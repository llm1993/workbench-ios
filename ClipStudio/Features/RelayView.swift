import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import ImageIO
import UIKit

enum RelayCrypto {
    static let chunk = 4 * 1024 * 1024
    static func safeName(_ input: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let clean = String(String.UnicodeScalarView(input.unicodeScalars.map { forbidden.contains($0) ? UnicodeScalar(95)! : $0 })).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { return "文件" }
        let ext = (clean as NSString).pathExtension
        let suffix = ext.isEmpty || ext.utf8.count > 24 ? "" : "." + ext
        var stem = suffix.isEmpty ? clean : (clean as NSString).deletingPathExtension
        while (stem + suffix).utf8.count > 240 { stem.removeLast() }
        return (stem.isEmpty ? "文件" : stem) + suffix
    }
    static func thumbnail(url: URL, size: Int, type: UTType?) -> Data? {
        guard size <= 30 * 1024 * 1024, type?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect); context.draw(image, in: rect)
        guard let flattened = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
    static func openThumbnail(_ file: JSONValue, key: Data) throws -> Data {
        guard file["thumb"].text.utf8.count <= 100_000 else { throw ClipError("缩略图过大") }
        return try ClipCrypto.open(file["thumb"].text, key: key, aad: "clipstudio:file:v1:\(file["key_id"].text):\(file["fid"].text):thumb")
    }
    static func aad(keyID: String, fid: String, part: String) -> Data { Data("clipstudio:file:v1:\(keyID):\(fid):\(part)".utf8) }
    static func openMeta(_ file: JSONValue, key: Data) throws -> JSONValue {
        let data = try ClipCrypto.open(file["meta"].text, key: key, aad: "clipstudio:file:v1:\(file["key_id"].text):\(file["fid"].text):meta")
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    static func sealChunk(_ plain: Data, key: Data, keyID: String, fid: String, index: Int, count: Int) throws -> Data {
        guard key.count == 32 else { throw ClipError("请先解锁剪贴板") }
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data:key), authenticating:aad(keyID:keyID,fid:fid,part:"chunk:\(index):\(count)"))
        guard let bytes=box.combined else { throw ClipError("文件加密失败") }; return bytes
    }
    static func openChunk(_ bytes: Data, key: Data, keyID: String, fid: String, index: Int, count: Int) throws -> Data {
        guard key.count == 32 else { throw ClipError("请先解锁剪贴板") }
        do{return try AES.GCM.open(AES.GCM.SealedBox(combined:bytes),using:SymmetricKey(data:key),authenticating:aad(keyID:keyID,fid:fid,part:"chunk:\(index):\(count)"))}
        catch{throw ClipError("文件块校验失败，停止下载")}
    }
    static func prepare(url: URL, directory: URL, account: Account, limit: Int) throws -> JSONValue {
        let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
        let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.contentTypeKey,.contentModificationDateKey])
        guard values.isRegularFile == true, let size=values.fileSize,size>=0,size<=limit else{throw ClipError("文件超过允许大小，或不是普通文件")}
        let chunks=max(1,(size+chunk-1)/chunk)
        let fid=try ClipCrypto.random(8).map{String(format:"%02x",$0)}.joined()
        let folder=directory.appendingPathComponent(fid,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var complete=false
        defer{if !complete{try? FileManager.default.removeItem(at:folder)}}
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        var hasher=SHA256();var total=0
        for i in 0..<chunks{
            try Task.checkCancellation()
            let bytes=try handle.read(upToCount:chunk) ?? Data();total += bytes.count;hasher.update(data:bytes)
            let encrypted=try sealChunk(bytes,key:account.key,keyID:account.keyInfo.key_id ?? "",fid:fid,index:i,count:chunks)
            try encrypted.write(to:folder.appendingPathComponent("\(i).bin"),options:[.atomic,.completeFileProtection])
        }
        guard total==size,(try handle.read(upToCount:1) ?? Data()).isEmpty else{throw ClipError("文件读取过程中发生变化，请重新选择")}
        let end=try url.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        guard end.fileSize==size,end.contentModificationDate==values.contentModificationDate else{throw ClipError("文件读取过程中被修改，请重新选择")}
        let hash=hasher.finalize().map{String(format:"%02x",$0)}.joined()
        let meta:JSONValue = .object(["name":.string(url.lastPathComponent),"size":.number(Double(size)),"type":.string(values.contentType?.preferredMIMEType ?? "application/octet-stream"),"sha256":.string(hash),"chunk":.number(Double(chunk))])
        let keyID=account.keyInfo.key_id ?? ""
        let sealed=try ClipCrypto.seal(JSONEncoder().encode(meta),key:account.key,aad:"clipstudio:file:v1:\(keyID):\(fid):meta")
        let jpeg = thumbnail(url: url, size: size, type: values.contentType)
        let thumb: JSONValue = try jpeg.map { JSONValue.string(try ClipCrypto.seal($0, key: account.key, aad: "clipstudio:file:v1:\(keyID):\(fid):thumb")) } ?? .null
        let payload:JSONValue = .object(["fid":.string(fid),"key_id":.string(keyID),"chunks":.number(Double(chunks)),"cipher_size":.number(Double(size+28*chunks)),"meta":.string(sealed),"thumb":thumb,"source":.string("iphone"),"device":.string("iPhone · 工作台")])
        try JSONEncoder().encode(payload).write(to:folder.appendingPathComponent("upload.json"),options:[.atomic,.completeFileProtection]);complete=true
        return payload
    }
}

struct RelayShare:Identifiable{let id=UUID();let url:URL;let remoteID:Int;let accountScope:String;let keyID:String}
struct NativeShareSheet:UIViewControllerRepresentable{
    let item:RelayShare
    let completion:(Bool)->Void
    func makeUIViewController(context:Context)->UIActivityViewController{
        let controller=UIActivityViewController(activityItems:[item.url],applicationActivities:nil)
        controller.completionWithItemsHandler={_,completed,_,_ in completion(completed)}
        return controller
    }
    func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context){}
}

struct RelayView:View{
    @EnvironmentObject private var store:ClipStore
    @Environment(\.scenePhase) private var phase
    @StateObject private var connectivity = TransferConnectivity()
    @State private var files:[JSONValue]=[]
    @State private var queued:[JSONValue]=[]
    @State private var usage:JSONValue = .null
    @State private var failure:String?
    @State private var notice:String?
    @State private var choosing=false
    @State private var more=false
    @State private var beforeID:Int?
    @State private var progress:Double=0
    @State private var active=false
    @State private var task:Task<Void,Never>?
    @State private var share:RelayShare?
    @State private var exportedURL:URL?
    @State private var pending:PendingMutation?
    @State private var pendingSources:[URL]=[]
    @State private var resumeOnForeground=false
    @State private var downloadToResume:JSONValue?
    @State private var resumeOnNetwork = false
    @State private var loadRevision = UUID()
    @State private var loading = false
    private var accountScope: String { (store.account?.base.absoluteString ?? "") + "|" + (store.account?.username ?? "") }
    private var directory:URL?{
        guard let a=store.account else{return nil}
        let hash=SHA256.hash(data:Data((a.base.absoluteString+"|"+a.username).utf8)).map{String(format:"%02x",$0)}.joined()
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?.appendingPathComponent("Relay/\(hash)",isDirectory:true)
    }
    var body:some View{
        ScrollView{
            LazyVStack(alignment:.leading,spacing:16){
                NativeCard{
                    Text("手机电脑互传文件").font(.headline)
                    Text("文件先在本机加密，传输时请保持 App 在前台。切走暂停，回来可继续。").font(.caption).foregroundStyle(.secondary)
                    Button("选择文件",systemImage:"plus"){choosing=true}.disabled(active || usage.isNull || !usage["accepting"].flag)
                    Text("已用 \(ByteCountFormatter.string(fromByteCount:Int64(usage["used"].double),countStyle:.file)) / \(ByteCountFormatter.string(fromByteCount:Int64(usage["quota"].double),countStyle:.file)) · \(usage["ttl_days"].int) 天后到期").font(.caption)
                    if !usage["accepting"].flag && !usage.isNull{Text(usage["refused"].text).font(.caption).foregroundStyle(.red)}
                    if active{ProgressView(value:progress);Button("暂停"){resumeOnForeground=false;resumeOnNetwork=false;task?.cancel()}}
                    if !active && (!queued.isEmpty || !pendingSources.isEmpty || downloadToResume != nil) {
                        Button(downloadToResume == nil ? "继续队列" : "继续下载"){continueIntent()}
                    }
                    if let notice{Text(notice).font(.caption).foregroundStyle(Theme.accent)}
                }
                if let failure{NativeFailure(message:failure);Button("重新加载"){Task{await load()}}}
                if !pendingSources.isEmpty {
                    Text("待加密文件").font(.title3.bold())
                    ForEach(Array(pendingSources.enumerated()), id: \.offset) { index, source in
                        NativeCard {
                            Text(source.lastPathComponent).font(.headline)
                            Button("移除待处理文件", role: .destructive) { pendingSources.remove(at: index) }.disabled(active)
                        }
                    }
                }
                if !queued.isEmpty{
                    Text("待续传").font(.title3.bold())
                    ForEach(queued,id:\.fileKey){file in
                        NativeCard{
                            Text(fileName(file)).font(.headline)
                            Button("继续上传"){downloadToResume=nil;start{try await upload(file)}}.disabled(active)
                            Button("移除本机队列",role:.destructive){pending=PendingMutation(title:"移除本机已加密队列？云端未完成文件可在下方删除。",path:"local:\(file["fid"].text)")}.disabled(active)
                        }
                    }
                }
                Text("中转中的文件").font(.title3.bold())
                ForEach(files,id:\.selfKey){file in
                    NativeCard{
                        RelayThumbnail(file: file, key: store.account?.key ?? Data())
                        Text(fileName(file)).font(.headline)
                        Text("\(file["source"].text == "windows" ? "电脑" : "手机/网页") · \(file["expires_at"].text)").font(.caption).foregroundStyle(.secondary)
                        if file["status"].text == "ready"{Button("下载并导出",systemImage:"square.and.arrow.down"){downloadToResume=file;start{try await download(file)}}.disabled(active)}
                        else{Text("上传未完成").font(.caption).foregroundStyle(.secondary)}
                        Button("删除云端文件",role:.destructive){pending=PendingMutation(title:"从所有设备的中转区删除此文件？",path:"/api/relay/files/\(file["id"].int)")}.disabled(active)
                    }
                }
                if more{Button("加载更早文件"){Task{await load(append:true)}}.disabled(active || loading)}
            }.padding(20)
        }.background(AmbientBackground()).navigationTitle("文件中转")
            .fileImporter(isPresented:$choosing,allowedContentTypes:[.item],allowsMultipleSelection:true){result in
                switch result{case .success(let urls):pendingSources+=urls;downloadToResume=nil;start{try await resumeAll()};case .failure(let e):failure=e.localizedDescription}
            }
            .sheet(item:$share,onDismiss:{cleanupExport()}){item in NativeShareSheet(item:item){completed in
                if completed{Task{do{if item.accountScope == accountScope, item.keyID == store.account?.keyInfo.key_id, let api=store.api{_=try await api.document("/api/relay/files/\(item.remoteID)/downloaded",method:"POST")}}catch{failure="文件已导出，下载次数回写失败。"}}}
            }}
            .confirmationDialog(pending?.title ?? "确认",isPresented:Binding(get:{pending != nil},set:{if !$0{pending=nil}}),titleVisibility:.visible){if let p=pending{Button("确认删除",role:.destructive){Task{await remove(p)}}}}
            .task{await load();loadQueue()}.refreshable{await load()}
            .onChange(of:phase){_,p in
                UIApplication.shared.isIdleTimerDisabled = active && p == .active
                if p != .active { if active { resumeOnForeground=true };task?.cancel() }
                else {loadQueue();Task{await load()};resumePendingIntent()}
            }
            .onChange(of:active){_,running in
                UIApplication.shared.isIdleTimerDisabled = running && phase == .active
                if !running { resumePendingIntent() }
            }
            .onChange(of:connectivity.connected) { _, connected in
                if !connected && active { resumeOnNetwork = true; task?.cancel() }
                if connected { resumePendingIntent() }
            }
            .onChange(of:store.account?.key.count){_,count in if count == 32{Task{await load()}}}
            .onChange(of:store.account?.keyInfo.key_id) { _, _ in
                resumeOnForeground=false;resumeOnNetwork=false;task?.cancel();pendingSources=[];downloadToResume=nil;share=nil;cleanupExport()
                files=[];usage = .null;Task{await load()};loadQueue()
            }
            .onDisappear{resumeOnForeground=false;resumeOnNetwork=false;task?.cancel();cleanupExport();UIApplication.shared.isIdleTimerDisabled=false}
    }
    private func fileName(_ file:JSONValue)->String{
        guard let account=store.account,file["key_id"].text==account.keyInfo.key_id,let meta=try? RelayCrypto.openMeta(file,key:account.key) else{return "无法解密的文件（请重新解锁）"}
        return meta["name"].text
    }
    private func loadQueue(){
        guard let directory else{return};queued=[]
        let urls=(try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
        for url in urls where validFID(url.lastPathComponent){
            if let bytes=try? Data(contentsOf:url.appendingPathComponent("upload.json")),let item=try? JSONDecoder().decode(JSONValue.self,from:bytes){queued.append(item)}
        }
    }
    private func validFID(_ fid:String)->Bool{fid.range(of:"^[0-9a-f]{16}$",options:.regularExpression) != nil}
    private func start(_ operation:@escaping ()async throws->Void){
        guard !active else{return};active=true;progress=0;failure=nil;notice=nil
        UIApplication.shared.isIdleTimerDisabled = phase == .active
        task=Task{defer{active=false;loadQueue()};do{try await operation()}catch is CancellationError{notice="已暂停，可继续传输"}catch let e as URLError where e.code == .cancelled{notice="已暂停，可继续传输"}catch{failure=error.localizedDescription}}
    }
    private func continueIntent(){
        guard connectivity.connected else { resumeOnNetwork = true; notice = "网络断开，恢复连接后继续"; return }
        if let file=downloadToResume{start{try await download(file)}}else{start{try await resumeAll()}}
    }
    private func resumePendingIntent() {
        guard (resumeOnForeground || resumeOnNetwork), phase == .active, connectivity.connected, !active else { return }
        resumeOnForeground = false; resumeOnNetwork = false; continueIntent()
    }
    private func load(append:Bool=false)async{
        if append && loading { return }
        let revision = UUID(); loadRevision = revision; loading = true
        defer { if loadRevision == revision { loading = false } }
        do{let (account,api)=try await store.validatedAccount()
            let nextUsage=try await api.document("/api/relay/usage")
            let query=append ? ["before_id":String(beforeID ?? 1),"limit":"20"] : ["limit":"20"]
            let page=try await api.document(ClipAPI.path("/api/relay/files",query:query))
            try Task.checkCancellation(); guard revision == loadRevision, sameAccount(account) else { return }
            usage = nextUsage; failure = nil
            var new=page["files"].array+page["uploading"].array
            if append{let known=Set(files.map(\.selfKey));new=new.filter{!known.contains($0.selfKey)};files+=new}else{files=new}
            more=page["has_more"].flag
            beforeID=page["files"].array.last?["id"].int
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch { if revision == loadRevision { failure=error.localizedDescription } }
    }
    private func resumeAll()async throws{
        let (account,_)=try await store.validatedAccount();guard let directory else{throw ClipError("请先登录")}
        guard sameAccount(account) else { throw CancellationError() }
        let limit=usage["max_file_iphone"].int;guard limit>0 else{throw ClipError("服务器未提供有效文件上限")}
        while let url=pendingSources.first{
            try Task.checkCancellation();notice="正在加密文件…"
            let prepared=Task.detached{try RelayCrypto.prepare(url:url,directory:directory,account:account,limit:limit)}
            _=try await withTaskCancellationHandler(operation:{try await prepared.value},onCancel:{prepared.cancel()})
            try Task.checkCancellation();guard sameAccount(account),pendingSources.first == url else { throw CancellationError() }
            pendingSources.removeFirst();loadQueue()
        }
        loadQueue();let remaining=queued
        for payload in remaining{try Task.checkCancellation();try await upload(payload)}
    }
    private func upload(_ payload:JSONValue)async throws{
        let (account,api)=try await store.validatedAccount();let fid=payload["fid"].text
        guard sameAccount(account),let directory,validFID(fid),payload["key_id"].text==account.keyInfo.key_id else{throw ClipError("上传队列密钥已变更，请移除旧队列并重新选择文件")}
        let folder=directory.appendingPathComponent(fid,isDirectory:true)
        var remote=try await api.transferDocument("/api/relay/files",method:"POST",payload:payload,registration:true)
        if remote["status"].text != "ready"{
            remote=try await api.transferDocument("/api/relay/files/\(remote["id"].int)")
            let missing=remote["missing"].array.map(\.int),count=payload["chunks"].int
            for (i,n) in missing.enumerated(){
                guard sameAccount(account), n >= 0, n < count else { throw ClipError("文件队列或分块编号已失效，请刷新后重试") }
                try Task.checkCancellation();notice="正在上传 \(i+1)/\(missing.count) 块";progress=Double(count-missing.count+i)/Double(max(1,count))
                let bytes=try Data(contentsOf:folder.appendingPathComponent("\(n).bin"))
                _=try await retryBytes(api:api,path:"/api/relay/files/\(remote["id"].int)/chunks/\(n)",method:"PUT",body:bytes)
            }
            try Task.checkCancellation(); guard sameAccount(account) else { throw CancellationError() }
            _=try await api.transferDocument("/api/relay/files/\(remote["id"].int)/complete",method:"POST")
        }
        try Task.checkCancellation(); guard sameAccount(account) else { throw CancellationError() }
        try FileManager.default.removeItem(at:folder);progress=1;notice="文件已上传";await load()
    }
    private func retryBytes(api:ClipAPI,path:String,method:String="GET",body:Data?=nil)async throws->Data{
        try await api.transferBytes(path, method: method, body: body)
    }
    private func download(_ file:JSONValue)async throws{
        let (account,api)=try await store.validatedAccount();guard sameAccount(account),let directory,file["key_id"].text==account.keyInfo.key_id,validFID(file["fid"].text) else{throw ClipError("文件密钥不匹配，请重新解锁")}
        let meta=try RelayCrypto.openMeta(file,key:account.key),count=file["chunks"].int,size=meta["size"].int
        guard size>=0,size<=RelayCrypto.chunk*10000,meta["size"].numeric == Double(size),meta["chunk"].int==RelayCrypto.chunk,count>0,count<=10000 else{throw ClipError("文件分块信息无效")}
        guard count==max(1,(size+RelayCrypto.chunk-1)/RelayCrypto.chunk), meta["sha256"].text.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{throw ClipError("文件分块或校验信息无效")}
        let cache=directory.appendingPathComponent("download-"+file["fid"].text,isDirectory:true)
        try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("RelayExport-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        let url=temp.appendingPathComponent(RelayCrypto.safeName(meta["name"].text))
        try Data().write(to:url,options:.completeFileProtection)
        let out=try FileHandle(forWritingTo:url);var successful=false
        defer{try? out.close();if !successful{try? FileManager.default.removeItem(at:temp)}}
        var hash=SHA256(),total=0
        for i in 0..<count{
            try Task.checkCancellation();notice="正在下载 \(i+1)/\(count) 块";progress=Double(i)/Double(count)
            let chunkURL=cache.appendingPathComponent("\(i).bin")
            let bytes:Data
            if let cached=try? Data(contentsOf:chunkURL){bytes=cached}else{bytes=try await retryBytes(api:api,path:"/api/relay/files/\(file["id"].int)/chunks/\(i)");try bytes.write(to:chunkURL,options:[.atomic,.completeFileProtection])}
            let plain:Data
            do {
                guard bytes.count == min(RelayCrypto.chunk,size-i*RelayCrypto.chunk)+28 else { throw ClipError("文件块长度不符") }
                plain=try RelayCrypto.openChunk(bytes,key:account.key,keyID:file["key_id"].text,fid:file["fid"].text,index:i,count:count)
            } catch { try? FileManager.default.removeItem(at:chunkURL); throw error }
            hash.update(data:plain);total+=plain.count;try out.write(contentsOf:plain)
        }
        let digest=hash.finalize().map{String(format:"%02x",$0)}.joined()
        try Task.checkCancellation();guard sameAccount(account) else { throw CancellationError() }
        guard total==size,digest==meta["sha256"].text else{try? FileManager.default.removeItem(at:cache);throw ClipError("文件完整性校验失败，不会导出")}
        try out.synchronize();try FileManager.default.removeItem(at:cache)
        successful=true;downloadToResume=nil;exportedURL=temp;share=RelayShare(url:url,remoteID:file["id"].int,accountScope:accountScope,keyID:file["key_id"].text);progress=1;notice="文件校验通过，请选择保存位置"
    }
    private func cleanupExport(){if let url=exportedURL{try? FileManager.default.removeItem(at:url);exportedURL=nil}}
    private func sameAccount(_ account:Account)->Bool {
        store.account?.base==account.base && store.account?.username==account.username && store.account?.keyInfo.key_id==account.keyInfo.key_id && store.account?.key==account.key
    }
    private func remove(_ p:PendingMutation)async{
        do{if p.path.hasPrefix("local:"),let directory{let fid=String(p.path.dropFirst(6));guard validFID(fid)else{return};try FileManager.default.removeItem(at:directory.appendingPathComponent(fid,isDirectory:true));loadQueue()}
            else if let api=store.api{_=try await api.document(p.path,method:"DELETE");await load()}
        }catch{failure=error.localizedDescription}
    }
}
extension JSONValue{var fileKey:String{self["fid"].text}}

private struct RelayThumbnail: View {
    let file: JSONValue
    let key: Data
    @State private var preview: UIImage?
    private var identity: String {
        SHA256.hash(data: Data(file["thumb"].text.utf8) + key).map { String(format: "%02x", $0) }.joined()
    }
    var body: some View {
        Group {
            if let preview { Image(uiImage: preview).resizable().scaledToFit().frame(maxWidth: 160, maxHeight: 160).clipShape(RoundedRectangle(cornerRadius: 14)).accessibilityLabel("加密图片缩略预览") }
        }.task(id: identity) {
            preview = nil
            guard key.count == 32, !file["thumb"].text.isEmpty,
                  let bytes = try? RelayCrypto.openThumbnail(file, key: key),
                  let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary) else { return }
            preview = UIImage(cgImage: image)
        }
    }
}
