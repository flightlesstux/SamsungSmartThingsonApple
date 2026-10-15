import SwiftUI

struct PanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            DeviceSwitcher(model: model)
            if model.showSettings {
                SettingsView(model: model)
            } else if let tv = model.tvs.first(where: { $0.id == model.selection }) {
                TVPanel(tv: tv, model: model)
            } else if let device = model.cloudDevices.first(where: { $0.id == model.selection }) {
                CloudPanel(device: device, model: model)
            } else {
                EmptyPanel(model: model)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(Theme.bg)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.2), value: model.selection)
        .animation(.snappy(duration: 0.2), value: model.showSettings)
    }
}

struct DeviceSwitcher: View {
    let model: AppModel

    private var items: [(id: String, name: String, symbol: String, live: Bool)] {
        model.tvs.map { ($0.id, $0.device.shortName, $0.device.symbol, $0.isOn) }
            + model.cloudDevices.map { ($0.id, Self.short($0.label), $0.symbol, $0.isRunning || ($0.hasSwitch && $0.isOn)) }
    }

    private static func short(_ name: String) -> String {
        name.count <= 12 ? name : String(name.prefix(11)) + "…"
    }

    var body: some View {
        // Wraps onto more rows as devices are added.
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.id) { item in
                let selected = item.id == model.selection && !model.showSettings
                Button { model.select(item.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: item.symbol).font(.system(size: 12))
                        Text(item.name).font(.system(size: 12, weight: .medium))
                        if item.live { Circle().fill(.green).frame(width: 5, height: 5) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(selected ? Color.white.opacity(0.16) : Theme.tile, in: Capsule())
                    .overlay(Capsule().stroke(Theme.stroke))
                    .foregroundStyle(selected ? .white : Theme.secondary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - TV

struct TVPanel: View {
    let tv: TVController
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: tv.device.symbol).foregroundStyle(Theme.secondary)
                Text(tv.device.name).font(.system(size: 15, weight: .medium))
                Text(tv.device.model).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                CircleButton(symbol: "power", size: 42, tint: tv.isOn ? .white : Theme.secondary,
                             highlighted: tv.isOn) { Task { await togglePower() } }
            }

            HeroGlyph(symbol: tv.device.symbol, active: tv.isOn,
                      caption: tv.isOn ? (tv.foregroundApp ?? "Live TV") : (tv.power == .standby ? "Standby" : "Off"))

            HStack(alignment: .center) {
                BigReadout(value: tv.isOn ? "\(Int(tv.volume))" : "--", unit: "vol")
                Spacer()
                Card(padding: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: tv.muted ? "speaker.slash.fill" : "speaker.wave.2")
                            .frame(width: 22)
                        Text("Mute").font(.system(size: 14, weight: .medium))
                        PillSwitch(isOn: tv.muted) { Task { await tv.setMuted(!tv.muted) } }
                    }
                }
                .disabled(!tv.isOn)
            }

            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    CircleButton(symbol: "minus") { tv.stepVolume(-1) }
                    GlassSlider(value: Binding(get: { tv.volume }, set: { _ in }), enabled: tv.isOn) { tv.setVolume($0) }
                    CircleButton(symbol: "plus") { tv.stepVolume(1) }
                }
                .disabled(!tv.isOn)
                HStack {
                    Text("0"); Spacer(); Text("100")
                }
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 54)
            }

            HStack(spacing: 8) {
                if let cloud = tv.cloud, let input = cloud.firstOption(STOption.tvInputs) {
                    OptionTile(device: cloud, option: input, model: model)
                } else {
                    ControlTile(symbol: "rectangle.on.rectangle", title: "Source", value: "Input") {
                        Task { await tv.send("KEY_SOURCE") }
                    }
                }
                ChoiceTile(symbol: "square.grid.2x2", title: "Apps", value: tv.foregroundApp ?? "Home",
                           choices: tv.apps.map { ($0.id, $0.name, $0.symbol) },
                           selected: tv.apps.first { $0.name == tv.foregroundApp }?.id) { id in
                    if let app = tv.apps.first(where: { $0.id == id }) { Task { await tv.launch(app) } }
                }
                ControlTile(symbol: "house", title: "Home", value: "Smart Hub") {
                    Task { await tv.send("KEY_HOME") }
                }
                ControlTile(symbol: "av.remote", title: "Remote", value: tv.showRemote ? "Shown" : "Hidden",
                            dot: tv.showRemote) { tv.showRemote.toggle() }
            }
            .disabled(!tv.isOn)

            if let cloud = tv.cloud, tv.isOn {
                let options = [STOption.tvPicture, STOption.tvSound].compactMap { cloud.firstOption($0) }
                if !options.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(options) { OptionTile(device: cloud, option: $0, model: model) }
                        ControlTile(symbol: "chevron.up.chevron.down", title: "Channel", value: "Up") {
                            Task { await tv.send("KEY_CHUP") }
                        }
                        ControlTile(symbol: "speaker.wave.3", title: "Volume", value: "Up") {
                            Task { await tv.send("KEY_VOLUP") }
                        }
                    }
                }
            }

            if tv.showRemote && tv.isOn { RemotePad(tv: tv) }

            Footer(symbol: tv.isOn ? "checkmark.shield" : "wifi.slash",
                   text: tv.pairing ? "Press Allow on the TV…" : (tv.message ?? statusText),
                   tint: tv.message == nil ? Theme.secondary : .orange) { model.showSettings = true }
        }
    }

    /// Local Wake-on-LAN first; the SmartThings twin can also power the TV on from deep standby.
    private func togglePower() async {
        if !tv.isOn, let cloud = tv.cloud, cloud.hasSwitch {
            await cloud.run("switch", "on", token: model.stToken)
            try? await Task.sleep(for: .seconds(3))
            await tv.refresh()
            if tv.isOn { return }
        }
        await tv.togglePower()
    }

    private var statusText: String {
        switch tv.power {
        case .on: tv.cloud == nil ? "Connected" : "Connected · SmartThings linked"
        case .standby: "Standby · tap power to wake"
        case .off: "Offline · tap power to wake"
        case .unknown: "Connecting…"
        }
    }
}

struct RemotePad: View {
    let tv: TVController

    var body: some View {
        Card(padding: 12) {
            HStack(spacing: 18) {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        key("arrow.uturn.backward", "KEY_RETURN", small: true)
                        key("chevron.up", "KEY_UP")
                        key("house", "KEY_HOME", small: true)
                    }
                    GridRow {
                        key("chevron.left", "KEY_LEFT")
                        CircleButton(symbol: "circle.fill", size: 40, highlighted: true) { send("KEY_ENTER") }
                        key("chevron.right", "KEY_RIGHT")
                    }
                    GridRow {
                        Color.clear.frame(width: 34, height: 34)
                        key("chevron.down", "KEY_DOWN")
                        Color.clear.frame(width: 34, height: 34)
                    }
                }
                VStack(spacing: 6) {
                    key("chevron.up.2", "KEY_CHUP", small: true)
                    Text("CH").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.secondary)
                    key("chevron.down.2", "KEY_CHDOWN", small: true)
                }
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        key("backward.fill", "KEY_REWIND", small: true)
                        key("forward.fill", "KEY_FF", small: true)
                    }
                    HStack(spacing: 6) {
                        key("play.fill", "KEY_PLAY", small: true)
                        key("pause.fill", "KEY_PAUSE", small: true)
                    }
                    HStack(spacing: 6) {
                        key("info.circle", "KEY_INFO", small: true)
                        key("gearshape", "KEY_MENU", small: true)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func key(_ symbol: String, _ code: String, small: Bool = false) -> some View {
        CircleButton(symbol: symbol, size: small ? 30 : 40) { send(code) }
    }

    private func send(_ code: String) { Task { await tv.send(code) } }
}

// MARK: - Settings

struct SettingsView: View {
    let model: AppModel
    @State private var token = ""
    @State private var manualIP = ""
    @State private var notifyDone = Settings.notifyDone
    @State private var notifySoon = Settings.notifySoon

    private func addManual() {
        let ip = manualIP
        manualIP = ""
        Task { await model.addTV(ip: ip) }
    }

    private func notifyRow(_ title: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            PillSwitch(isOn: isOn, action: toggle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.system(size: 17, weight: .semibold))

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("SmartThings token", systemImage: "key").font(.system(size: 13, weight: .medium))
                    Text(model.stToken == nil ? "Not set" : "Saved in Keychain")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    SecureField("Personal access token", text: $token)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Link("Create token…", destination: URL(string: "https://account.smartthings.com/tokens")!)
                            .font(.system(size: 11))
                        Spacer()
                        if model.stToken != nil {
                            Button("Remove") { model.saveToken("") }.controlSize(.small)
                        }
                        Button("Save") { model.saveToken(token); token = "" }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(token.isEmpty)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("TVs (local network)", systemImage: "tv").font(.system(size: 13, weight: .medium))
                        Spacer()
                        if model.scanning { ProgressView().controlSize(.mini) }
                        Button("Scan") { Task { await model.scan() } }
                            .controlSize(.small)
                            .disabled(model.scanning)
                    }
                    if model.tvs.isEmpty {
                        Text("No TVs yet. Scan finds Samsung TVs on this network automatically.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.tvs) { tv in
                        HStack {
                            Text(tv.device.name).font(.system(size: 12))
                            Text(tv.device.model).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                            Spacer()
                            Button(tv.pairing ? "Allow on TV…" : "Pair") { Task { await tv.repair() } }
                                .controlSize(.small)
                                .disabled(tv.pairing)
                            Button {
                                model.removeTV(tv)
                            } label: { Image(systemName: "trash") }
                                .controlSize(.small)
                        }
                    }
                    HStack {
                        TextField("Add by IP address", text: $manualIP)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addManual)
                        Button("Add", action: addManual)
                            .controlSize(.small)
                            .disabled(manualIP.isEmpty)
                    }
                    if let msg = model.scanMessage {
                        Text(msg).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Notifications", systemImage: "bell").font(.system(size: 13, weight: .medium))
                        Spacer()
                        Button("Test") { Notifier.shared.sendTest() }.controlSize(.small)
                    }
                    notifyRow("When a cycle finishes", isOn: notifyDone) {
                        notifyDone.toggle()
                        Settings.notifyDone = notifyDone
                    }
                    notifyRow("\(Notifier.soonMinutes) minutes before the end", isOn: notifySoon) {
                        notifySoon.toggle()
                        Settings.notifySoon = notifySoon
                    }
                    Text("Washer, dryer, dishwasher, oven and robot vacuum. A stuck vacuum always alerts.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }

            HStack {
                Button("Done") { model.showSettings = false }
                Spacer()
                Button("Quit SmartPanel") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
    }
}
