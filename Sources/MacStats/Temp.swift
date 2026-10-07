// The Temp menu bar item: "Temp" over the hottest part's temperature (soft red when
// that part is in the red), and a panel with two gauges (the hottest part, and how
// hard the Mac is drawing power) over every sensor the Mac has: temperatures as one
// row per part (hottest first, coloured by heat), then power in plain words, then fans.

import Cocoa

/// What the Temp item shows: the hottest part's temperature, whether that part's row
/// is red, and the part for its tooltip.
func tempItemText(_ readings: [Reading]) -> (value: String, tooltip: String, alert: Bool) {
    guard let hottest = temperatureGroups(readings).first else { return ("–", "No temperature sensors.", false) }
    let level = heat(of: hottest.name, celsius: hottest.celsius)
    return (degrees(hottest.celsius, unit: false),
            "Hottest: \(hottest.name), \(degrees(hottest.celsius)) (\(level.word.lowercased())). Click for every sensor.",
            level == .hot)
}

/// The temperatures, in °C, at which a part turns yellow (warm) and red (hot). Parts
/// differ a lot: a chip runs at 60–85 °C under load and throttles from about 90–100 °C,
/// a battery should stay within 10–35 °C and wears faster above 40 °C, and an SSD's
/// flash is rated to about 70 °C.
struct HeatLimits {
    let warm: Double
    let hot: Double
}

let chipLimits = HeatLimits(warm: 85, hot: 100)
let batteryLimits = HeatLimits(warm: 35, hot: 40)
let ssdLimits = HeatLimits(warm: 50, hot: 70)
let otherLimits = HeatLimits(warm: 60, hot: 80)

/// The limits for a temperature row, by its name.
/// What a Temperature row's part is, for its tooltip; nil for a part this list does not
/// know. The first matching rule wins, so the specific ones come first.
func partDescription(_ name: String) -> String? {
    let lower = name.lowercased()
    let rules: [(match: (String) -> Bool, text: String)] = [
        ({ $0.contains("efficiency core") }, "Low-power CPU cores, for background work."),
        ({ $0.contains("performance core") }, "Fast CPU cores, for the work you wait on."),
        ({ $0.contains("super core") }, "The fastest CPU cores, for the heaviest work."),
        ({ $0.contains("heatpipe") || $0.contains("heatsink") }, "Metal that carries heat away from the chips."),
        ({ $0.hasPrefix("gpu") }, "The graphics processor."),
        ({ $0.hasPrefix("cpu") }, "The processor that runs macOS and apps."),
        ({ $0.contains("engine") }, "The machine-learning cores, for AI features."),
        ({ $0.contains("memory") }, "The memory (RAM)."),
        ({ $0.contains("battery") }, "The battery. Heat wears it out faster."),
        ({ $0.contains("ssd") || $0.contains("nand") || $0.hasPrefix("disk") }, "The built-in storage."),
        ({ $0.contains("wi-fi") || $0.contains("airport") }, "The Wi-Fi and Bluetooth chip."),
        ({ $0.contains("thunderbolt") }, "The controller behind the USB-C ports."),
        ({ $0.contains("image signal") }, "The camera's image processor."),
        ({ $0.contains("display") }, "The display."),
        ({ $0.contains("power") }, "The chips that manage power."),
        ({ $0.contains("soc") || $0.contains("mainboard") || $0.contains("northbridge") || $0.contains("thermal zone") },
         "The main board, around the chips."),
    ]
    return rules.first { $0.match(lower) }?.text
}

func heatLimits(for name: String) -> HeatLimits {
    let lower = name.lowercased()
    if lower.contains("battery") { return batteryLimits }
    if lower.contains("ssd") || lower.contains("nand") || lower.hasPrefix("disk") { return ssdLimits }
    let chipParts = ["cpu", "gpu", "engine", "soc", "memory", "package", "die"]
    if chipParts.contains(where: lower.contains) { return chipLimits }
    return otherLimits
}

enum Heat: String {
    case normal = "green", warm = "yellow", hot = "red"

    var word: String {
        switch self {
        case .normal: return "Normal"
        case .warm: return "Warm"
        case .hot: return "Hot"
        }
    }

    var color: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .warm: return .systemYellow
        case .hot: return .systemRed
        }
    }
}

func heat(of name: String, celsius: Double) -> Heat {
    let limits = heatLimits(for: name)
    return celsius < limits.warm ? .normal : celsius < limits.hot ? .warm : .hot
}

/// Where a temperature sits on its part's gauge: green from 25 °C, yellow from the
/// part's warm limit, red from its hot limit, the arc ending as far past hot as warm is
/// below it.
func heatFraction(of name: String, celsius: Double) -> Double {
    let limits = heatLimits(for: name)
    return gaugeFraction(celsius, low: 25, warm: limits.warm, hot: limits.hot, high: 2 * limits.hot - limits.warm)
}

// MARK: - Power use

/// How much power the whole Mac draws, in three tiers like the temperatures. The tiers
/// follow the Mac's own figures. The M4 MacBook Air idles at 0.7–3.6 W (Apple's
/// ENERGY STAR filing); under load its chip sustains 8–9 W and bursts to 20–23 W, and
/// the whole Mac peaks near 31 W, the size of its 30 W charger (Notebookcheck,
/// LaptopMedia). So: normal below 10 W, moderate below 20 W, high from 20 W, the gauge
/// ending at 31 W. Other Macs get tiers scaled to their chip class, which are estimates.
struct PowerLimits {
    let moderate: Double
    let high: Double
    let maximum: Double
}

let powerLimits: PowerLimits = {
    switch Chip.current {
    case .m1Pro, .m2Pro, .m3Pro, .m4Pro, .m5Pro:
        return PowerLimits(moderate: 20, high: 45, maximum: 70)
    case .m1Max, .m2Max, .m3Max, .m4Max, .m5Max, .m1Ultra, .m2Ultra, .m3Ultra, .m4Ultra, .m5Ultra:
        return PowerLimits(moderate: 35, high: 90, maximum: 140)
    case .intel:
        return PowerLimits(moderate: 20, high: 45, maximum: 90)
    default:
        return PowerLimits(moderate: 10, high: 20, maximum: 31)
    }
}()

enum PowerLevel: String {
    case normal, moderate, high

    var word: String { rawValue.capitalized }
    var color: NSColor {
        switch self {
        case .normal: return .systemGreen
        case .moderate: return .systemYellow
        case .high: return .systemRed
        }
    }
}

func powerLevel(watts: Double) -> PowerLevel {
    watts < powerLimits.moderate ? .normal : watts < powerLimits.high ? .moderate : .high
}

/// What the Mac draws now, and how long the battery lasts at that rate when it is
/// running on the battery.
func powerUse(_ readings: [Reading], battery charge: BatteryCharge?) -> (watts: Double, hoursLeft: Double?)? {
    let byKey = Dictionary(readings.map { ($0.sensor.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    guard let total = byKey["PSTR"], total > 0 else { return nil }
    let onCharger = (byKey["PDTR"] ?? 0) > 0.5 || (byKey["VD0R"] ?? 0) > 1
    let hours = onCharger ? nil : charge.map { $0.leftWh / total }
    return (total, hours)
}

func formatHours(_ hours: Double) -> String {
    let minutes = Int((hours * 60).rounded())
    return minutes < 60 ? "about \(minutes) min left" : "about \(minutes / 60) h \(minutes % 60) min left"
}

/// One row of the Power section.
struct PowerLine {
    let id: String
    let title: String
    let value: String
    let tooltip: String?
}

/// The Power section: the SMC's voltage, current and power readings in plain words,
/// and the battery's charge. What the whole Mac uses, the battery's draw, the charger
/// (only while one is connected, with its voltage and current in the tooltip) and the
/// internal supply; any other such sensor follows under its own name; what is left in
/// the battery comes last.
func powerLines(_ readings: [Reading], battery charge: BatteryCharge?) -> [PowerLine] {
    let byKey = Dictionary(readings.map { ($0.sensor.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    var lines: [PowerLine] = []
    if let total = byKey["PSTR"] {
        lines.append(PowerLine(id: "PSTR", title: "Total", value: String(format: "%.1f W", total),
                               tooltip: "Everything the Mac is using right now."))
    }
    if let battery = byKey["PPBR"] {
        lines.append(PowerLine(id: "PPBR", title: "Battery", value: String(format: "%.1f W", battery),
                               tooltip: "Power coming out of the battery; about 0 on the charger."))
    }
    let chargerWatts = byKey["PDTR"] ?? 0, chargerVolts = byKey["VD0R"] ?? 0, chargerAmps = byKey["ID0R"] ?? 0
    if chargerWatts > 0.5 || chargerVolts > 1 {
        lines.append(PowerLine(id: "charger", title: "Charger", value: String(format: "%.1f W", chargerWatts),
                               tooltip: String(format: "Coming in from the charger at %.1f V and %.2f A.", chargerVolts, chargerAmps)))
    }
    if let supply = byKey["VP0R"] {
        lines.append(PowerLine(id: "VP0R", title: "Internal supply", value: String(format: "%.2f V", supply),
                               tooltip: "The Mac's main internal supply line; it stays near 12 V."))
    }
    let shown: Set<String> = ["PSTR", "PPBR", "PDTR", "VD0R", "ID0R", "VP0R"]
    for reading in readings where [.power, .voltage, .current].contains(reading.sensor.kind) && !shown.contains(reading.sensor.key) {
        lines.append(PowerLine(id: reading.sensor.key, title: reading.sensor.name, value: formatReading(reading), tooltip: nil))
    }
    if let charge {
        lines.append(PowerLine(
            id: "batteryLeft", title: "Battery left",
            value: String(format: "%.1f/%.1f Wh (%d%%)", charge.leftWh, charge.fullWh, charge.percent),
            tooltip: String(format: "A full charge holds %.1f Wh (%.1f Wh new).\n%d charge cycles so far.",
                            charge.fullWh, charge.designWh, charge.cycles)))
    }
    return lines
}

final class TempPanel: StatsPanel {
    private let reader: SensorReader
    private let heatGauge = GaugeView()
    private let powerGauge = GaugeView()
    private let temperatureList = NSStackView()
    private var temperatureRows: [String: PanelRow] = [:]
    private let powerCaption = separatorView("Power")
    private let powerList = NSStackView()
    private var powerRows: [String: PanelRow] = [:]  // by PowerLine id
    private var fanRows: [String: PanelRow] = [:]    // by SMC key

    init(reader: SensorReader) {
        self.reader = reader
        super.init(title: "Sensors")
        build(reader.read())
    }

    private func build(_ readings: [Reading]) {
        let groups = temperatureGroups(readings)
        // Two gauges on top, as Stats' RAM panel has: the hottest part, and power use.
        let dashboard = NSStackView(views: [heatGauge, powerGauge])
        dashboard.orientation = .horizontal
        dashboard.distribution = .fillEqually
        dashboard.spacing = 0
        dashboard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dashboard.widthAnchor.constraint(equalToConstant: Panel.width),
            dashboard.heightAnchor.constraint(equalToConstant: 108),
        ])
        heatGauge.heading = "Hottest part"
        powerGauge.heading = "Power use"
        heatGauge.hoverTip = twoLines("The hottest part, coloured on its own limits like its row below.")
        powerGauge.hoverTip = twoLines(String(format: "What the whole Mac draws: normal under %.0f W, moderate under %.0f W, "
            + "high above.", powerLimits.moderate, powerLimits.high))
        body.addArrangedSubview(dashboard)
        if !groups.isEmpty {
            body.addArrangedSubview(separatorView("Temperature"))
            temperatureList.orientation = .vertical
            temperatureList.alignment = .leading
            temperatureList.spacing = 0
            for group in groups {
                temperatureRows[group.name] = PanelRow(group.name + ":", color: heat(of: group.name, celsius: group.celsius).color)
            }
            body.addArrangedSubview(temperatureList)
        }
        if reader.sensors.contains(where: { [.power, .voltage, .current].contains($0.kind) }) || batteryCharge() != nil {
            body.addArrangedSubview(powerCaption)
            powerList.orientation = .vertical
            powerList.alignment = .leading
            powerList.spacing = 0
            body.addArrangedSubview(powerList)
        }
        let fans = reader.sensors.filter { $0.kind == .fan }
        if !fans.isEmpty {
            body.addArrangedSubview(separatorView("Fans"))
            for fan in fans {
                let row = PanelRow(fan.name + ":")
                fanRows[fan.key] = row
                body.addArrangedSubview(row)
            }
        }
        if groups.isEmpty && body.arrangedSubviews.isEmpty {
            let none = NSTextField(labelWithString: "This Mac reports no sensors.")
            none.font = .systemFont(ofSize: 12)
            none.textColor = .secondaryLabelColor
            body.addArrangedSubview(none)
        }
        update(readings)
    }

    override func willOpen() {
        update(reader.read())
    }

    /// Shows new readings: the gauges, and temperature rows re-sorted hottest first and recoloured.
    func update(_ readings: [Reading]) {
        let groups = temperatureGroups(readings)
        let charge = batteryCharge()
        if let hottest = groups.first {
            heatGauge.fraction = heatFraction(of: hottest.name, celsius: hottest.celsius)
            heatGauge.title = "\(heat(of: hottest.name, celsius: hottest.celsius).word) · \(degrees(hottest.celsius))"
            heatGauge.subtitle = hottest.name
        }
        if let use = powerUse(readings, battery: charge) {
            powerGauge.fraction = gaugeFraction(use.watts, low: 0, warm: powerLimits.moderate,
                                                hot: powerLimits.high, high: powerLimits.maximum)
            powerGauge.title = String(format: "%@ · %.0f W", powerLevel(watts: use.watts).word, use.watts)
            powerGauge.subtitle = use.hoursLeft.map(formatHours) ?? "on charger"
        }
        for group in groups {
            guard let row = temperatureRows[group.name] else { continue }
            row.value.stringValue = degrees(group.celsius)
            row.setColor(heat(of: group.name, celsius: group.celsius).color)
            let limits = heatLimits(for: group.name)
            // Two lines: what the part is, then where its square turns yellow and red.
            let heatLine = "Yellow from \(degrees(limits.warm)), red from \(degrees(limits.hot))."
            row.hoverTip = (partDescription(group.name).map { $0 + "\n" } ?? "") + heatLine
        }
        temperatureList.setViews(groups.compactMap { temperatureRows[$0.name] }, in: .top)
        // Power rows come and go with the charger.
        let lines = powerLines(readings, battery: charge)
        for line in lines {
            let row = powerRows[line.id] ?? PanelRow(line.title + ":")
            powerRows[line.id] = row
            row.value.stringValue = line.value
            row.hoverTip = line.tooltip.map(twoLines)
        }
        powerList.setViews(lines.compactMap { powerRows[$0.id] }, in: .top)
        let byKey = Dictionary(readings.map { ($0.sensor.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, row) in fanRows {
            row.value.stringValue = byKey[key].map(formatReading) ?? "–"
        }
        if isVisible { fitToContents() }
    }
}

/// Prints what the panel shows: each section, then its rows.
func sensorsReport() -> Int32 {
    let reader = SensorReader()
    let readings = reader.read()
    guard !readings.isEmpty else {
        FileHandle.standardError.write("This Mac reports no sensors.\n".data(using: .utf8)!)
        return 1
    }
    let groups = temperatureGroups(readings)
    let charge = batteryCharge()
    print("Gauges")
    if let hottest = groups.first {
        print(["Hottest", hottest.name, String(format: "%.1f", hottest.celsius),
               heat(of: hottest.name, celsius: hottest.celsius).rawValue].joined(separator: "\t"))
    }
    if let use = powerUse(readings, battery: charge) {
        print(["Power use", String(format: "%.1f", use.watts), powerLevel(watts: use.watts).rawValue,
               use.hoursLeft.map(formatHours) ?? "on charger"].joined(separator: "\t"))
    }
    if !groups.isEmpty { print("Temperature") }
    for group in groups {
        print([group.name, String(format: "%.1f", group.celsius), String(group.count),
               String(format: "%.1f-%.1f", group.coolest, group.hottest),
               heat(of: group.name, celsius: group.celsius).rawValue].joined(separator: "\t"))
    }
    let lines = powerLines(readings, battery: charge)
    if !lines.isEmpty { print("Power") }
    for line in lines { print(line.title + "\t" + line.value) }
    let fans = readings.filter { $0.sensor.kind == .fan }
    if !fans.isEmpty { print("Fans") }
    for reading in fans { print(reading.sensor.name + "\t" + formatReading(reading)) }
    return 0
}
