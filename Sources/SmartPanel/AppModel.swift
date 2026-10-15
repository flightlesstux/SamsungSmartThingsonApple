import SwiftUI

@MainActor @Observable
final class AppModel {
    var selection: String
    var showSettings = false
    var stToken: String?
    var tvs: [TVController]
    var scanning = false
    var scanMessage: String?

    /// Every SmartThings device except hubs and TVs that are already controlled locally.
    var cloudDevices: [STDevice] = []
    var cloudError: String?
    var cloudLoading = false

    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// SmartThings twins of local TVs, keyed by local TV id.
    @ObservationIgnored private var allCloud: [STDevice] = []

    /// `demo` skips saved devices, networking and notifications (used to record the README GIF).
    init(demo: Bool = false) {
        let saved = demo ? [] : Settings.savedTVs
        tvs = saved.map(TVController.init)
        selection = UserDefaults.standard.string(forKey: "selection") ?? saved.first?.id ?? ""
        guard !demo else {
            stToken = "demo"
            return
        }
        stToken = Settings.smartThingsToken
        Notifier.shared.start()
        startPolling()
    }

    /// Cloud devices that report a running cycle (menu bar countdown).
    var running: [STDevice] { cloudDevices.filter(\.isRunning) }

    func select(_ id: String) {
        selection = id
        showSettings = false
        UserDefaults.standard.set(id, forKey: "selection")
    }

    /// Keeps the selection valid after devices appear or disappear.
    private func fixSelection() {
        let ids = tvs.map(\.id) + cloudDevices.map(\.id)
        if !ids.contains(selection), let first = ids.first { select(first) }
    }

    // MARK: TV discovery

    /// Concurrent callers share the scan in progress instead of skipping it.
    func scan() async {
        if let scanTask { return await scanTask.value }
        let task = Task {
            scanning = true
            defer { scanning = false }
            let found = await TVDiscovery.discover()
            merge(found)
            scanMessage = found.isEmpty
                ? "No Samsung TVs answered. Check System Settings → Privacy & Security → Local Network."
                : "Found \(found.count) TV\(found.count == 1 ? "" : "s")."
        }
        scanTask = task
        await task.value
        scanTask = nil
    }

    /// Adds a TV that doesn't answer SSDP (e.g. on another subnet).
    func addTV(ip: String) async {
        let ip = ip.trimmingCharacters(in: .whitespaces)
        guard let device = await TVDiscovery.probe(ip) else {
            scanMessage = "No Samsung TV at \(ip)."
            return
        }
        merge([device])
        scanMessage = "Added \(device.name)."
    }

    func removeTV(_ tv: TVController) {
        tvs.removeAll { $0.id == tv.id }
        Settings.setTVToken(nil, for: tv.id)
        persist()
        linkCloud()
        fixSelection()
    }

    private func merge(_ found: [TVDevice]) {
        for device in found {
            if let existing = tvs.first(where: { $0.id == device.id }) {
                existing.update(device)
            } else {
                tvs.append(TVController(device: device))
            }
        }
        persist()
        linkCloud()
        fixSelection()
    }

    private func persist() {
        Settings.savedTVs = tvs.map(\.device)
    }

    // MARK: SmartThings

    func saveToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.smartThingsToken = trimmed.isEmpty ? nil : trimmed
        stToken = Settings.smartThingsToken
        allCloud = []
        cloudDevices = []
        for tv in tvs { tv.cloud = nil }
        Task { await discoverCloud() }
    }

    func discoverCloud() async {
        guard let token = stToken, !token.isEmpty else {
            cloudError = STError.noToken.errorDescription
            return
        }
        cloudLoading = true
        defer { cloudLoading = false }
        do {
            let items = try await SmartThingsAPI(token: token).devices()
            var next: [STDevice] = []
            for item in items {
                guard let id = item["deviceId"] as? String, (item["type"] as? String) != "HUB" else { continue }
                if let existing = allCloud.first(where: { $0.id == id }) {
                    next.append(existing)
                    continue
                }
                let comps = item["components"] as? [[String: Any]] ?? []
                let main = comps.first { $0["id"] as? String == "main" } ?? comps.first ?? [:]
                let categories = (main["categories"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                    .filter { $0 != "Other" }
                let caps = Set(comps.flatMap { ($0["capabilities"] as? [[String: Any]]) ?? [] }.compactMap { $0["id"] as? String })
                let label = (item["label"] as? String) ?? (item["name"] as? String) ?? "Device"
                next.append(STDevice(id: id, kind: STKind.classify(categories: categories, capabilities: caps),
                                     label: label, capabilities: caps,
                                     componentIDs: comps.compactMap { $0["id"] as? String }))
            }
            allCloud = next.sorted { ($0.kind.sortOrder, $0.label) < ($1.kind.sortOrder, $1.label) }
            cloudError = nil
            linkCloud()
            await refreshCloud()
            fixSelection()
        } catch {
            cloudError = error.localizedDescription
        }
    }

    /// Pairs local TVs with their SmartThings twin (same name) for picture/sound mode, inputs and power-on.
    private func linkCloud() {
        var linked = Set<String>()
        for tv in tvs {
            let twin = allCloud.first {
                $0.kind == .television && $0.label.caseInsensitiveCompare(tv.device.name) == .orderedSame
            }
            tv.cloud = twin
            if let twin { linked.insert(twin.id) }
        }
        cloudDevices = allCloud.filter { !linked.contains($0.id) }
    }

    func refreshCloud() async {
        let token = stToken
        await withTaskGroup(of: Void.self) { group in
            for device in allCloud { group.addTask { await device.refresh(token: token) } }
        }
    }

    // MARK: Polling

    private func startPolling() {
        poller = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                // Rediscover on launch and every 5 minutes to follow DHCP changes and new devices;
                // every 30 s while no TVs are known (e.g. until Local Network access is granted).
                if tick % 60 == 0 || (self.tvs.isEmpty && tick % 6 == 0) { await self.scan() }
                if tick % 60 == 0 || (self.allCloud.isEmpty && self.stToken != nil && tick % 6 == 0) {
                    await self.discoverCloud()
                } else if tick % 4 == 0 {
                    await self.refreshCloud()
                }
                await withTaskGroup(of: Void.self) { group in
                    for tv in self.tvs { group.addTask { await tv.refresh() } }
                }
                tick += 1
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

@main
struct SmartPanelApp: App {
    @State private var model = AppModel(demo: CommandLine.arguments.contains("--demo-frames"))

    init() {
        let args = CommandLine.arguments
        let model = self.model

        // `SmartPanel --demo-frames <dir>` renders the scripted README walkthrough as PNG frames and exits.
        if let i = args.firstIndex(of: "--demo-frames"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                let recorder = DemoRecorder(dir: dir)
                recorder.run()
                exit(0)
            }
        }

        // `SmartPanel --send <tv name or ip> <KEY>` sends one remote key and exits.
        if let i = args.firstIndex(of: "--send"), i + 2 < args.count {
            let target = args[i + 1], key = args[i + 2]
            Task { @MainActor in
                if model.tvs.isEmpty { await model.scan() }
                guard let tv = model.tvs.first(where: { $0.device.name == target || $0.device.ip == target }) else {
                    print("no TV named \(target)")
                    exit(1)
                }
                await tv.send(key)
                print(tv.message ?? "sent \(key)")
                try? await Task.sleep(for: .milliseconds(500))
                exit(0)
            }
        }

        // `SmartPanel --snapshot <dir>` renders every panel to PNG and exits (used for visual checks).
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                for id in model.tvs.map(\.id) + model.cloudDevices.map(\.id) + ["settings"] {
                    if id == "settings" { model.showSettings = true } else { model.select(id) }
                    let renderer = ImageRenderer(content: PanelView(model: model))
                    renderer.scale = 2
                    if let tiff = renderer.nsImage?.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        let name = model.tvs.first { $0.id == id }?.device.name ?? model.cloudDevices.first { $0.id == id }?.label ?? id
                        try? png.write(to: dir.appendingPathComponent("\(name).png"))
                    }
                }
                exit(0)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        if let running = model.running.first {
            Image(systemName: running.symbol)
            if let m = running.remainingMinutes { Text("\(m)m") }
        } else if let tv = model.tvs.first(where: { $0.isOn }) {
            Image(systemName: "av.remote")
            Text("\(Int(tv.volume))")
        } else {
            Image(systemName: "av.remote")
        }
    }
}
