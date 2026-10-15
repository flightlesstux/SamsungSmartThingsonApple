import Foundation

enum STError: LocalizedError {
    case noToken, http(Int, String)

    var errorDescription: String? {
        switch self {
        case .noToken: "Add a SmartThings token in settings."
        case .http(401, _): "SmartThings token rejected (401)."
        case .http(let code, let body): "SmartThings \(code): \(body.prefix(140))"
        }
    }
}

/// component -> capability -> attribute -> value
typealias STStatus = [String: [String: [String: Any]]]

struct SmartThingsAPI {
    let token: String

    private func request(_ path: String, method: String = "GET", body: Any? = nil) async throws -> Any {
        var req = URLRequest(url: URL(string: "https://api.smartthings.com/v1\(path)")!, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw STError.http(code, String(decoding: data, as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    func devices() async throws -> [[String: Any]] {
        let obj = try await request("/devices") as? [String: Any]
        return obj?["items"] as? [[String: Any]] ?? []
    }

    func status(_ deviceId: String) async throws -> STStatus {
        let obj = try await request("/devices/\(deviceId)/status") as? [String: Any]
        let comps = obj?["components"] as? [String: [String: [String: Any]]] ?? [:]
        var out: STStatus = [:]
        for (comp, caps) in comps {
            var capsOut: [String: [String: Any]] = [:]
            for (cap, attrs) in caps {
                var values: [String: Any] = [:]
                for (attr, wrapper) in attrs {
                    if let v = (wrapper as? [String: Any])?["value"], !(v is NSNull) { values[attr] = v }
                }
                capsOut[cap] = values
            }
            out[comp] = capsOut
        }
        return out
    }

    func command(_ deviceId: String, component: String, capability: String, command: String, args: [Any]) async throws {
        let body: [String: Any] = ["commands": [[
            "component": component, "capability": capability, "command": command, "arguments": args,
        ]]]
        _ = try await request("/devices/\(deviceId)/commands", method: "POST", body: body)
    }
}

// MARK: - Device kinds

enum STKind: String, CaseIterable {
    case washer, dryer, dishwasher, airConditioner, refrigerator, robotCleaner, oven, airPurifier
    case television, speaker, light, plug, lock, sensor, other

    var symbol: String {
        switch self {
        case .washer: "washer"
        case .dryer: "dryer"
        case .dishwasher: "dishwasher"
        case .airConditioner: "air.conditioner.horizontal"
        case .refrigerator: "refrigerator"
        case .robotCleaner: "robotic.vacuum"
        case .oven: "oven"
        case .airPurifier: "air.purifier"
        case .television: "tv"
        case .speaker: "hifispeaker"
        case .light: "lightbulb"
        case .plug: "powerplug"
        case .lock: "lock"
        case .sensor: "sensor"
        case .other: "square.grid.2x2"
        }
    }

    var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// Capability that carries run / pause / stop and remaining time, for cycle appliances.
    var operatingCapability: String? {
        switch self {
        case .washer: "washerOperatingState"
        case .dryer: "dryerOperatingState"
        case .dishwasher: "dishwasherOperatingState"
        case .oven: "ovenOperatingState"
        default: nil
        }
    }

    static func classify(categories: [String], capabilities caps: Set<String>) -> STKind {
        let byCategory: [String: STKind] = [
            "Washer": .washer, "Dryer": .dryer, "Dishwasher": .dishwasher,
            "AirConditioner": .airConditioner, "Refrigerator": .refrigerator, "KimchiRefrigerator": .refrigerator,
            "RobotCleaner": .robotCleaner, "Oven": .oven, "Range": .oven, "Microwave": .oven,
            "AirPurifier": .airPurifier, "Television": .television, "SmartMonitor": .television,
            "Projector": .television, "NetworkAudio": .speaker, "Speaker": .speaker,
            "Light": .light, "SmartPlug": .plug, "Switch": .plug, "SmartLock": .lock,
        ]
        for c in categories { if let k = byCategory[c] { return k } }
        if caps.contains("washerOperatingState") { return .washer }
        if caps.contains("dryerOperatingState") { return .dryer }
        if caps.contains("dishwasherOperatingState") { return .dishwasher }
        if caps.contains("airConditionerMode") { return .airConditioner }
        if caps.contains("refrigeration") { return .refrigerator }
        if caps.contains("robotCleanerMovement") { return .robotCleaner }
        if caps.contains("ovenOperatingState") { return .oven }
        if caps.contains("airPurifierFanMode") { return .airPurifier }
        if caps.contains("tvChannel") { return .television }
        if caps.contains("audioVolume") { return .speaker }
        if caps.contains("lock") { return .lock }
        if caps.contains("colorControl") || caps.contains("colorTemperature") { return .light }
        if caps.contains("switch") { return .plug }
        if caps.contains(where: { $0.hasSuffix("Sensor") || $0.hasSuffix("Measurement") }) { return .sensor }
        return .other
    }
}

/// A tile backed by a capability attribute, optionally settable from a list of supported values.
struct STOption: Identifiable {
    var id: String { "\(component).\(capability).\(attribute)" }
    let title: String
    let symbol: String
    let capability: String
    let attribute: String
    var supported: String? = nil
    var command: String? = nil
    var component = "main"
    var fixedChoices: [String] = []
}

// MARK: - Device controller

@MainActor @Observable
final class STDevice: Identifiable {
    nonisolated let id: String
    let kind: STKind
    var label: String
    let capabilities: Set<String>
    let componentIDs: [String]
    var status: STStatus = [:]
    var lastUpdate: Date?
    var error: String?

    @ObservationIgnored private var lastPhase: CyclePhase?
    @ObservationIgnored private var warnedSoon = false

    init(id: String, kind: STKind, label: String, capabilities: Set<String>, componentIDs: [String] = ["main"]) {
        self.id = id
        self.kind = kind
        self.label = label
        self.capabilities = capabilities
        self.componentIDs = componentIDs
    }

    var symbol: String { kind.symbol }

    // MARK: Raw access

    func value(_ cap: String, _ attr: String, _ comp: String = "main") -> Any? { status[comp]?[cap]?[attr] }

    func string(_ cap: String, _ attr: String, _ comp: String = "main") -> String? {
        switch value(cap, attr, comp) {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    func number(_ cap: String, _ attr: String, _ comp: String = "main") -> Double? {
        switch value(cap, attr, comp) {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    func has(_ cap: String, _ comp: String = "main") -> Bool { status[comp]?[cap] != nil }

    var isOn: Bool { string("switch", "switch") == "on" }
    var hasSwitch: Bool { has("switch") }

    // MARK: Cycle appliances

    /// "run", "pause" or "stop".
    var machineState: String {
        guard let op = kind.operatingCapability else { return "stop" }
        if let s = string(op, "machineState") { return s == "ready" ? "stop" : s }
        switch string("samsungce.\(op)", "operatingState") {
        case "running": return "run"
        case "paused": return "pause"
        default: return "stop"
        }
    }

    var isRunning: Bool {
        if kind.operatingCapability != nil { return machineState == "run" }
        if kind == .robotCleaner { return string("robotCleanerMovement", "robotCleanerMovement") == "cleaning" }
        return false
    }

    /// Raw SmartThings job state, e.g. "rinse", "drying", "wrinklePrevent".
    var rawJobState: String? {
        guard let op = kind.operatingCapability else { return nil }
        let prefix = op.replacingOccurrences(of: "OperatingState", with: "")
        let raw = string(op, "\(prefix)JobState") ?? string("samsungce.\(op)", "\(prefix)JobState")
            ?? string(op, "operatingState")
        guard let raw, raw != "none", raw != "ready" else { return nil }
        return raw
    }

    var jobState: String? { rawJobState.map(Self.pretty) }

    var remainingMinutes: Int? {
        guard let op = kind.operatingCapability else { return nil }
        if let n = number("samsungce.\(op)", "remainingTime"), n > 0 {
            // Minutes on most models; anything over 10 hours must be seconds.
            return n > 600 ? Int(n / 60) : Int(n)
        }
        guard machineState != "stop", let iso = string(op, "completionTime"),
              let end = ISO8601DateFormatter.withFraction.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        else { return nil }
        let mins = Int(end.timeIntervalSinceNow / 60)
        return mins > 0 ? mins : nil
    }

    var completion: Date? { remainingMinutes.map { Date().addingTimeInterval(Double($0) * 60) } }

    /// 0...1
    var progress: Double {
        guard let op = kind.operatingCapability else { return 0 }
        if let n = number("samsungce.\(op)", "progress") ?? number(op, "progress") { return n / 100 }
        return machineState == "stop" ? 0 : 0.5
    }

    var remoteEnabled: Bool {
        guard has("remoteControlStatus") else { return true }
        return string("remoteControlStatus", "remoteControlEnabled") == "true"
    }

    func setMachineState(_ state: String, token: String?) async {
        guard let op = kind.operatingCapability else { return }
        await run(op, "setMachineState", [state], token: token)
    }

    var cycleOptions: [STOption] {
        switch kind {
        case .washer: [
            STOption(title: "Cycle", symbol: "list.bullet.circle", capability: "samsungce.washerCycle", attribute: "washerCycle"),
            STOption(title: "Temp", symbol: "thermometer.medium", capability: "custom.washerWaterTemperature",
                     attribute: "washerWaterTemperature", supported: "supportedWasherWaterTemperature", command: "setWasherWaterTemperature"),
            STOption(title: "Spin", symbol: "tornado", capability: "custom.washerSpinLevel",
                     attribute: "washerSpinLevel", supported: "supportedWasherSpinLevel", command: "setWasherSpinLevel"),
            STOption(title: "Rinse", symbol: "drop", capability: "custom.washerRinseCycles",
                     attribute: "washerRinseCycles", supported: "supportedWasherRinseCycles", command: "setWasherRinseCycles"),
        ]
        case .dryer: [
            STOption(title: "Cycle", symbol: "list.bullet.circle", capability: "samsungce.dryerCycle", attribute: "dryerCycle"),
            STOption(title: "Dry level", symbol: "sun.max", capability: "custom.dryerDryLevel",
                     attribute: "dryerDryLevel", supported: "supportedDryerDryLevel", command: "setDryerDryLevel"),
            STOption(title: "Wrinkle", symbol: "wind", capability: "custom.dryerWrinklePrevent",
                     attribute: "dryerWrinklePrevent", command: "setDryerWrinklePrevent", fixedChoices: ["on", "off"]),
            STOption(title: "Energy", symbol: "bolt", capability: "powerConsumptionReport", attribute: "powerConsumption"),
        ]
        case .dishwasher: [
            STOption(title: "Course", symbol: "list.bullet.circle", capability: "samsungce.dishwasherWashingCourse",
                     attribute: "washingCourse", supported: "supportedCourses", command: "setWashingCourse"),
            STOption(title: "Mode", symbol: "sparkles", capability: "dishwasherMode",
                     attribute: "dishwasherMode", supported: "supportedDishwasherModes", command: "setDishwasherMode"),
            STOption(title: "Rinse aid", symbol: "drop", capability: "samsungce.dishwasherWashingOptions", attribute: "rinseAid"),
            STOption(title: "Energy", symbol: "bolt", capability: "powerConsumptionReport", attribute: "powerConsumption"),
        ]
        case .oven: [
            STOption(title: "Mode", symbol: "flame", capability: "ovenMode",
                     attribute: "ovenMode", supported: "supportedOvenModes", command: "setOvenMode"),
            STOption(title: "Setpoint", symbol: "thermometer.medium", capability: "ovenSetpoint", attribute: "ovenSetpoint"),
            STOption(title: "Inside", symbol: "thermometer.medium", capability: "temperatureMeasurement", attribute: "temperature"),
            STOption(title: "Energy", symbol: "bolt", capability: "powerConsumptionReport", attribute: "powerConsumption"),
        ]
        default: []
        }
    }

    // MARK: Option helpers

    func display(_ option: STOption) -> String? {
        if option.capability == "powerConsumptionReport" {
            guard let report = value(option.capability, option.attribute, option.component) as? [String: Any],
                  let wh = report["energy"] as? NSNumber else { return nil }
            return String(format: "%.1f kWh", wh.doubleValue / 1000)
        }
        guard let raw = string(option.capability, option.attribute, option.component) else { return nil }
        return label(for: raw, in: option)
    }

    /// (id, label) pairs; handles both plain string lists and [{id, name}] maps.
    func choices(_ option: STOption) -> [(id: String, label: String)] {
        if !option.fixedChoices.isEmpty { return option.fixedChoices.map { ($0, Self.pretty($0)) } }
        guard let supported = option.supported, let raw = value(option.capability, supported, option.component) else { return [] }
        if let list = raw as? [String] { return list.map { ($0, Self.pretty($0)) } }
        if let maps = raw as? [[String: Any]] {
            return maps.compactMap { m in
                guard let id = m["id"] as? String else { return nil }
                return (id, (m["name"] as? String) ?? Self.pretty(id))
            }
        }
        return []
    }

    private func label(for raw: String, in option: STOption) -> String {
        choices(option).first { $0.id == raw }?.label ?? Self.pretty(raw)
    }

    func set(_ option: STOption, to value: String, token: String?) async {
        guard let cmd = option.command else { return }
        await run(option.capability, cmd, [value], component: option.component, token: token)
    }

    static func pretty(_ raw: String) -> String {
        // "Table_02_Course_1B" -> "Course 1B"; "coolDown" -> "Cool Down"
        if let r = raw.range(of: "Course_") { return "Course " + raw[r.upperBound...] }
        var out = ""
        for ch in raw {
            if ch.isUppercase, let last = out.last, last.isLowercase { out.append(" ") }
            out.append(ch)
        }
        return out.replacingOccurrences(of: "_", with: " ").capitalized
    }

    // MARK: Network

    func refresh(token: String?) async {
        guard let token, !token.isEmpty else {
            error = STError.noToken.errorDescription
            return
        }
        do {
            status = try await SmartThingsAPI(token: token).status(id)
            lastUpdate = Date()
            error = nil
            notifyTransition(from: lastPhase, alreadyWarned: &warnedSoon)
            lastPhase = phase
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run(_ capability: String, _ command: String, _ args: [Any] = [], component: String = "main", token: String?) async {
        guard let token else { return }
        do {
            try await SmartThingsAPI(token: token).command(id, component: component, capability: capability, command: command, args: args)
            try? await Task.sleep(for: .seconds(1))
            await refresh(token: token)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func togglePower(token: String?) async {
        await run("switch", isOn ? "off" : "on", token: token)
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

extension STOption {
    /// Candidate capabilities in preference order; the first one the device reports is used.
    static let tvInputs = [
        STOption(title: "Source", symbol: "rectangle.on.rectangle", capability: "samsungvd.mediaInputSource",
                 attribute: "inputSource", supported: "supportedInputSourcesMap", command: "setInputSource"),
        STOption(title: "Source", symbol: "rectangle.on.rectangle", capability: "mediaInputSource",
                 attribute: "inputSource", supported: "supportedInputSources", command: "setInputSource"),
    ]
    static let tvPicture = [
        STOption(title: "Picture", symbol: "photo.tv", capability: "custom.picturemode",
                 attribute: "pictureMode", supported: "supportedPictureModes", command: "setPictureMode"),
        STOption(title: "Picture", symbol: "photo.tv", capability: "samsungvd.pictureMode",
                 attribute: "pictureMode", supported: "supportedPictureModes", command: "setPictureMode"),
    ]
    static let tvSound = [
        STOption(title: "Sound", symbol: "waveform", capability: "custom.soundmode",
                 attribute: "soundMode", supported: "supportedSoundModes", command: "setSoundMode"),
        STOption(title: "Sound", symbol: "waveform", capability: "samsungvd.soundMode",
                 attribute: "soundMode", supported: "supportedSoundModes", command: "setSoundMode"),
    ]
}

extension STDevice {
    func firstOption(_ candidates: [STOption]) -> STOption? {
        candidates.first { has($0.capability, $0.component) }
    }
}
