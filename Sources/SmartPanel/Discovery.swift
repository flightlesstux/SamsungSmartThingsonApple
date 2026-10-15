import Foundation

/// Finds Samsung TVs on the LAN: SSDP (DIAL) search, then confirms each host via its REST API on port 8001.
enum TVDiscovery {
    static func discover(timeout: TimeInterval = 3) async -> [TVDevice] {
        let hosts = await Task.detached { ssdpHosts(timeout: timeout) }.value
        return await withTaskGroup(of: TVDevice?.self) { group in
            for host in hosts { group.addTask { await probe(host) } }
            var found: [TVDevice] = []
            for await device in group { if let device { found.append(device) } }
            return found.sorted { $0.name < $1.name }
        }
    }

    /// Asks a host for its Samsung TV description; nil if it isn't one.
    static func probe(_ ip: String) async -> TVDevice? {
        let req = URLRequest(url: URL(string: "http://\(ip):8001/api/v2/")!, timeoutInterval: 3)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = obj["device"] as? [String: Any],
              (info["type"] as? String)?.contains("Samsung") == true
        else { return nil }
        let mac = (info["wifiMac"] as? String) ?? ""
        let duid = (info["duid"] as? String) ?? ip
        return TVDevice(
            id: mac.isEmpty ? duid : mac.uppercased(),
            name: (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Samsung TV",
            model: (info["modelName"] as? String) ?? "",
            ip: ip,
            mac: mac
        )
    }

    private static func ssdpHosts(timeout: TimeInterval) -> Set<String> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)

        let targets = ["urn:dial-multiscreen-org:service:dial:1", "urn:samsung.com:device:RemoteControlReceiver:1"]
        for st in targets {
            let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n"
            let bytes = Array(msg.utf8)
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hosts = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            var addr = from.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN))
            hosts.insert(String(cString: text))
        }
        return hosts
    }
}
