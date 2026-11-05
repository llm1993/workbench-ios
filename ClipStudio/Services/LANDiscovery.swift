import Foundation
import CryptoKit

@MainActor
final class LANDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var changed: (([LANPeer]) -> Void)?
    var failed: ((String) -> Void)?
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var resolved: [String: LANPeer] = [:]
    private var scope = ""
    private var keyID = ""
    private var auth: SymmetricKey?

    func start(scope: String, keyID: String, auth: SymmetricKey) {
        guard browser == nil else { return }
        self.scope = scope; self.keyID = keyID; self.auth = auth
        let browser = NetServiceBrowser()
        browser.delegate = self; self.browser = browser
        browser.searchForServices(ofType: LANProtocol.service, inDomain: "local.")
    }
    func stop() {
        browser?.stop(); browser?.delegate = nil; browser = nil
        for service in services.values { service.stopMonitoring(); service.stop(); service.delegate = nil }
        services.removeAll(); resolved.removeAll(); auth = nil
        changed?([])
    }
    private func serviceKey(_ service: NetService) -> String { service.domain + "|" + service.type + "|" + service.name }
    private func publish() {
        var unique: [String: LANPeer] = [:]
        for peer in resolved.values.sorted(by: { ($0.host, $0.port) < ($1.host, $1.port) }) { unique[peer.id] = peer }
        changed?(Array(unique.values).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        let id = serviceKey(service)
        guard services.count < 64, services[id] == nil else { return }
        services[id] = service; service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        let id = serviceKey(service)
        services.removeValue(forKey: id)?.stop(); resolved.removeValue(forKey: id); publish()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        failed?("无法查找附近设备。请在系统设置中允许工作台访问本地网络，并确认两台设备处于可互通的网络。")
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services[serviceKey(sender)] === sender else { return }
        sender.startMonitoring(); update(sender)
    }
    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) { update(sender, txtData: data) }
    private func update(_ service: NetService, txtData: Data? = nil) {
        let id = serviceKey(service)
        guard services[id] === service, let auth, let host = service.hostName,
              let data = txtData ?? service.txtRecordData(), data.count <= 2048 else { return }
        if let peer = try? LANProtocol.peer(txt: NetService.dictionary(fromTXTRecord: data), host: host,
                                          port: service.port, scope: scope, keyID: keyID, key: auth) {
            resolved[id] = peer
        } else { resolved.removeValue(forKey: id) }
        publish()
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolved.removeValue(forKey: serviceKey(sender)); publish()
    }
}
