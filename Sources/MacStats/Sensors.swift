// Finds the Mac's sensors in the SMC, reads them, and turns the temperature
// readings into one row per part of the Mac: "CPU performance core 1" to "8"
// become "CPU performance cores", each group's value weighted toward its hottest
// sensor.

import Foundation

enum Chip: String {
    case intel
    case m1, m1Pro, m1Max, m1Ultra
    case m2, m2Pro, m2Max, m2Ultra
    case m3, m3Pro, m3Max, m3Ultra
    case m4, m4Pro, m4Max, m4Ultra
    case m5, m5Pro, m5Max, m5Ultra
    case a18Pro

    /// This Mac's chip, from its CPU name ("Apple M4 Pro", "Intel(R) Core(TM) …").
    static let current: Chip = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        return chip(named: String(cString: name))
    }()

    static func chip(named name: String) -> Chip {
        if name.contains("A18 Pro") { return .a18Pro }
        guard let match = name.range(of: #"M\d+( (Pro|Max|Ultra))?"#, options: .regularExpression) else { return .intel }
        let words = name[match].split(separator: " ")
        let raw = words[0].lowercased() + (words.count > 1 ? String(words[1]) : "")
        return Chip(rawValue: raw) ?? .intel
    }
}

enum SensorGroup { case cpu, gpu, system, sensor }
enum SensorKind: String { case temperature, voltage, current, power, fan }

struct CatalogSensor {
    let key: String
    let name: String
    let group: SensorGroup
    let kind: SensorKind
    let chips: [Chip]?
    let core: Bool
}

/// One sensor found on this Mac.
struct Sensor {
    let key: String
    let name: String
    let group: SensorGroup
    let kind: SensorKind
    let core: Bool
}

struct Reading {
    let sensor: Sensor
    let value: Double
}

/// Whether `key` fits `pattern`, where "%" stands for any one character.
private func matchesPattern(_ key: String, _ pattern: String) -> Bool {
    guard key.count == pattern.count else { return false }
    for (character, wanted) in zip(key, pattern) where wanted != "%" && character != wanted { return false }
    return true
}

/// Finds this Mac's sensors once, then reads them on demand. An SMC read takes a
/// fraction of a millisecond, so reading every second costs next to nothing.
final class SensorReader {
    private let smc = SMC()
    let sensors: [Sensor]

    init() {
        guard let smc else { sensors = []; return }
        let keys = smc.allKeys()
        let present = Set(keys)
        var found: [Sensor] = []
        var seen = Set<String>()
        for entry in sensorCatalog where entry.chips?.contains(Chip.current) ?? true {
            // "%" in a key stands for any one character, and in the name for that character.
            let matches: [(key: String, name: String)]
            if let wildcard = entry.key.firstIndex(of: "%") {
                let offset = entry.key.distance(from: entry.key.startIndex, to: wildcard)
                matches = keys.filter { matchesPattern($0, entry.key) }.map { key in
                    let character = String(key[key.index(key.startIndex, offsetBy: offset)])
                    return (key, entry.name.replacingOccurrences(of: "%", with: character))
                }
            } else {
                matches = present.contains(entry.key) ? [(entry.key, entry.name)] : []
            }
            for match in matches where seen.insert(match.key).inserted {
                found.append(Sensor(key: match.key, name: match.name, group: entry.group, kind: entry.kind, core: entry.core))
            }
        }
        // Fans: FNum says how many, F<n>Ac is each one's speed.
        let fans = Int(smc.value("FNum") ?? 0)
        for index in 0..<fans {
            found.append(Sensor(key: "F\(index)Ac", name: "Fan \(index + 1)", group: .system, kind: .fan, core: false))
        }
        sensors = found
    }

    /// The sensors answering now, with readings outside what a Mac can report dropped.
    func read() -> [Reading] {
        guard let smc else { return [] }
        return sensors.compactMap { sensor in
            guard let value = smc.value(sensor.key), value.isFinite else { return nil }
            if sensor.kind == .temperature && !(value > 0 && value < 130) { return nil }
            return Reading(sensor: sensor, value: value)
        }
    }
}

// MARK: - Temperature groups

/// A group's temperature: each reading weighted by how close it is to the group's
/// hottest, e^((t − hottest) / spread). With a 3 °C spread the hottest counts fully,
/// one 3 °C cooler about 37%, one 6 °C cooler about 14%, so the hottest part leads
/// without one hot sensor standing for the whole group.
func hotWeighted(_ values: [Double], spread: Double = 3) -> Double {
    guard let hottest = values.max() else { return .nan }
    let weights = values.map { exp(($0 - hottest) / spread) }
    return zip(values, weights).map(*).reduce(0, +) / weights.reduce(0, +)
}

/// The group a sensor belongs to, from its name: trailing numbers and letters go,
/// and "core" becomes "cores". "CPU performance core 3" → "CPU performance cores",
/// "GPU 5" → "GPU", "Thunderbolt O" → "Thunderbolt", "Disk 1 (A)" → "Disk".
func groupName(_ name: String) -> String {
    var words = name.split(separator: " ").map(String.init)
    func isIndex(_ word: String) -> Bool {
        word.allSatisfy(\.isNumber) || word.count == 1
            || word.range(of: #"^\([A-Za-z0-9]\)$"#, options: .regularExpression) != nil
    }
    while words.count > 1, let last = words.last, isIndex(last) { words.removeLast() }
    var group = words.joined(separator: " ")
    if group.lowercased().hasSuffix(" core") { group += "s" }
    return friendlyNames[group] ?? group
}

/// Names that read better than the SMC's.
private let friendlyNames = ["Airport": "Wi-Fi", "NAND": "SSD"]

struct TemperatureGroup {
    let name: String
    let celsius: Double
    let coolest: Double
    let hottest: Double
    let count: Int
}

/// One row per group, hottest first.
func temperatureGroups(_ readings: [Reading]) -> [TemperatureGroup] {
    var byName: [String: [Double]] = [:]
    var order: [String] = []
    for reading in readings where reading.sensor.kind == .temperature {
        let name = groupName(reading.sensor.name)
        if byName[name] == nil { order.append(name) }
        byName[name, default: []].append(reading.value)
    }
    return order.map { name in
        let values = byName[name]!
        return TemperatureGroup(name: name, celsius: hotWeighted(values), coolest: values.min()!,
                                hottest: values.max()!, count: values.count)
    }
    .sorted { ($0.celsius, $1.name) > ($1.celsius, $0.name) }
}

/// The menu bar's CPU and GPU figures: the core sensors, weighted toward the
/// hottest. Without core sensors, every sensor in the group counts.
func cpuAndGPU(_ readings: [Reading]) -> (cpu: Double?, gpu: Double?) {
    func figure(_ group: SensorGroup) -> Double? {
        let temperatures = readings.filter { $0.sensor.kind == .temperature && $0.sensor.group == group }
        let cores = temperatures.filter(\.sensor.core)
        let values = (cores.isEmpty ? temperatures : cores).map(\.value)
        return values.isEmpty ? nil : hotWeighted(values)
    }
    return (figure(.cpu), figure(.gpu))
}

// MARK: - Units

/// °F where the Mac's region measures in US units, °C elsewhere.
let usesFahrenheit = Locale.current.measurementSystem == .us

func degrees(_ celsius: Double, unit: Bool = true) -> String {
    let value = usesFahrenheit ? celsius * 9 / 5 + 32 : celsius
    return String(format: "%.0f°", value) + (unit ? (usesFahrenheit ? "F" : "C") : "")
}

func formatReading(_ reading: Reading) -> String {
    switch reading.sensor.kind {
    case .temperature: return degrees(reading.value)
    case .voltage: return String(format: "%.2f V", reading.value)
    case .current: return String(format: "%.2f A", reading.value)
    case .power: return String(format: "%.1f W", reading.value)
    case .fan: return String(format: "%.0f RPM", reading.value)
    }
}
