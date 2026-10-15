import SwiftUI

/// Routes a SmartThings device to the panel that fits its kind.
struct CloudPanel: View {
    let device: STDevice
    let model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            switch device.kind {
            case .washer, .dryer, .dishwasher, .oven: CyclePanel(device: device, model: model)
            case .airConditioner: ClimatePanel(device: device, model: model)
            case .refrigerator: FridgePanel(device: device, model: model)
            case .robotCleaner: VacuumPanel(device: device, model: model)
            case .airPurifier: PurifierPanel(device: device, model: model)
            case .television, .speaker: MediaPanel(device: device, model: model)
            case .light, .plug, .lock, .sensor, .other: GenericPanel(device: device, model: model)
            }
            CloudFooter(device: device, model: model)
        }
    }
}

struct EmptyPanel: View {
    let model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("No devices yet").font(.system(size: 15, weight: .semibold))
                Text("TVs on this network appear automatically. Add a SmartThings token to bring in appliances, climate, lights and sensors.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Button("Open settings") { model.showSettings = true }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 30)
    }
}

// MARK: - Shared pieces

struct DeviceHeader: View {
    let device: STDevice
    let subtitle: String?
    let model: AppModel

    var body: some View {
        HStack {
            Image(systemName: device.symbol).foregroundStyle(Theme.secondary)
            Text(device.label).font(.system(size: 15, weight: .medium)).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            if device.hasSwitch {
                CircleButton(symbol: "power", size: 42, tint: device.isOn ? .white : Theme.secondary,
                             highlighted: device.isOn) { Task { await device.togglePower(token: model.stToken) } }
            }
        }
    }
}

struct CloudFooter: View {
    let device: STDevice
    let model: AppModel

    var body: some View {
        Footer(symbol: device.error == nil ? "cloud" : "exclamationmark.triangle",
               text: device.error ?? updated,
               tint: device.error == nil ? Theme.secondary : .orange) { model.showSettings = true }
    }

    private var updated: String {
        guard let t = device.lastUpdate else { return "SmartThings · connecting…" }
        return "SmartThings · updated \(t.formatted(date: .omitted, time: .shortened))"
    }
}

/// Choice tile bound to a SmartThings capability attribute.
struct OptionTile: View {
    let device: STDevice
    let option: STOption
    let model: AppModel

    var body: some View {
        let choices = option.command == nil || !device.remoteEnabled ? [] : device.choices(option)
        ChoiceTile(symbol: option.symbol, title: option.title, value: device.display(option) ?? "—",
                   choices: choices.map { (id: $0.id, label: $0.label, symbol: String?.none) },
                   selected: device.string(option.capability, option.attribute, option.component)) { pick in
            Task { await device.set(option, to: pick, token: model.stToken) }
        }
    }
}

/// Read-only tile for a sensor value.
struct ReadingTile: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        ControlTile(symbol: symbol, title: title, value: value)
    }
}

/// A row of option tiles, padded to four columns so tiles keep the same width everywhere.
struct TileRow: View {
    let device: STDevice
    let options: [STOption]
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { OptionTile(device: device, option: $0, model: model) }
            ForEach(0..<max(0, 4 - options.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
        }
    }
}

/// Debounced numeric setpoint: the slider moves immediately, the command is sent once it settles.
@MainActor @Observable
final class SetpointDraft {
    var value: Double?
    @ObservationIgnored private var task: Task<Void, Never>?

    func change(to v: Double, commit: @escaping (Double) async -> Void) {
        value = v
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await commit(v)
            self.value = nil
        }
    }
}

private func formatTemp(_ v: Double?) -> String {
    guard let v else { return "--" }
    return v.rounded() == v ? "\(Int(v))" : String(format: "%.1f", v)
}

/// Fahrenheit if the device reports values that only make sense in °F.
private func tempUnit(_ v: Double?) -> String {
    (v ?? 0) > 45 ? "°F" : "°C"
}

// MARK: - Washer / dryer / dishwasher / oven

struct CyclePanel: View {
    let device: STDevice
    let model: AppModel

    var body: some View {
        DeviceHeader(device: device, subtitle: stateText, model: model)

        HeroGlyph(symbol: device.symbol, active: device.isOn || device.isRunning, animate: device.isRunning,
                  caption: device.jobState)

        HStack(alignment: .center) {
            if let m = device.remainingMinutes {
                BigReadout(value: "\(m)", unit: "min")
            } else {
                BigReadout(value: device.isOn ? "Ready" : "Off", unit: "")
            }
            Spacer()
            Card(padding: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "iphone.radiowaves.left.and.right").frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Remote").font(.system(size: 14, weight: .medium))
                        Text(device.remoteEnabled ? "Enabled" : "Off on device")
                            .font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    }
                    Circle().fill(device.remoteEnabled ? Color.green : Theme.tertiary).frame(width: 7, height: 7)
                }
            }
        }

        VStack(spacing: 6) {
            HStack(spacing: 10) {
                CircleButton(symbol: "stop.fill") {
                    Task { await device.setMachineState("stop", token: model.stToken) }
                }
                GlassSlider(value: .constant(device.progress * 100), enabled: false)
                    .opacity(device.isOn || device.isRunning ? 1 : 0.4)
                CircleButton(symbol: device.isRunning ? "pause.fill" : "play.fill", highlighted: device.isRunning) {
                    Task { await device.setMachineState(device.isRunning ? "pause" : "run", token: model.stToken) }
                }
            }
            .disabled(!device.remoteEnabled)
            HStack {
                Text("\(Int(device.progress * 100))%")
                Spacer()
                if let done = device.completion { Text("Done at \(done.formatted(date: .omitted, time: .shortened))") }
            }
            .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 54)
        }

        TileRow(device: device, options: device.cycleOptions, model: model)
    }

    private var stateText: String {
        switch device.machineState {
        case "run": "Running"
        case "pause": "Paused"
        default: device.isOn ? "Idle" : "Off"
        }
    }
}

// MARK: - Air conditioner

struct ClimatePanel: View {
    let device: STDevice
    let model: AppModel
    @State private var draft = SetpointDraft()

    private var room: Double? { device.number("temperatureMeasurement", "temperature") }
    private var setpoint: Double? { draft.value ?? device.number("thermostatCoolingSetpoint", "coolingSetpoint") }
    private var range: ClosedRange<Double> {
        let lo = device.number("custom.thermostatSetpointControl", "minimumSetpoint")
        let hi = device.number("custom.thermostatSetpointControl", "maximumSetpoint")
        if let lo, let hi, lo < hi { return lo...hi }
        return tempUnit(setpoint) == "°F" ? 60...86 : 16...30
    }
    private var optionalMode: String? { device.string("custom.airConditionerOptionalMode", "acOptionalMode") }

    var body: some View {
        HStack {
            Image(systemName: "thermometer.medium").foregroundStyle(Theme.secondary)
            Text("Room").font(.system(size: 15, weight: .medium))
            Text("\(formatTemp(room))\(tempUnit(room))").font(.system(size: 15, weight: .semibold))
            Text(device.label).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
            Spacer()
            CircleButton(symbol: "power", size: 42, tint: device.isOn ? .white : Theme.secondary,
                         highlighted: device.isOn) { Task { await device.togglePower(token: model.stToken) } }
        }

        HeroGlyph(symbol: device.symbol, active: device.isOn, animate: device.isOn,
                  caption: device.isOn ? device.string("airConditionerMode", "airConditionerMode").map(STDevice.pretty) : "Off")

        HStack(alignment: .center) {
            BigReadout(value: formatTemp(setpoint), unit: tempUnit(setpoint))
            Spacer()
            if device.has("custom.airConditionerOptionalMode") {
                Card(padding: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "leaf").frame(width: 22)
                        Text("Eco Mode").font(.system(size: 14, weight: .medium))
                        PillSwitch(isOn: optionalMode == "energySaving") { setOptional("energySaving") }
                    }
                }
            }
        }
        .disabled(!device.isOn)

        VStack(spacing: 6) {
            HStack(spacing: 10) {
                CircleButton(symbol: "minus") { step(-1) }
                GlassSlider(value: .constant(setpoint ?? range.lowerBound), range: range, enabled: device.isOn) { v in
                    draft.change(to: v, commit: commit)
                }
                CircleButton(symbol: "plus") { step(1) }
            }
            HStack {
                Text("\(Int(range.lowerBound))°"); Spacer(); Text("\(Int(range.upperBound))°")
            }
            .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 54)
        }
        .disabled(!device.isOn)

        HStack(spacing: 8) {
            OptionTile(device: device, option: STOption(title: "Mode", symbol: "snowflake", capability: "airConditionerMode",
                                                        attribute: "airConditionerMode", supported: "supportedAcModes",
                                                        command: "setAirConditionerMode"), model: model)
            OptionTile(device: device, option: STOption(title: "Fan speed", symbol: "fan", capability: "airConditionerFanMode",
                                                        attribute: "fanMode", supported: "supportedAcFanModes",
                                                        command: "setFanMode"), model: model)
            ControlTile(symbol: "moon", title: "Sleep", value: optionalMode == "sleep" ? "On" : "Off",
                        dot: optionalMode == "sleep") { setOptional("sleep") }
            OptionTile(device: device, option: STOption(title: "Airflow", symbol: "wind", capability: "fanOscillationMode",
                                                        attribute: "fanOscillationMode", supported: "supportedFanOscillationModes",
                                                        command: "setFanOscillationMode"), model: model)
        }
        .disabled(!device.isOn)
    }

    private func step(_ delta: Double) {
        guard let current = setpoint else { return }
        draft.change(to: min(range.upperBound, max(range.lowerBound, current + delta)), commit: commit)
    }

    private func commit(_ v: Double) async {
        await device.run("thermostatCoolingSetpoint", "setCoolingSetpoint", [v], token: model.stToken)
    }

    private func setOptional(_ mode: String) {
        let next = optionalMode == mode ? "off" : mode
        Task { await device.run("custom.airConditionerOptionalMode", "setAcOptionalMode", [next], token: model.stToken) }
    }
}

// MARK: - Refrigerator

struct FridgePanel: View {
    let device: STDevice
    let model: AppModel

    private var compartments: [(id: String, title: String, symbol: String)] {
        [("cooler", "Fridge", "refrigerator"), ("freezer", "Freezer", "snowflake"), ("onedoor", "Compartment", "refrigerator")]
            .filter { device.has("thermostatCoolingSetpoint", $0.0) || device.has("temperatureMeasurement", $0.0) }
    }

    private var doorOpen: Bool {
        device.componentIDs.contains { device.string("contactSensor", "contact", $0) == "open" }
    }

    var body: some View {
        DeviceHeader(device: device, subtitle: doorOpen ? "Door open" : "Closed", model: model)

        HeroGlyph(symbol: "refrigerator", active: true, animate: doorOpen, caption: doorOpen ? "Door open" : nil)

        ForEach(compartments, id: \.id) { comp in
            CompartmentRow(device: device, component: comp.id, title: comp.title, symbol: comp.symbol, model: model)
        }

        HStack(spacing: 8) {
            boostTile(title: "Power Cool", symbol: "snowflake", rapid: "rapidCooling", rapidCmd: "setRapidCooling",
                      ce: "samsungce.powerCool")
            boostTile(title: "Power Freeze", symbol: "snowflake.circle", rapid: "rapidFreezing", rapidCmd: "setRapidFreezing",
                      ce: "samsungce.powerFreeze")
            ReadingTile(symbol: "door.left.hand.open", title: "Door", value: doorOpen ? "Open" : "Closed")
            ReadingTile(symbol: "drop", title: "Water filter",
                        value: device.number("custom.waterFilter", "waterFilterUsage").map { "\(100 - Int($0))% left" } ?? "—")
        }
    }

    /// Supports both the classic `refrigeration` capability and newer `samsungce.powerCool/powerFreeze`.
    private func boostTile(title: String, symbol: String, rapid: String, rapidCmd: String, ce: String) -> some View {
        let on: Bool
        if device.has("refrigeration") {
            on = device.string("refrigeration", rapid) == "on"
        } else {
            on = device.value(ce, "activated") as? Bool ?? false
        }
        return ControlTile(symbol: symbol, title: title, value: on ? "On" : "Off", dot: on) {
            Task {
                if device.has("refrigeration") {
                    await device.run("refrigeration", rapidCmd, [on ? "off" : "on"], token: model.stToken)
                } else {
                    await device.run(ce, on ? "deactivate" : "activate", token: model.stToken)
                }
            }
        }
    }
}

struct CompartmentRow: View {
    let device: STDevice
    let component: String
    let title: String
    let symbol: String
    let model: AppModel
    @State private var draft = SetpointDraft()

    private var current: Double? { device.number("temperatureMeasurement", "temperature", component) }
    private var setpoint: Double? { draft.value ?? device.number("thermostatCoolingSetpoint", "coolingSetpoint", component) }

    var body: some View {
        Card(padding: 12) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 20, weight: .light)).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text("Now \(formatTemp(current))\(tempUnit(current))")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer()
                CircleButton(symbol: "minus", size: 32) { step(-1) }
                Text("\(formatTemp(setpoint))\(tempUnit(setpoint))")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 76)
                CircleButton(symbol: "plus", size: 32) { step(1) }
            }
        }
    }

    private func step(_ delta: Double) {
        guard let s = setpoint else { return }
        let lo = device.number("custom.thermostatSetpointControl", "minimumSetpoint", component) ?? -30
        let hi = device.number("custom.thermostatSetpointControl", "maximumSetpoint", component) ?? 10
        let next = min(hi, max(lo, s + delta))
        draft.change(to: next) { v in
            await device.run("thermostatCoolingSetpoint", "setCoolingSetpoint", [v], component: component, token: model.stToken)
        }
    }
}

// MARK: - Robot vacuum

struct VacuumPanel: View {
    let device: STDevice
    let model: AppModel

    private var movement: String? { device.string("robotCleanerMovement", "robotCleanerMovement") }
    private var battery: Double? { device.number("battery", "battery") }

    var body: some View {
        DeviceHeader(device: device, subtitle: movement.map(STDevice.pretty), model: model)

        HeroGlyph(symbol: device.symbol, active: true, animate: device.isRunning, caption: movement.map(STDevice.pretty))

        HStack(alignment: .center) {
            BigReadout(value: battery.map { "\(Int($0))" } ?? "--", unit: "%")
            Spacer()
            Card(padding: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "bolt").frame(width: 22)
                    Text("Turbo").font(.system(size: 14, weight: .medium))
                    let turbo = device.string("robotCleanerTurboMode", "robotCleanerTurboMode") == "on"
                    PillSwitch(isOn: turbo) {
                        Task {
                            await device.run("robotCleanerTurboMode", "setRobotCleanerTurboMode", [turbo ? "off" : "on"],
                                             token: model.stToken)
                        }
                    }
                }
            }
        }

        HStack(spacing: 10) {
            actionButton("Clean", "play.fill", highlighted: device.isRunning) {
                await device.run("robotCleanerCleaningMode", "setRobotCleanerCleaningMode", ["auto"], token: model.stToken)
            }
            actionButton("Pause", "pause.fill") {
                await device.run("robotCleanerMovement", "setRobotCleanerMovement", ["pause"], token: model.stToken)
            }
            actionButton("Dock", "house.fill") {
                await device.run("robotCleanerMovement", "setRobotCleanerMovement", ["homing"], token: model.stToken)
            }
        }

        TileRow(device: device, options: [
            STOption(title: "Mode", symbol: "arrow.up.and.down.and.arrow.left.and.right",
                     capability: "robotCleanerCleaningMode", attribute: "robotCleanerCleaningMode",
                     command: "setRobotCleanerCleaningMode", fixedChoices: ["auto", "part", "repeat", "manual", "map"]),
            STOption(title: "Suction", symbol: "wind", capability: "robotCleanerTurboMode",
                     attribute: "robotCleanerTurboMode", command: "setRobotCleanerTurboMode",
                     fixedChoices: ["off", "on", "silence"]),
            STOption(title: "Status", symbol: "info.circle", capability: "robotCleanerMovement", attribute: "robotCleanerMovement"),
            STOption(title: "Battery", symbol: "battery.75percent", capability: "battery", attribute: "battery"),
        ], model: model)
    }

    private func actionButton(_ title: String, _ symbol: String, highlighted: Bool = false,
                              _ action: @escaping () async -> Void) -> some View {
        VStack(spacing: 4) {
            CircleButton(symbol: symbol, size: 48, highlighted: highlighted) { Task { await action() } }
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Air purifier

struct PurifierPanel: View {
    let device: STDevice
    let model: AppModel

    private var pm25: Double? { device.number("dustSensor", "fineDustLevel") ?? device.number("fineDustSensor", "fineDustLevel") }

    var body: some View {
        DeviceHeader(device: device, subtitle: device.string("airQualitySensor", "airQuality").map { "AQ \($0)" }, model: model)

        HeroGlyph(symbol: device.symbol, active: device.isOn, animate: device.isOn,
                  caption: device.string("airPurifierFanMode", "airPurifierFanMode").map(STDevice.pretty))

        HStack(alignment: .center) {
            BigReadout(value: pm25.map { "\(Int($0))" } ?? "--", unit: "µg/m³")
            Spacer()
            Card(padding: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("PM2.5").font(.system(size: 14, weight: .medium))
                    Text(quality).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
        }

        TileRow(device: device, options: [
            STOption(title: "Fan", symbol: "fan", capability: "airPurifierFanMode", attribute: "airPurifierFanMode",
                     supported: "supportedAirPurifierFanModes", command: "setAirPurifierFanMode"),
            STOption(title: "PM10", symbol: "aqi.medium", capability: "dustSensor", attribute: "dustLevel"),
            STOption(title: "PM1.0", symbol: "aqi.medium", capability: "veryFineDustSensor", attribute: "veryFineDustLevel"),
            STOption(title: "Filter", symbol: "line.3.horizontal.decrease", capability: "filterState", attribute: "filterLifeRemaining"),
        ], model: model)
    }

    private var quality: String {
        guard let v = pm25 else { return "No reading" }
        switch v {
        case ..<13: return "Good"
        case ..<36: return "Moderate"
        case ..<56: return "Unhealthy (sensitive)"
        default: return "Unhealthy"
        }
    }
}

// MARK: - Soundbar / speaker / cloud-only TV

struct MediaPanel: View {
    let device: STDevice
    let model: AppModel
    @State private var draft = SetpointDraft()

    private var volume: Double? { draft.value ?? device.number("audioVolume", "volume") }
    private var muted: Bool { device.string("audioMute", "mute") == "muted" }

    var body: some View {
        DeviceHeader(device: device, subtitle: device.string("mediaPlayback", "playbackStatus").map(STDevice.pretty), model: model)

        HeroGlyph(symbol: device.symbol, active: device.isOn,
                  caption: device.isOn ? device.string("mediaInputSource", "inputSource") : "Off")

        if device.has("audioVolume") {
            HStack(alignment: .center) {
                BigReadout(value: volume.map { "\(Int($0))" } ?? "--", unit: "vol")
                Spacer()
                if device.has("audioMute") {
                    Card(padding: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2").frame(width: 22)
                            Text("Mute").font(.system(size: 14, weight: .medium))
                            PillSwitch(isOn: muted) {
                                Task { await device.run("audioMute", "setMute", [muted ? "unmuted" : "muted"], token: model.stToken) }
                            }
                        }
                    }
                }
            }
            .disabled(!device.isOn)

            HStack(spacing: 10) {
                CircleButton(symbol: "minus") { Task { await device.run("audioVolume", "volumeDown", token: model.stToken) } }
                GlassSlider(value: .constant(volume ?? 0), enabled: device.isOn) { v in
                    draft.change(to: v) { v in
                        await device.run("audioVolume", "setVolume", [Int(v)], token: model.stToken)
                    }
                }
                CircleButton(symbol: "plus") { Task { await device.run("audioVolume", "volumeUp", token: model.stToken) } }
            }
            .disabled(!device.isOn)
        }

        if device.has("mediaPlayback") || device.has("mediaTrackControl") {
            HStack(spacing: 14) {
                CircleButton(symbol: "backward.fill") { Task { await device.run("mediaTrackControl", "previousTrack", token: model.stToken) } }
                CircleButton(symbol: "play.fill") { Task { await device.run("mediaPlayback", "play", token: model.stToken) } }
                CircleButton(symbol: "pause.fill") { Task { await device.run("mediaPlayback", "pause", token: model.stToken) } }
                CircleButton(symbol: "forward.fill") { Task { await device.run("mediaTrackControl", "nextTrack", token: model.stToken) } }
            }
            .disabled(!device.isOn)
        }

        TileRow(device: device, options: [
            device.firstOption(STOption.tvInputs),
            device.firstOption(STOption.tvSound),
            device.firstOption(STOption.tvPicture),
        ].compactMap { $0 }, model: model)
        .disabled(!device.isOn)
    }
}

// MARK: - Lights, plugs, locks, sensors and anything else

struct GenericPanel: View {
    let device: STDevice
    let model: AppModel
    @State private var draft = SetpointDraft()

    private var level: Double? { draft.value ?? device.number("switchLevel", "level") }

    private var readings: [(symbol: String, title: String, value: String)] {
        var out: [(String, String, String)] = []
        func add(_ symbol: String, _ title: String, _ cap: String, _ attr: String, _ format: (String) -> String = { $0 }) {
            if let v = device.string(cap, attr) { out.append((symbol, title, format(v))) }
        }
        add("thermometer.medium", "Temperature", "temperatureMeasurement", "temperature") { "\($0)°" }
        add("humidity", "Humidity", "relativeHumidityMeasurement", "humidity") { "\($0)%" }
        add("battery.75percent", "Battery", "battery", "battery") { "\($0)%" }
        add("door.left.hand.open", "Contact", "contactSensor", "contact", STDevice.pretty)
        add("figure.walk.motion", "Motion", "motionSensor", "motion", STDevice.pretty)
        add("house", "Presence", "presenceSensor", "presence", STDevice.pretty)
        add("water.waves", "Water", "waterSensor", "water", STDevice.pretty)
        add("smoke", "Smoke", "smokeDetector", "smoke", STDevice.pretty)
        add("bolt", "Power", "powerMeter", "power") { "\($0) W" }
        add("bolt.circle", "Energy", "energyMeter", "energy") { "\($0) kWh" }
        add("sun.max", "Light", "illuminanceMeasurement", "illuminance") { "\($0) lux" }
        add("lightbulb.led", "Color temp", "colorTemperature", "colorTemperature") { "\($0) K" }
        add("lock", "Lock", "lock", "lock", STDevice.pretty)
        return out
    }

    var body: some View {
        DeviceHeader(device: device, subtitle: STDevice.pretty(device.kind.rawValue), model: model)

        HeroGlyph(symbol: device.symbol, active: !device.hasSwitch || device.isOn,
                  caption: device.hasSwitch ? (device.isOn ? "On" : "Off") : nil)

        if device.has("switchLevel") {
            HStack(alignment: .center) {
                BigReadout(value: level.map { "\(Int($0))" } ?? "--", unit: "%")
                Spacer()
            }
            GlassSlider(value: .constant(level ?? 0), enabled: device.isOn) { v in
                draft.change(to: v) { v in
                    await device.run("switchLevel", "setLevel", [Int(v)], token: model.stToken)
                }
            }
        }

        if device.has("lock") {
            HStack(spacing: 10) {
                Button("Lock") { Task { await device.run("lock", "lock", token: model.stToken) } }
                Button("Unlock") { Task { await device.run("lock", "unlock", token: model.stToken) } }
            }
            .controlSize(.large)
        }

        let tiles = readings
        if tiles.isEmpty {
            Text("No readings reported").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(tiles, id: \.title) { ReadingTile(symbol: $0.symbol, title: $0.title, value: $0.value) }
            }
        }
    }
}
