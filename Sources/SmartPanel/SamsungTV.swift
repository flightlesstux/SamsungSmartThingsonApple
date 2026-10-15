import Foundation

enum PowerState: String {
    case on, standby, off, unknown
}

struct TVApp: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String

    static let candidates: [TVApp] = [
        TVApp(id: "111299001912", name: "YouTube", symbol: "play.rectangle.fill"),
        TVApp(id: "3201907018807", name: "Netflix", symbol: "n.square.fill"),
        TVApp(id: "3201910019365", name: "Prime Video", symbol: "p.square.fill"),
        TVApp(id: "3201901017640", name: "Disney+", symbol: "sparkles.tv.fill"),
        TVApp(id: "3201807016597", name: "Apple TV", symbol: "applelogo"),
        TVApp(id: "3201606009684", name: "Spotify", symbol: "music.note"),
        TVApp(id: "3202203026841", name: "Twitch", symbol: "gamecontroller.fill"),
        TVApp(id: "3201512006963", name: "Plex", symbol: "film.stack.fill"),
        TVApp(id: "3201710015037", name: "Samsung TV Plus", symbol: "tv.inset.filled"),
    ]
}

enum TVError: LocalizedError {
    case unauthorized, noConnection

    var errorDescription: String? {
        switch self {
        case .unauthorized: "TV rejected the connection. Re-pair in settings."
        case .noConnection: "TV not reachable."
        }
    }
}

/// Accepts the self-signed certificate that Samsung TVs serve on port 8002, only for the one TV host.
final class LANTrust: NSObject, URLSessionDelegate {
    let host: String

    init(host: String) {
        self.host = host
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           space.host == host,
           let trust = space.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}

@MainActor @Observable
final class TVController: Identifiable {
    nonisolated let id: String
    private(set) var device: TVDevice

    var power: PowerState = .unknown
    var volume: Double = 0
    var muted = false
    var apps: [TVApp] = []
    var foregroundApp: String?
    var message: String?
    var pairing = false
    var showRemote = false
    /// SmartThings twin of this TV, when the account has one (picture/sound mode, inputs, power-on).
    var cloud: STDevice?

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var connecting: Task<URLSessionWebSocketTask, Error>?
    @ObservationIgnored private var session: URLSession
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var lastLocalChange = Date.distantPast
    @ObservationIgnored private var appsProbed = false

    init(device: TVDevice) {
        id = device.id
        self.device = device
        session = Self.makeSession(device.ip)
    }

    private static func makeSession(_ ip: String) -> URLSession {
        URLSession(configuration: .ephemeral, delegate: LANTrust(host: ip), delegateQueue: nil)
    }

    /// Picks up a new name or DHCP address from discovery.
    func update(_ newDevice: TVDevice) {
        guard newDevice != device else { return }
        if newDevice.ip != device.ip {
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            session = Self.makeSession(newDevice.ip)
        }
        device = newDevice
    }

    var isOn: Bool { power == .on }

    // MARK: Polling

    func refresh() async {
        power = await fetchPower()
        guard power == .on else {
            foregroundApp = nil
            return
        }
        // Don't fight the slider while the user is dragging it.
        if Date().timeIntervalSince(lastLocalChange) > 3 {
            if let v = await UPnP.getVolume(device.ip) { volume = Double(v) }
            if let m = await UPnP.getMute(device.ip) { muted = m }
        }
        await refreshApps()
    }

    private func fetchPower() async -> PowerState {
        let req = URLRequest(url: URL(string: "http://\(device.ip):8001/api/v2/")!, timeoutInterval: 2)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .off }
        let state = (obj["device"] as? [String: Any])?["PowerState"] as? String
        return state == "standby" ? .standby : .on
    }

    private func refreshApps() async {
        let probe = appsProbed ? apps : TVApp.candidates
        let ip = device.ip
        let results = await withTaskGroup(of: (TVApp, Bool?).self) { group in
            for app in probe {
                group.addTask {
                    let req = URLRequest(url: URL(string: "http://\(ip):8001/api/v2/applications/\(app.id)")!, timeoutInterval: 2)
                    guard let (data, resp) = try? await URLSession.shared.data(for: req),
                          (resp as? HTTPURLResponse)?.statusCode == 200,
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { return (app, nil) }
                    return (app, obj["visible"] as? Bool ?? false)
                }
            }
            var out: [(TVApp, Bool?)] = []
            for await r in group { out.append(r) }
            return out
        }
        let installed = results.filter { $0.1 != nil }
        if !appsProbed, !installed.isEmpty {
            apps = TVApp.candidates.filter { app in installed.contains { $0.0 == app } }
            appsProbed = true
        }
        foregroundApp = installed.first { $0.1 == true }?.0.name
    }

    // MARK: Commands

    func togglePower() async {
        if power == .on {
            await send("KEY_POWER")
            power = .standby
            return
        }
        WakeOnLAN.send(mac: device.mac, ip: device.ip)
        message = "Waking…"
        try? await Task.sleep(for: .seconds(3))
        if await fetchPower() == .standby { await send("KEY_POWER") }
        try? await Task.sleep(for: .seconds(2))
        message = nil
        await refresh()
    }

    func setVolume(_ value: Double) {
        volume = value
        lastLocalChange = Date()
        volumeTask?.cancel()
        let ip = device.ip
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await UPnP.setVolume(ip, Int(value.rounded()))
        }
    }

    func stepVolume(_ delta: Double) {
        setVolume(min(100, max(0, volume + delta)))
    }

    func setMuted(_ value: Bool) async {
        muted = value
        lastLocalChange = Date()
        await UPnP.setMute(device.ip, value)
    }

    func launch(_ app: TVApp) async {
        var req = URLRequest(url: URL(string: "http://\(device.ip):8001/api/v2/applications/\(app.id)")!, timeoutInterval: 3)
        req.httpMethod = "POST"
        if let (_, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            foregroundApp = app.name
            return
        }
        // Newer firmware: launch through the remote-control channel instead.
        let payload: [String: Any] = [
            "method": "ms.channel.emit",
            "params": ["event": "ed.apps.launch", "to": "host",
                       "data": ["appId": app.id, "action_type": "DEEP_LINK"]],
        ]
        await sendJSON(payload)
        foregroundApp = app.name
    }

    func send(_ key: String) async {
        await sendJSON([
            "method": "ms.remote.control",
            "params": ["Cmd": "Click", "DataOfCmd": key, "Option": "false", "TypeOfRemote": "SendRemoteKey"],
        ])
    }

    func repair() async {
        Settings.setTVToken(nil, for: device.id)
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        _ = try? await connectedSocket()
    }

    private func sendJSON(_ payload: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        do {
            let ws = try await connectedSocket()
            try await ws.send(.string(text))
            message = nil
        } catch {
            socket = nil
            message = (error as? TVError)?.errorDescription ?? "Remote unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: WebSocket

    private func connectedSocket() async throws -> URLSessionWebSocketTask {
        if let socket, socket.state == .running { return socket }
        if let connecting { return try await connecting.value }
        let task = Task { try await openSocket() }
        connecting = task
        defer { connecting = nil }
        let ws = try await task.value
        socket = ws
        return ws
    }

    private func openSocket() async throws -> URLSessionWebSocketTask {
        let name = Data("MacRemote".utf8).base64EncodedString()
        var url = "wss://\(device.ip):8002/api/v2/channels/samsung.remote.control?name=\(name)"
        let token = Settings.tvToken(device.id)
        if let token { url += "&token=\(token)" } else { pairing = true }
        defer { pairing = false }

        let ws = session.webSocketTask(with: URL(string: url)!)
        ws.resume()
        // Pairing waits for a human to press "Allow" on the TV.
        let watchdog = Task {
            guard (try? await Task.sleep(for: .seconds(token == nil ? 35 : 6))) != nil else { return }
            ws.cancel(with: .goingAway, reason: nil)
        }
        defer { watchdog.cancel() }

        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await ws.receive() } catch { throw TVError.noConnection }
            guard case .string(let text) = message,
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let event = obj["event"] as? String else { continue }
            switch event {
            case "ms.channel.connect":
                if let newToken = (obj["data"] as? [String: Any])?["token"] as? String {
                    Settings.setTVToken(newToken, for: device.id)
                }
                drain(ws)
                return ws
            case "ms.channel.unauthorized", "ms.channel.timeOut":
                ws.cancel(with: .goingAway, reason: nil)
                throw TVError.unauthorized
            default:
                continue
            }
        }
    }

    /// Keeps reading so the TV's broadcast events don't pile up, and drops the socket when it closes.
    private func drain(_ ws: URLSessionWebSocketTask) {
        Task { [weak self] in
            while true {
                do { _ = try await ws.receive() } catch {
                    if self?.socket === ws { self?.socket = nil }
                    return
                }
            }
        }
    }
}

// MARK: - UPnP RenderingControl (absolute volume / mute on port 9197)

enum UPnP {
    private static func call(_ ip: String, _ action: String, _ args: String = "") async -> String? {
        let body = """
        <?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) \
        xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><InstanceID>0</InstanceID>\
        <Channel>Master</Channel>\(args)</u:\(action)></s:Body></s:Envelope>
        """
        var req = URLRequest(url: URL(string: "http://\(ip):9197/upnp/control/RenderingControl1")!, timeoutInterval: 3)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:RenderingControl:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = Data(body.utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let start = xml.range(of: "<\(name)>"),
              let end = xml.range(of: "</\(name)>", range: start.upperBound..<xml.endIndex) else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }

    static func getVolume(_ ip: String) async -> Int? {
        guard let xml = await call(ip, "GetVolume") else { return nil }
        return tag("CurrentVolume", in: xml).flatMap { Int($0) }
    }

    static func setVolume(_ ip: String, _ value: Int) async {
        _ = await call(ip, "SetVolume", "<DesiredVolume>\(value)</DesiredVolume>")
    }

    static func getMute(_ ip: String) async -> Bool? {
        guard let xml = await call(ip, "GetMute") else { return nil }
        return tag("CurrentMute", in: xml).map { $0 == "1" }
    }

    static func setMute(_ ip: String, _ value: Bool) async {
        _ = await call(ip, "SetMute", "<DesiredMute>\(value ? 1 : 0)</DesiredMute>")
    }
}

// MARK: - Wake-on-LAN

enum WakeOnLAN {
    static func send(mac: String, ip: String) {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet += bytes }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        for target in ["255.255.255.255", ip] {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(9).bigEndian
            inet_pton(AF_INET, target, &addr.sin_addr)
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
}
