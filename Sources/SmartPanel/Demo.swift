import SwiftUI

/// Renders a scripted walkthrough with fixture devices (no network) to numbered PNG frames.
/// Turn them into the README GIF with `scripts/make-demo-gif.sh`.
@MainActor
final class DemoRecorder {
    static let fps = 12.0

    let dir: URL
    let model = AppModel(demo: true)
    private var frame = 0
    /// Fake notification banner (title, body) drawn on the stage.
    private var banner: (String, String)?

    init(dir: URL) {
        self.dir = dir
    }

    func run() {
        let tv = TVController(device: TVDevice(id: "demo-tv", name: "Lounge", model: "Smart TV", ip: "", mac: ""))
        let monitor = TVController(device: TVDevice(id: "demo-m8", name: "Studio", model: "LS Smart Monitor", ip: "", mac: ""))
        for t in [tv, monitor] { t.apps = Array(TVApp.candidates.prefix(4)) }
        tv.power = .on
        tv.volume = 12
        tv.foregroundApp = "YouTube"
        monitor.power = .standby
        model.tvs = [tv, monitor]

        let ac = device("demo-ac", .airConditioner, "Bedroom AC", Fixtures.airConditioner)
        let washer = device("demo-washer", .washer, "Washer", Fixtures.washer)
        let dryer = device("demo-dryer", .dryer, "Dryer", Fixtures.dryer)
        let fridge = device("demo-fridge", .refrigerator, "Fridge", Fixtures.fridge, components: ["main", "cooler", "freezer"])
        let vacuum = device("demo-vacuum", .robotCleaner, "Jet Bot", Fixtures.vacuum)
        model.cloudDevices = [washer, dryer, ac, fridge, vacuum]

        // TV: volume, mute, app switch, remote pad.
        model.selection = tv.id
        hold(1.2)
        animate(1.2) { tv.volume = (12 + 20 * $0).rounded() }
        hold(0.5)
        tv.muted = true
        hold(0.7)
        tv.muted = false
        tv.foregroundApp = "Netflix"
        hold(0.8)
        tv.showRemote = true
        hold(1.4)
        tv.showRemote = false

        // Monitor: wake from standby.
        model.selection = monitor.id
        hold(0.8)
        monitor.power = .on
        monitor.volume = 25
        monitor.foregroundApp = "YouTube"
        hold(1.0)

        // Air conditioner: cool down from 26 to 22, then Eco mode.
        model.selection = ac.id
        hold(1.0)
        animate(1.2) { t in
            ac.status["main"]?["thermostatCoolingSetpoint"] = ["coolingSetpoint": (26 - 4 * t).rounded()]
        }
        hold(0.5)
        ac.status["main"]?["custom.airConditionerOptionalMode"]?["acOptionalMode"] = "energySaving"
        hold(1.0)

        // Washer: running cycle counting down, pause and resume.
        model.selection = washer.id
        hold(1.0)
        animate(1.2) { t in
            washer.status["main"]?["samsungce.washerOperatingState"] =
                ["remainingTime": Int((42 - 4 * t).rounded()), "progress": Int((63 + 7 * t).rounded())]
        }
        washer.status["main"]?["washerOperatingState"]?["machineState"] = "pause"
        hold(0.9)
        washer.status["main"]?["washerOperatingState"]?["machineState"] = "run"

        // Dryer finishes: notification banner.
        model.selection = dryer.id
        hold(0.8)
        dryer.status["main"]?["samsungce.dryerOperatingState"] = ["remainingTime": 0, "progress": 100]
        dryer.status["main"]?["dryerOperatingState"] = ["machineState": "stop", "dryerJobState": "none"]
        banner = ("Dryer finished", "Laundry is dry.")
        hold(1.8)
        banner = nil

        // Fridge, vacuum.
        model.selection = fridge.id
        hold(1.4)
        model.selection = vacuum.id
        hold(1.4)

        // Back to the TV so the loop is seamless.
        model.selection = tv.id
        tv.volume = 12
        tv.foregroundApp = "YouTube"
        hold(0.5)
    }

    private func device(_ id: String, _ kind: STKind, _ label: String, _ main: [String: [String: Any]],
                        components: [String] = ["main"]) -> STDevice {
        let d = STDevice(id: id, kind: kind, label: label, capabilities: Set(main.keys), componentIDs: components)
        d.status = ["main": main]
        if kind == .refrigerator {
            d.status["cooler"] = Fixtures.compartment(now: 3, set: 3)
            d.status["freezer"] = Fixtures.compartment(now: -19, set: -18)
        }
        d.lastUpdate = Date()
        return d
    }
}

/// Sample SmartThings status payloads (main component) for the demo.
enum Fixtures {
    static let airConditioner: [String: [String: Any]] = [
        "switch": ["switch": "on"],
        "temperatureMeasurement": ["temperature": 27],
        "thermostatCoolingSetpoint": ["coolingSetpoint": 26],
        "airConditionerMode": ["airConditionerMode": "cool", "supportedAcModes": ["auto", "cool", "dry", "wind", "heat"]],
        "airConditionerFanMode": ["fanMode": "auto", "supportedAcFanModes": ["auto", "low", "medium", "high", "turbo"]],
        "fanOscillationMode": ["fanOscillationMode": "vertical", "supportedFanOscillationModes": ["fixed", "vertical", "horizontal", "all"]],
        "custom.airConditionerOptionalMode": ["acOptionalMode": "off", "supportedAcOptionalMode": ["off", "energySaving", "sleep"]],
        "custom.thermostatSetpointControl": ["minimumSetpoint": 16, "maximumSetpoint": 30],
    ]

    static let washer: [String: [String: Any]] = [
        "switch": ["switch": "on"],
        "washerOperatingState": ["machineState": "run", "washerJobState": "rinse"],
        "samsungce.washerOperatingState": ["remainingTime": 42, "progress": 63],
        "samsungce.washerCycle": ["washerCycle": "Table_02_Course_1B"],
        "custom.washerWaterTemperature": ["washerWaterTemperature": "40",
                                          "supportedWasherWaterTemperature": ["cold", "20", "30", "40", "60"]],
        "custom.washerSpinLevel": ["washerSpinLevel": "1200", "supportedWasherSpinLevel": ["800", "1200", "1400"]],
        "custom.washerRinseCycles": ["washerRinseCycles": "2", "supportedWasherRinseCycles": ["1", "2", "3"]],
        "remoteControlStatus": ["remoteControlEnabled": "true"],
    ]

    static let dryer: [String: [String: Any]] = [
        "switch": ["switch": "on"],
        "dryerOperatingState": ["machineState": "run", "dryerJobState": "drying"],
        "samsungce.dryerOperatingState": ["remainingTime": 55, "progress": 38],
        "samsungce.dryerCycle": ["dryerCycle": "Table_02_Course_2B"],
        "custom.dryerDryLevel": ["dryerDryLevel": "normal", "supportedDryerDryLevel": ["damp", "less", "normal", "more"]],
        "custom.dryerWrinklePrevent": ["dryerWrinklePrevent": "on"],
        "powerConsumptionReport": ["powerConsumption": ["energy": 1840.0]],
        "remoteControlStatus": ["remoteControlEnabled": "true"],
    ]

    static let fridge: [String: [String: Any]] = [
        "contactSensor": ["contact": "closed"],
        "refrigeration": ["rapidCooling": "off", "rapidFreezing": "on"],
        "custom.waterFilter": ["waterFilterUsage": 35],
    ]

    static func compartment(now: Double, set: Double) -> [String: [String: Any]] {
        ["temperatureMeasurement": ["temperature": now], "thermostatCoolingSetpoint": ["coolingSetpoint": set]]
    }

    static let vacuum: [String: [String: Any]] = [
        "battery": ["battery": 78],
        "robotCleanerMovement": ["robotCleanerMovement": "cleaning"],
        "robotCleanerCleaningMode": ["robotCleanerCleaningMode": "auto"],
        "robotCleanerTurboMode": ["robotCleanerTurboMode": "off"],
    ]
}

extension DemoRecorder {
    // MARK: Frames

    private func hold(_ seconds: Double) {
        guard let png = render() else { return }
        for _ in 0..<max(1, Int(seconds * Self.fps)) { write(png) }
    }

    private func animate(_ seconds: Double, _ step: (Double) -> Void) {
        let count = max(2, Int(seconds * Self.fps))
        for i in 0..<count {
            let t = Double(i) / Double(count - 1)
            step(t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2) // ease in-out
            if let png = render() { write(png) }
        }
    }

    private func render() -> Data? {
        let renderer = ImageRenderer(content: DemoStage(model: model, banner: banner))
        renderer.scale = 1.5
        guard let tiff = renderer.nsImage?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private func write(_ png: Data) {
        try? png.write(to: dir.appendingPathComponent(String(format: "frame_%04d.png", frame)))
        frame += 1
    }
}

/// Desktop backdrop with a menu bar and the panel hanging below it, like the real menu bar popover.
struct DemoStage: View {
    let model: AppModel
    var banner: (String, String)?

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.24, blue: 0.36), Color(red: 0.47, green: 0.40, blue: 0.36)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "applelogo")
                    Text("Finder").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "wifi")
                    HStack(spacing: 4) { MenuBarLabel(model: model) }
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                    Text("Thu 15:42")
                }
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 28)
                .background(.black.opacity(0.35))

                PanelView(model: model)
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.12)))
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    .padding(.top, 10)
                Spacer(minLength: 0)
            }
            if let banner {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "dryer")
                        .font(.system(size: 16))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(banner.0).font(.system(size: 13, weight: .semibold))
                        Text(banner.1).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                    Text("now").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)
                .padding(12)
                .frame(width: 320)
                .background(Color(white: 0.18).opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .padding(.top, 38)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(width: 520, height: 800)
    }
}
