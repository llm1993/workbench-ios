import SwiftUI

struct WorkspaceSettingsView: View {
    @EnvironmentObject private var store: ClipStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @State private var profile: JSONValue = .null
    @State private var failure: String?
    @State private var login = false
    @State private var logout = false
    var body: some View {
        NavigationStack {
            Form {
                if let failure { NativeFailure(message:failure) }
                Section("工作台账号") {
                    LabeledContent("账号",value:store.account?.username ?? "未登录")
                    LabeledContent("工作台",value:store.account?.base.host ?? "")
                    Button("重新登录 / 切换账号"){login=true}
                    NavigationLink("修改密码"){PasswordView()}
                    NavigationLink("登录设备"){SessionDevicesView()}
                    NavigationLink("门厅应用排序与显隐"){HomeLayoutView()}
                }
                Section("外观") {
                    Picker("显示模式",selection:$appearance){Text("跟随系统").tag("system");Text("浅色").tag("light");Text("深色").tag("dark")}
                }
                Section("推送") {NavigationLink("Bark 推送配置"){BarkSettingsView()}}
                if profile["apps"].array.contains(where: { $0["key"].text == "clip" }) {
                    Section("剪贴板") { NavigationLink("加密与历史管理") { ClipSecurityView() } }
                }
                if profile["is_admin"].flag {
                    Section("管理") {
                        NavigationLink("邀请"){InvitesView()}
                        NavigationLink("用户与应用权限"){UsersView()}
                        NavigationLink("值守与代理"){AdminStatusView()}
                    }
                }
                Section("关于") {
                    LabeledContent("版本",value:Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Text("未读默认同步工作台账号，也可切换到独立的本机阅读库；各云端模块使用当前工作台账号。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {Button("退出登录",role:.destructive){logout=true}.disabled(store.busy)}
            }.navigationTitle("账户与设置").navigationBarTitleDisplayMode(.inline)
                .toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){dismiss()}}}
                .sheet(isPresented:$login){NavigationStack{LoginView()}.environmentObject(store)}
                .modifier(OperationError(enabled:!login))
                .confirmationDialog("退出会清除本机令牌与剪贴板密钥，保留云端数据及未读本机阅读库。",isPresented:$logout,titleVisibility:.visible){
                    Button("退出并撤销会话",role:.destructive){Task{await store.logout();if store.account == nil{dismiss()}}}
                    Button("仅退出本机",role:.destructive){Task{await store.logout(localOnly:true);if store.account == nil{dismiss()}}}
                }
                .task(id:(store.account?.base.absoluteString ?? "")+(store.account?.username ?? "")) {
                    profile = .null
                    do { if let api=store.api { let next=try await api.document("/api/auth/me");try Task.checkCancellation();profile=next } }
                    catch is CancellationError{} catch{failure=error.localizedDescription}
                }
                .onChange(of:store.account?.username){old,name in if name != old{dismiss()}}
        }
    }
}

struct PasswordView: View {
    @EnvironmentObject private var store:ClipStore
    @State private var old=""
    @State private var new=""
    @State private var confirm=""
    @State private var busy=false
    @State private var message:String?
    @State private var failed=false
    var body:some View{
        Form{
            Section{SecureField("当前密码",text:$old).textContentType(.password);SecureField("新密码（至少 8 位）",text:$new).textContentType(.newPassword);SecureField("确认新密码",text:$confirm)}
            Section{Button(busy ? "更新中…" : "更新密码"){Task{await update()}}.disabled(busy)}footer:{Text("修改后其他设备会退出，本机使用服务器签发的新会话保持登录。")}
            if let message{Text(message).foregroundStyle(failed ? .red : Theme.accent)}
        }.navigationTitle("修改密码")
    }
    private func update()async{
        guard !busy,let api=store.api else{return};busy=true;defer{busy=false}
        do{
            guard new.unicodeScalars.count>=8,new==confirm else{throw ClipError("新密码至少 8 位，且两次输入必须一致")}
            let response=try await api.document("/api/auth/password",method:"POST",payload:.object(["old_password":.string(old),"new_password":.string(new)]))
            try store.acceptSessionResponse(response,expectedToken:api.token);old="";new="";confirm="";failed=false;message="密码已更新，其他设备已退出。"
        }catch{failed=true;message=error.localizedDescription}
    }
}

struct SessionDevicesView:View{
    @EnvironmentObject private var store:ClipStore
    @State private var sessions:[JSONValue]=[]
    @State private var failure:String?
    @State private var pending:PendingMutation?
    @State private var busy=false
    var body:some View{
        List{
            if let failure{NativeFailure(message:failure)}
            ForEach(sessions,id:\.selfKey){s in
                VStack(alignment:.leading,spacing:8){
                    Text((s["name"].text.isEmpty ? "未命名设备" : s["name"].text)+(s["current"].flag ? " · 当前设备" : "")).font(.headline)
                    Text("最近活跃 "+s["last_seen_at"].text).font(.caption).foregroundStyle(.secondary)
                    Text("到期 "+s["expires_at"].text).font(.caption).foregroundStyle(.secondary)
                    Button(s["current"].flag ? "退出当前设备" : "退出此设备",role:.destructive){pending=PendingMutation(title:"撤销此设备的登录？",path:"/api/auth/sessions/\(s["id"].text)")}
                }.padding(.vertical,8)
            }
            Button("退出其他所有设备",role:.destructive){pending=PendingMutation(title:"退出其他所有设备？本机保留登录。",path:"/api/auth/sessions/revoke-others",method:"POST")}
        }.navigationTitle("登录设备").disabled(busy).task{await load()}.refreshable{await load()}
            .confirmationDialog(pending?.title ?? "确认",isPresented:Binding(get:{pending != nil},set:{if !$0{pending=nil}}),titleVisibility:.visible){if let action=pending{Button("确认退出",role:.destructive){Task{await execute(action)}}}}
    }
    private func load()async{do{if let api=store.api{sessions=try await api.document("/api/auth/sessions")["items"].array;failure=nil}}catch{failure=error.localizedDescription}}
    private func execute(_ action:PendingMutation)async{
        guard !busy,let api=store.api else{return};busy=true;defer{busy=false}
        do{let response=try await api.document(action.path,method:action.method)
            guard store.account?.token == api.token else{throw CancellationError()}
            if response["current"].flag{try store.clearLocalSession()}else{try store.acceptSessionResponse(response,expectedToken:api.token);await load()}
        }catch{failure=error.localizedDescription}
    }
}

struct HomeLayoutView:View{
    @EnvironmentObject private var store:ClipStore
    @State private var layout = WorkspaceAppLayout(apps: [])
    @State private var failure:String?
    @State private var busy=false
    @State private var loading=false
    @State private var loaded=false
    private var accountIdentity: String { (store.account?.base.absoluteString ?? "") + "|" + (store.account?.username ?? "") }
    var body:some View{
        List{
            Section{
                ForEach($layout.apps){$app in
                    Toggle(app.name,isOn:$app.isVisible).accessibilityIdentifier("layout-" + app.key)
                }.onMove{from,to in layout.apps.move(fromOffsets:from,toOffset:to)}
            }footer:{Text("拖动调整顺序。隐藏只影响首页，不会撤销使用权限。")}
            if loading { ProgressView("正在加载应用…") }
            if let failure{Text(failure).foregroundStyle(.red);Button("重试"){Task{if loaded{await save()}else{await load()}}}}
            Button(busy ? "保存中…" : "保存布局"){Task{await save()}}.disabled(!loaded)
        }.disabled(busy || loading).navigationTitle("门厅").toolbar{EditButton()}.task(id:accountIdentity){await load()}
    }
    private func load()async{
        guard let api=store.api else{return}
        let identity=accountIdentity;loading=true;loaded=false;defer{loading=false}
        do{
            let profile:WorkspaceProfile=try await api.request("/api/auth/me")
            try Task.checkCancellation();guard identity==accountIdentity else{return}
            layout=WorkspaceAppLayout(apps:profile.apps);loaded=true;failure=nil
        }catch is CancellationError{}catch{if identity==accountIdentity{failure=error.localizedDescription}}
    }
    private func save()async{
        guard !busy,loaded,let api=store.api else{return};busy=true;defer{busy=false}
        let identity=accountIdentity
        do{
            let response:WorkspaceAppLayout=try await api.request("/api/auth/apps",method:"PUT",body:JSONEncoder().encode(layout.payload))
            try Task.checkCancellation();guard identity==accountIdentity else{return}
            layout=response;failure=nil
        }catch is CancellationError{}catch{if identity==accountIdentity{failure=error.localizedDescription}}
    }
}

struct BarkSettingsView:View{
    @EnvironmentObject private var store:ClipStore
    @State private var server="default"
    @State private var key=""
    @State private var configured=false
    @State private var hint=""
    @State private var failure:String?
    @State private var busy=false
    @State private var clear=false
    var body:some View{
        Form{
            Section{
                Picker("推送服务器",selection:$server){Text("本站自建 Bark").tag("default");Text("Bark 官方").tag("official")}
                SecureField("设备 key（留空保持原值）",text:$key).textInputAutocapitalization(.never).autocorrectionDisabled()
                LabeledContent("设备 key",value:configured ? "已配置 · 尾号 "+hint : "未配置")
                Button("保存"){Task{await save()}}.disabled(busy)
                Button("清除设备 key",role:.destructive){clear=true}.disabled(!configured || busy)
            }footer:{Text("设备 key 用于发送到这台 Bark App，与剪贴板加密口令不同。")}
            if let failure{NativeFailure(message:failure)}
        }.navigationTitle("Bark 推送").task{await load()}
            .confirmationDialog("清除后将停止向此设备推送。",isPresented:$clear,titleVisibility:.visible){Button("清除",role:.destructive){Task{await save(clear:true)}}}
    }
    private func load()async{do{if let api=store.api{let d=try await api.document("/api/clip/settings");server=d["bark_server"].text;configured=d["bark_key_set"].flag;hint=d["bark_key_hint"].text}}catch{failure=error.localizedDescription}}
    private func save(clear:Bool=false)async{guard !busy,let api=store.api else{return};busy=true;defer{busy=false};do{var p:JSONValue = .object(["bark_server":.string(server)]);if clear || !key.isEmpty{p["bark_key"] = .string(clear ? "" : key)};_=try await api.document("/api/clip/settings",method:"PUT",payload:p);key="";failure=nil;await load()}catch{failure=error.localizedDescription}}
}

struct InvitesView:View{
    @EnvironmentObject private var store:ClipStore
    @State private var items:[JSONValue]=[]
    @State private var code:JSONValue = .null
    @State private var form:FormRequest?
    @State private var failure:String?
    @State private var revoke:JSONValue?
    var body:some View{
        List{
            Button("生成邀请码",systemImage:"plus"){create()}
            if !code.isNull{Section("本次生成，仅显示一次"){
                Text(code["code"].text).font(.title2.monospaced()).textSelection(.enabled)
                Button("复制邀请消息"){UIPasteboard.general.string="邀请你加入我的工作台：\(store.account?.base.absoluteString ?? "")\n邀请码：\(code["code"].text)"}
            }}
            if let failure{NativeFailure(message:failure)}
            ForEach(items,id:\.selfKey){r in
                VStack(alignment:.leading,spacing:7){
                    Text(r["note"].text.isEmpty ? "邀请码 · "+r["hint"].text : r["note"].text).font(.headline)
                    Text("\(r["used_count"].int) / \(r["max_uses"].int) 次 · "+(r["active"].flag ? "有效" : "已失效")).font(.caption)
                    Text("到期 "+r["expires_at"].text).font(.caption).foregroundStyle(.secondary)
                    if !r["revoked"].flag{Button("撤销",role:.destructive){revoke=r}}
                }
            }
        }.navigationTitle("邀请").sheet(item:$form){NativeForm($0)}.task{await load()}.refreshable{await load()}
            .confirmationDialog("撤销此邀请码？",isPresented:Binding(get:{revoke != nil},set:{if !$0{revoke=nil}}),titleVisibility:.visible){if let r=revoke{Button("撤销",role:.destructive){Task{do{if let api=store.api{_=try await api.document("/api/auth/invites/\(r["id"].int)",method:"DELETE");await load()}}catch{failure=error.localizedDescription}}}}}
    }
    private func load()async{do{if let api=store.api{items=try await api.document("/api/auth/invites")["items"].array}}catch{failure=error.localizedDescription}}
    private func create(){form=FormRequest(title:"生成邀请码",fields:[FormField(id:"note",title:"给谁的（备注）"),FormField(id:"days",title:"有效天数",kind:.integer,required:true,min:1,max:90),FormField(id:"max_uses",title:"可用次数",kind:.integer,required:true,min:1,max:50)],initial:.object(["days":.number(7),"max_uses":.number(1)])){v in
        guard let api=store.api else{throw ClipError("请先登录")};code=try await api.document("/api/auth/invites",method:"POST",payload:v);await load()
    }}
}

struct UsersView:View{
    @EnvironmentObject private var store:ClipStore
    @State private var users:[JSONValue]=[]
    @State private var catalog:[JSONValue]=[]
    @State private var pending:PendingMutation?
    @State private var failure:String?
    @State private var busy=false
    @State private var grants: Set<Int> = []
    @State private var grantsReady = false
    var body:some View{
        List{
            if let failure{NativeFailure(message:failure)}
            ForEach(users,id:\.selfKey){u in
                Section(u["username"].text+(u["is_admin"].flag ? " · 管理员" : "")){
                    Text(u["disabled"].flag ? "已停用" : "正常").foregroundStyle(u["disabled"].flag ? .red : Theme.accent)
                    if grantsReady && !u["is_admin"].flag && !u["disabled"].flag {
                        Button { pending = PendingMutation(title: "\(grants.contains(u["id"].int) ? "关闭" : "开通") \(u["username"].text) 的未读模型功能？使用管理员额度，文章标题和摘要片段会发送至模型服务。", path: "/api/weidu/digest/grants/\(u["id"].int)", method: "PUT", payload: .object(["granted": .bool(!grants.contains(u["id"].int))])) } label: { LabeledContent("未读 AI 与模型摘要", value: grants.contains(u["id"].int) ? "已开通" : "未开通") }
                    }
                    if !u["is_admin"].flag {
                        ForEach(catalog,id:\.moduleKey){app in
                            let k=app["key"].text
                            Button{pending=PendingMutation(title:"\(u["apps"][k].flag ? "关闭" : "开通") \(u["username"].text) 的\(app["name"].text)权限？",path:"/api/auth/users/\(u["id"].int)/apps",method:"PUT",payload:.object(["apps":.object([k:.bool(!u["apps"][k].flag)])]))}label:{LabeledContent(app["name"].text,value:u["apps"][k].flag ? "已开通" : "未开通")}
                        }
                    }
                    if u["username"].text != store.account?.username{
                        Button(u["disabled"].flag ? "恢复用户" : "停用用户",role:u["disabled"].flag ? nil : .destructive){pending=PendingMutation(title:u["disabled"].flag ? "恢复此用户登录？" : "停用此用户并退出其所有设备？",path:"/api/auth/users/\(u["id"].int)/disable",method:"POST",payload:.object(["disabled":.bool(!u["disabled"].flag)]))}
                    }
                }
            }
        }.navigationTitle("用户与权限").disabled(busy).task{await load()}
            .confirmationDialog(pending?.title ?? "确认修改",isPresented:Binding(get:{pending != nil},set:{if !$0{pending=nil}}),titleVisibility:.visible){if let p=pending{Button("确认",role:.destructive){Task{await execute(p)}}}}
    }
    private func load()async{do{if let api=store.api{
        let d=try await api.document("/api/auth/users");users=d["items"].array;catalog=d["apps"].array
        grantsReady = false
        do { grants = Set(try await api.document("/api/weidu/digest/grants")["granted"].array.map(\.int)); grantsReady = true }
        catch let e as HTTPFailure where e.status == 503 { }
    }}catch{failure=error.localizedDescription}}
    private func execute(_ p:PendingMutation)async{guard !busy,let api=store.api else{return};busy=true;defer{busy=false};do{_=try await api.document(p.path,method:p.method,payload:p.payload);await load()}catch{failure=error.localizedDescription}}
}
extension JSONValue{var moduleKey:String{self["key"].text}}

struct AdminStatusView:View{
    @EnvironmentObject private var store:ClipStore
    @State private var status:JSONValue = .null
    @State private var proxy:JSONValue = .null
    @State private var failure:String?
    @State private var hours:Int?
    @State private var busy=false
    var body:some View{
        List{
            if let failure{NativeFailure(message:failure)}
            Section("值守"){
                LabeledContent("整体状态",value:status["overall"]["text"].text)
                ForEach([("c5","C5"),("redmi","红米")],id:\.0){k,title in
                    DisclosureGroup(title) {
                        if !status[k]["error"].text.isEmpty {Text(status[k]["error"].text).foregroundStyle(.red)}
                        if status[k]["stale"].flag {Text("探针或上报已过期").foregroundStyle(.orange)}
                        ForEach(Array(status[k]["checks"].array.enumerated()),id:\.offset){_,check in
                            VStack(alignment:.leading,spacing:4) {
                                LabeledContent(check["label"].text,value:check["ok"].isNull ? "未知" : check["ok"].flag ? "正常" : "异常")
                                Text(check["detail"].text).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("本周告警",value:status[k]["weekly_alerts"].text)
                    }
                }
                LabeledContent("最近备份",value:status["backup"]["file"].text)
                if !status["backup"]["error"].text.isEmpty {Text(status["backup"]["error"].text).foregroundStyle(.red)}
            }
            Section("红米出口代理"){
                LabeledContent("服务端设置",value:proxy["on"].flag ? "已开启" : "已关闭")
                LabeledContent("设备实际状态",value:!proxy["redmi"]["error"].text.isEmpty ? proxy["redmi"]["error"].text : proxy["redmi"]["stale"].flag ? "上报已过期" : proxy["redmi"]["running"].flag ? "运行中" : "未运行")
                if !proxy["until"].isNull {Text("设置截至 "+Date(timeIntervalSince1970:proxy["until"].double).formatted()).font(.caption)}
                ForEach([1,2,4],id:\.self){h in Button("开启 \(h) 小时"){hours=h}}
                Button("立即关闭",role:.destructive){hours=0}
                Text("变更等待设备下一次上报生效；设备失联时，不把服务端设置当作实际运行成功。").font(.caption).foregroundStyle(.secondary)
            }.disabled(busy)
        }.navigationTitle("值守与代理").task{await load()}.refreshable{await load()}
            .confirmationDialog(hours == 0 ? "立即关闭代理？" : "开启代理 \(hours ?? 0) 小时？",isPresented:Binding(get:{hours != nil},set:{if !$0{hours=nil}}),titleVisibility:.visible){if let h=hours{Button("确认变更",role:.destructive){Task{await change(h)}}}}
    }
    private func load()async{guard let api=store.api else{return};do{async let a=api.document("/api/admin/status");async let b=api.document("/api/admin/proxy");let d=try await(a,b);status=d.0;proxy=d.1}catch{failure=error.localizedDescription}}
    private func change(_ h:Int)async{guard !busy,let api=store.api else{return};busy=true;defer{busy=false};do{proxy=try await api.document("/api/admin/proxy",method:"POST",payload:.object(["hours":.integer(h)]))}catch{failure=error.localizedDescription}}
}

struct RegisterView:View{
    @EnvironmentObject private var store:ClipStore
    @Environment(\.dismiss) private var dismiss
    @State private var server: String
    @State private var username=""
    @State private var password=""
    @State private var confirm=""
    @State private var invite=""
    init(server: String = "") { _server = State(initialValue: server) }
    var body:some View{
        Form{
            TextField("工作台 HTTPS 地址",text:$server,prompt:Text(ClipAPI.serverAddressExample)).keyboardType(.URL).textContentType(.URL)
            TextField("邀请码",text:$invite)
            TextField("用户名（2–32 位）",text:$username).textContentType(.username)
            SecureField("密码（至少 8 位）",text:$password).textContentType(.newPassword)
            SecureField("确认密码",text:$confirm)
            Button(store.busy ? "注册中…" : "注册并登录"){
                guard password==confirm,password.unicodeScalars.count>=8 else{store.error="密码至少 8 位，且两次输入必须一致";return}
                Task{if await store.register(server:server,username:username,password:password,invite:invite){password="";confirm="";dismiss()}}
            }.disabled(store.busy || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || invite.isEmpty || username.isEmpty)
        }.textInputAutocapitalization(.never).autocorrectionDisabled().navigationTitle("邀请注册")
            .modifier(OperationError())
    }
}
