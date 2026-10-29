// MacStats' tests: a program that drives the built MacStats binary through its command
// line (the flags main.swift lists) and checks what it prints and draws. A plain program
// rather than XCTest or Swift Testing because MacStats builds with the Xcode Command Line
// Tools alone, which ship neither. Run with `make test`, which builds both first; this
// finds MacStats beside itself in the build directory.
//
// Tests that need hardware the Mac may lack (sensors, a GPU, a battery, Apple silicon)
// skip with a note rather than fail, so they pass on a virtual machine too.

import Foundation

// MARK: - The harness

// Line-buffered output, so a crash in a test cannot hide which test it was.
setvbuf(stdout, nil, _IOLBF, 0)

let testsBinary = Bundle.main.executableURL!.resolvingSymlinksInPath()
let buildDir = testsBinary.deletingLastPathComponent()
let macstats = buildDir.appendingPathComponent("MacStats").path
let root = buildDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let sources = root.appendingPathComponent("Sources/MacStats")

struct Run {
    let status: Int32
    let stdout: String
    let stderr: String
    var lines: [String] { stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n") }
}

/// Runs a program; `ok` means a non-zero exit fails the test. `env` adds to (or replaces in)
/// this program's environment.
@discardableResult
func run(
    _ path: String, _ arguments: [String], ok: Bool = true, timeout: TimeInterval = 120, stdin: String? = nil,
    env: [String: String] = [:]
) throws -> Run {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if !env.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    let input = Pipe()
    process.standardInput = stdin == nil ? FileHandle.nullDevice : input
    try process.run()
    if let stdin {
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()  // so the program sees the end of its input
    }
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    deadline.cancel()
    let result = Run(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    if ok && result.status != 0 {
        throw Failure("\(URL(fileURLWithPath: path).lastPathComponent) \(arguments.joined(separator: " ")) exited \(result.status)\n\(stdout)\(stderr)")
    }
    return result
}

func macStats(
    _ arguments: String..., ok: Bool = true, timeout: TimeInterval = 120, stdin: String? = nil, env: [String: String] = [:]
) throws -> Run {
    try run(macstats, arguments, ok: ok, timeout: timeout, stdin: stdin, env: env)
}

func macStats(_ arguments: [String]) throws -> Run { try run(macstats, arguments) }

struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
struct Skip: Error { let reason: String }

var failures: [String] = []
var currentFailures: [String] = []

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { currentFailures.append("\(message) (line \(line))") }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    if actual != expected { currentFailures.append("\(message): expected \(expected), got \(actual) (line \(line))") }
}

func skip(_ reason: String) throws -> Never { throw Skip(reason: reason) }

var passed = 0, skipped = 0
func test(_ name: String, _ body: () throws -> Void) {
    currentFailures = []
    do {
        try body()
    } catch let failure as Failure {
        currentFailures.append(failure.message)
    } catch let skipped as Skip {
        print("skip \(name): \(skipped.reason)")
        MacStatsTests.skipped += 1
        return
    } catch {
        currentFailures.append("\(error)")
    }
    if currentFailures.isEmpty {
        print("ok   \(name)")
        passed += 1
    } else {
        print("FAIL \(name)")
        for failure in currentFailures { print("     \(failure)") }
        failures.append(name)
    }
}

enum MacStatsTests { static var skipped = 0 }

func tempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("macstats-tests-\(name)-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func pngWidth(_ path: String) throws -> Int {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count > 24, data[0] == 0x89, data[1] == 0x50, data[2] == 0x4e, data[3] == 0x47 else { throw Failure("\(path) is not a PNG") }
    return data[16..<20].reduce(0) { $0 << 8 | Int($1) }
}

func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

/// The tab-separated fields of the first line starting with `title`.
func fields(_ lines: [String], _ title: String) -> [String]? {
    lines.first { $0.hasPrefix(title + "\t") }?.components(separatedBy: "\t").dropFirst().map { $0 }
}

func section(_ lines: [String], _ heading: String) -> [[String]] {
    guard let start = lines.firstIndex(of: heading) else { return [] }
    return lines[(start + 1)...].prefix { $0.contains("\t") }.map { $0.components(separatedBy: "\t") }
}

func number(_ text: String) -> Double {
    Double(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? .nan
}

let isAppleSilicon = (try? run("/usr/bin/uname", ["-m"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == "arm64"
let cpuBrand = (try? run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
/// GitHub's macOS runners are virtual machines: no sensors, no CPU clusters in the registry,
/// and a virtual GPU. Checks that need the real hardware hold only off one.
let isVirtualMachine = (try? run("/usr/sbin/sysctl", ["-n", "kern.hv_vmm_present"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) == "1"
let chipHasSensors: Bool = {
    guard let lines = try? macStats("--sensors").lines else { return false }
    return lines.contains("Temperature")
}()

guard FileManager.default.isExecutableFile(atPath: macstats) else {
    print("MacStatsTests: no MacStats binary beside me at \(macstats); run `make test`, which builds both.")
    exit(2)
}

// MARK: - The repository

test("carries no machine paths, and credits Stats beside the code adapted from it") {
    let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }.sorted()
    check(files.count >= 14, "has the feature files (\(files.count))")
    for file in files {
        let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
        check(!text.contains("/Users/"), "\(file) names no home directory")
    }
    let licence = try String(contentsOf: root.appendingPathComponent("LICENSE-stats.txt"), encoding: .utf8)
    check(licence.contains("MIT License") && licence.contains("Serhiy Mytrovtsiy"), "LICENSE-stats.txt is Stats' MIT licence")
    for file in ["SMC.swift", "SensorCatalog.swift", "CPU.swift", "GPU.swift", "RAM.swift", "IOReport.swift"] {
        let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
        check(text.contains("LICENSE-stats.txt"), "\(file) credits Stats")
    }
    for script in ["install.sh", "scripts/bundle.sh"] {
        try run("/bin/sh", ["-n", root.appendingPathComponent(script).path])
    }
    let bundle = try String(contentsOf: root.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
    check(bundle.contains("CFBundleIconFile</key><string>AppIcon"), "bundle.sh names the icon in Info.plist")
    let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    check(matches(version, "^[0-9]+\\.[0-9]+\\.[0-9]+$"), "VERSION is x.y.z (\(version))")
    checkEqual(try macStats("--version").lines, ["unbundled"], "a bare binary has no version; the bundle stamps one")
}

// MARK: - The menu bar items

test("renders the CPU item as its usage, as wide for any value") {
    let dir = try tempDir("png")
    let cpu = try macStats("--render", "cpu", dir.appendingPathComponent("cpu.png").path).stdout
    check(matches(cpu, "^[0-9]+%\n$"), "prints the CPU's usage, not \(cpu.debugDescription)")
    let ram = try macStats("--render", "ram", dir.appendingPathComponent("ram.png").path).stdout
    // The item is as wide as "100%" whatever it shows, so the items beside it never shift.
    checkEqual(try pngWidth(dir.appendingPathComponent("cpu.png").path), try pngWidth(dir.appendingPathComponent("ram.png").path),
               "the CPU and RAM items are as wide whatever their values (CPU \(cpu.trimmingCharacters(in: .newlines)), RAM \(ram.trimmingCharacters(in: .newlines)))")
}

test("renders the GPU item as its utilization") {
    let png = try tempDir("png").appendingPathComponent("gpu.png").path
    let result = try macStats("--render", "gpu", png, ok: false)
    if result.status != 0 { try skip("no GPU to read: \(result.stderr.trimmingCharacters(in: .newlines))") }
    check(matches(result.stdout, "^[0-9]+%\n$"), "prints a percentage")
    _ = try pngWidth(png)
}

test("renders the RAM item as the share of memory in use") {
    let png = try tempDir("png").appendingPathComponent("ram.png").path
    check(matches(try macStats("--render", "ram", png).stdout, "^[0-9]+%\n$"), "prints a percentage")
    _ = try pngWidth(png)
}

test("renders the Disk item as its free space in whole GB") {
    let png = try tempDir("png").appendingPathComponent("disk.png").path
    check(matches(try macStats("--render", "disk", png).stdout, "^[0-9]+ GB\n$"), "prints whole GB")
    _ = try pngWidth(png)
}

test("renders the Temp item as the hottest part's temperature") {
    let png = try tempDir("png").appendingPathComponent("temp.png").path
    check(matches(try macStats("--render", "temp", png).stdout, "^([0-9]+°|–)\n$"), "prints a temperature, or – without sensors")
    _ = try pngWidth(png)
}

test("draws the CS logo app icon at every size iconutil packs") {
    let dir = try tempDir("icon")
    let iconset = dir.appendingPathComponent("AppIcon.iconset")
    _ = try macStats("--write-icon", iconset.path)
    let files = try FileManager.default.contentsOfDirectory(atPath: iconset.path).sorted()
    checkEqual(files.count, 10, "five sizes, each at 1x and 2x")
    for file in files {
        guard let match = file.range(of: "^icon_([0-9]+)x\\1(@2x)?\\.png$", options: .regularExpression) else {
            check(false, "\(file) is named as iconutil wants"); continue
        }
        _ = match
        let points = Int(file.split(separator: "_")[1].split(separator: "x")[0])!
        checkEqual(try pngWidth(iconset.appendingPathComponent(file).path), points * (file.contains("@2x") ? 2 : 1), "\(file)'s width")
    }
    try run("/usr/bin/iconutil", ["-c", "icns", "-o", dir.appendingPathComponent("AppIcon.icns").path, iconset.path])
}

// MARK: - The panels

test("explains every legend key with a tooltip, and keeps every tooltip to two lines") {
    // <panel> <key|other> <name> <lines> <widest line in pt> <text>
    let tips = try macStats("--tooltips", timeout: 60).lines.map { $0.components(separatedBy: "\t") }
    let keys = { (panel: String) in tips.filter { $0[0] == panel && $0[1] == "key" }.map { $0[2] } }
    checkEqual(Array(keys("CPU").prefix(4)), ["System", "User", "Idle", "Load"], "the CPU keys")
    checkEqual(keys("GPU"), ["Utilization", "Renderer", "Tiler"], "the GPU keys")
    checkEqual(keys("RAM"), ["App", "Wired", "Compressed", "Free", "Swap"], "the RAM keys")
    checkEqual(keys("Disk").sorted(), ["Free", "Purgeable", "macOS system", "my apps / files", "other", "recovery", "swap", "update/boot"], "the Disk keys")
    if chipHasSensors { check(!keys("Temp").isEmpty, "the Temp panel has rows") }
    let diskOther = tips.filter { $0[0] == "Disk" && $0[1] == "other" }.map { $0[5] }
    check(diskOther.contains { $0.hasPrefix("Opens this folder once") }, "the Grant button's tooltip")
    check(diskOther.contains { $0.hasPrefix("macOS has no dialog for this folder") }, "the no-button tooltip")
    check(diskOther.contains { $0.hasPrefix("Allowed in System Settings") }, "the refused folder's tooltip")
    check(diskOther.contains { $0.hasPrefix("Opens what was added since") }, "the Grant button's tooltip on a media folder that left something out")
    for tip in tips where tip.count == 6 {
        let (panel, kind, name, lines, widest, text) = (tip[0], tip[1], tip[2], Int(tip[3]) ?? 0, Int(tip[4]) ?? 0, tip[5])
        if kind == "key" { check(text.count >= 20, "\(panel) › \(name) explains itself (\(text.debugDescription))") }
        if name == "NSTableCellView" { continue }  // a folder's path
        // A process row's command line may run to the width at which the tooltip wraps.
        check(lines <= 2 && widest <= (name == "ProcessRow" ? 320 : 240), "\(panel) › \(name) fits two lines: \(lines) lines, \(widest) pt")
    }
}

test("reads the CPU: System, User and Idle add up, each core type, load, clock speeds and processes") {
    let lines = try macStats("--cpu", timeout: 30).lines
    let percent = { (title: String) in number(fields(lines, title)?.first ?? "") }
    let sum = percent("System") + percent("User") + percent("Idle")
    check(abs(sum - 100) <= 2, "System, User and Idle add up to 100% (\(sum))")
    for title in ["1 minute", "5 minutes", "15 minutes"] { check(number(fields(lines, title)?.first ?? "") >= 0, "\(title) load") }
    let cores = section(lines, "Cores")
    if isAppleSilicon && cores.isEmpty {
        check(isVirtualMachine, "an Apple silicon Mac names its core clusters in the registry (a virtual machine does not)")
    }
    if isAppleSilicon && !cores.isEmpty {
        let total = cores.reduce(0) { $0 + (Int($1[1]) ?? 0) }
        let ncpu = Int(try run("/usr/sbin/sysctl", ["-n", "hw.ncpu"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
        checkEqual(total, ncpu, "the core types hold every core")
        for core in cores {
            let mhz = core[2].components(separatedBy: ",").map { Int($0.components(separatedBy: " ")[0]) ?? 0 }
            check(mhz.count > 1 && zip(mhz, mhz.dropFirst()).allSatisfy { $0 <= $1 } && mhz.allSatisfy { $0 > 0 }, "\(core[0])' clock steps rise")
            if let speed = section(lines, "Frequency").first(where: { $0[0] == core[0] }).flatMap({ Int($0[1].components(separatedBy: " ")[0]) }) {
                check(speed >= mhz[0] && speed <= mhz.last!, "\(core[0])' speed (\(speed) MHz) is within its steps")
            }
        }
    }
    let processes = section(lines, "Top processes").map { number($0[1]) }
    check(!processes.isEmpty, "lists processes")
    check(zip(processes, processes.dropFirst()).allSatisfy { $0 >= $1 }, "the busiest first")
    check(section(lines, "Top processes").allSatisfy { $0.count == 3 }, "each process has a name, its usage and a detail")
}

test("says what a process is doing: its command, its folder and what started it") {
    // A shell told to run two commands keeps running itself (one command it would hand over to).
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacStats Work \(getpid())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let shell = Process()
    shell.executableURL = URL(fileURLWithPath: "/bin/sh")
    shell.arguments = ["-c", "sleep 30; true"]
    shell.currentDirectoryURL = folder
    shell.standardOutput = FileHandle.nullDevice
    try shell.run()
    defer { shell.terminate() }
    let report = try macStats("--process", String(shell.processIdentifier)).lines.map { $0.components(separatedBy: "\t") }
    let field = { (title: String) in report.filter { $0.count == 2 && $0[0] == title }.map { $0[1] } }
    checkEqual(field("Name"), ["sh"], "the shell's name")
    checkEqual(field("Detail"), ["sleep 30; true · MacStats Work \(getpid())"], "its command and its folder")
    let tooltip = field("Tooltip")
    checkEqual(tooltip.count, 2, "a two-line tooltip")
    checkEqual(tooltip.first, "sh -c sleep 30; true", "the command line")
    // The folder follows the ancestors only when the line has room for it (it depends on
    // what runs the tests), so the detail above is where it is checked.
    check(tooltip.last?.hasPrefix("Started by MacStatsTests") == true, "started by this program: \(tooltip.last ?? "")")
    checkEqual(try macStats("--process", "2147483000", ok: false).status, 1, "no such process")
}

test("names a Claude Code session by its title") {
    // A stand-in "claude" (a copy of sleep) with its own settings folder, as Claude Code
    // keeps them: a record of the running session, and a transcript whose latest title wins.
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("MacStats Claude \(getpid())")
    let settings = base.appendingPathComponent("settings"), work = base.appendingPathComponent("Work Folder")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let claude = base.appendingPathComponent("claude")
    try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: claude.path)
    let session = Process()
    session.executableURL = claude
    session.arguments = ["30"]
    session.currentDirectoryURL = work
    session.environment = ["CLAUDE_CONFIG_DIR": settings.path]
    try session.run()
    defer { session.terminate() }
    let pid = session.processIdentifier
    // The transcript under another folder's name, as for a session that moved.
    let transcripts = settings.appendingPathComponent("projects/-elsewhere")
    try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: settings.appendingPathComponent("sessions"), withIntermediateDirectories: true)
    let record = #"{"pid":\#(pid),"sessionId":"test-session","cwd":"\#(work.path)","status":"busy","name":"x-1","nameSource":"derived"}"#
    try record.write(to: settings.appendingPathComponent("sessions/\(pid).json"), atomically: true, encoding: .utf8)
    let transcript = [
        #"{"type":"user","message":{"content":"a -title\" that is not one"}}"#,
        #"{"type":"ai-title","aiTitle":"First title","sessionId":"test-session"}"#,
        #"{"type":"ai-title","aiTitle":"Fix the login page","sessionId":"test-session"}"#,
    ].joined(separator: "\n") + "\n"
    try transcript.write(to: transcripts.appendingPathComponent("test-session.jsonl"), atomically: true, encoding: .utf8)
    let report = try macStats("--process", String(pid)).lines.map { $0.components(separatedBy: "\t") }
    let field = { (title: String) in report.filter { $0.count == 2 && $0[0] == title }.map { $0[1] } }
    checkEqual(field("Name"), ["claude"], "the session's name")
    checkEqual(field("Detail"), ["Fix the login page · Work Folder"], "its latest title and its folder")
    checkEqual(field("Tooltip").first, "Claude Code, working: Fix the login page", "whether it is working, and its title")
}

test("reads the GPU: utilization, renderer, tiler, memory, model and the apps using it") {
    let result = try macStats("--gpu", ok: false, timeout: 30)
    if result.status != 0 { try skip("no GPU to read") }
    let lines = result.lines
    for title in ["Utilization", "Renderer", "Tiler"] {
        let percent = number(fields(lines, title)?.first ?? "")
        check(percent >= 0 && percent <= 100, "\(title) is a percentage")
    }
    let memory = (fields(lines, "Memory") ?? []).map { Double($0) ?? -1 }
    check(memory.count == 3 && memory[0] >= 0 && memory[1] >= 0, "GPU memory figures are read (\(memory))")
    if !isVirtualMachine {
        check(memory.count == 3 && memory[0] <= memory[1], "GPU memory in use is within what is set aside (\(memory))")
    }
    let ram = Double(try run("/usr/sbin/sysctl", ["-n", "hw.memsize"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    check(memory.count == 3 && memory[2] > 0 && memory[2] <= ram, "the GPU memory limit is at most the Mac's memory")
    check(!(fields(lines, "Model")?.first ?? "").isEmpty, "names the GPU")
    let apps = section(lines, "Top GPU apps").map { number($0[1]) }
    check(zip(apps, apps.dropFirst()).allSatisfy { $0 >= $1 }, "the busiest app first")
}

test("splits memory into App, Wired, Compressed and Free, and lists the top processes") {
    let lines = try macStats("--memory").lines
    let row = { (title: String) in Double(fields(lines, title)?[1] ?? "") ?? .nan }
    let usage = section(lines, "Usage").map { $0[0] }
    checkEqual(usage, ["Used", "App", "Wired", "Compressed", "Free", "Swap", "Total"], "the rows in Stats' order")
    let close = { (a: Double, b: Double) in abs(a - b) <= 0.01 * row("Total") }
    check(close(row("App") + row("Wired") + row("Compressed"), row("Used")), "App, Wired and Compressed make Used")
    check(close(row("Used") + row("Free"), row("Total")), "Used and Free make all memory")
    let processes = section(lines, "Top processes").map { Double($0[2]) ?? 0 }
    check(!processes.isEmpty && processes.count <= 8, "up to eight processes")
    check(zip(processes, processes.dropFirst()).allSatisfy { $0 >= $1 }, "biggest first")
}

test("rates power use by this Mac's tiers") {
    let level = { (watts: Double) in try macStats("--power-level", String(watts)).stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    // The M4 MacBook Air: normal below 10 W, moderate below 20 W, high from 20 W.
    if isAppleSilicon && matches(cpuBrand, "Apple M[0-9]+$") {
        checkEqual(try [9.9, 10, 19.9, 20, 31].map(level), ["normal", "moderate", "moderate", "high", "high"], "the plain M-chip tiers")
    }
    let sensors = try macStats("--sensors", ok: false)
    if sensors.status != 0 { try skip("this Mac reports no sensors") }
    let gauges = sensors.lines
    if let hottest = fields(gauges, "Hottest"), let top = section(gauges, "Temperature").first {
        checkEqual(hottest[0], top[0], "the gauge shows the top Temperature row")
    }
}

test("weights a group toward its hottest sensor") {
    func weigh(_ values: [Double]) throws -> Double {
        Double(try macStats(["--weigh"] + values.map { String($0) }).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .nan
    }
    checkEqual(try weigh([50]), 50, "one sensor")
    checkEqual(try weigh([50, 50, 50]), 50, "equal sensors")
    // One sensor 3 °C cooler counts e^-1 ≈ 37%: (53 + 50 * 0.368) / 1.368 ≈ 52.19.
    checkEqual(try weigh([53, 50]), 52.19, "a cooler sensor counts less")
    let values = [49.8, 53.0, 51.85, 51.83, 49.76, 49.88, 52.4, 50.26, 50.37]
    let mean = values.reduce(0, +) / Double(values.count)
    let weighted = try weigh(values)
    check(weighted > mean && weighted < values.max()!, "between the average and the hottest")
}

test("colours each temperature row by that part's own limits") {
    let heat = { (name: String, celsius: Double) in try macStats("--heat", name, String(celsius)).stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    // [row, yellow from, red from]: a chip runs hot by design, a battery and an SSD do not.
    for (name, warm, hot) in [("CPU performance cores", 85.0, 100.0), ("GPU", 85, 100), ("Battery", 35, 40), ("SSD", 50, 70), ("Wi-Fi", 60, 80)] {
        checkEqual(try heat(name, warm - 0.1), "green", "\(name) below \(warm) °C")
        checkEqual(try heat(name, warm), "yellow", "\(name) at \(warm) °C")
        checkEqual(try heat(name, hot - 0.1), "yellow", "\(name) below \(hot) °C")
        checkEqual(try heat(name, hot), "red", "\(name) at \(hot) °C")
    }
}

test("lists each part of the Mac once, with no numbered sensors left") {
    if !chipHasSensors { try skip("this Mac reports no temperature sensors") }
    let rows = section(try macStats("--sensors").lines, "Temperature")
    check(!rows.isEmpty, "has temperature rows")
    let names = rows.map { $0[0] }
    checkEqual(Set(names).count, names.count, "each part appears once")
    for name in names { check(!matches(name, "( [0-9]+| [A-Z]| \\([A-Z0-9]\\))$"), "\(name) is not a numbered sensor") }
    let celsius = rows.map { number($0[1]) }
    check(zip(celsius, celsius.dropFirst()).allSatisfy { $0 >= $1 }, "hottest first")
    if isAppleSilicon {
        check(names.contains { matches($0, "^CPU (performance|efficiency) cores$") }, "CPU cores are grouped")
        check(names.contains("GPU"), "GPU sensors are grouped")
    }
}

test("puts voltage, current and power in one plain Power section") {
    let sensors = try macStats("--sensors", ok: false)
    if sensors.status != 0 { try skip("this Mac reports no sensors") }
    let lines = sensors.lines
    for raw in ["Voltage", "Current"] { check(!lines.contains(raw), "no separate \(raw) section") }
    let titles = section(lines, "Power").map { $0[0] }
    if titles.isEmpty { try skip("this Mac reports no power sensors") }
    for raw in ["System Total", "DC In", "12V rail"] { check(!titles.contains(raw), "\(raw) is shown in plain words") }
    if isAppleSilicon { checkEqual(titles.first, "Total", "what the whole Mac uses comes first") }
    let hasBattery = try run("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"]).stdout.contains("AppleRawMaxCapacity")
    if hasBattery {
        let row = section(lines, "Power").first { $0[0] == "Battery left" }
        check(row != nil, "a Mac with a battery shows what is left in it")
        check(matches(row?[1] ?? "", "^[0-9]+\\.[0-9]/[0-9]+\\.[0-9] Wh \\([0-9]+%\\)$"), "as left/full Wh and the percentage")
    }
}

test("gives every Disk Spaces row under Used a colour, biggest first, Free last") {
    let rows = try macStats("--legend").lines.map { $0.components(separatedBy: "\t") }
    checkEqual(rows.map { $0[0] }.sorted(), ["Free", "Purgeable", "macOS system", "my apps / files", "other", "recovery", "swap", "update/boot"], "the rows")
    for row in rows { check(row.count > 1 && !row[1].isEmpty, "\(row[0]) has a colour") }
    checkEqual(rows.last?[0], "Free", "Free is always last")
    let sizes = rows.dropLast().map { Double($0[2]) ?? 0 }
    check(zip(sizes, sizes.dropFirst()).allSatisfy { $0 >= $1 }, "the rest go biggest first")
}

test("lists the disk's five spaces in order") {
    checkEqual(try macStats("--spaces").lines.map { $0.components(separatedBy: "\t")[0] },
               ["macOS system", "update/boot", "recovery", "swap", "my apps / files"], "the five spaces")
}

test("lists external volumes with their used and total bytes") {
    let rows = try macStats("--volumes").lines.filter { !$0.isEmpty }.map { $0.components(separatedBy: "\t") }
    for row in rows {
        checkEqual(row.count, 5, "name, used, total, mount point, state: \(row)")
        let used = Int64(row[1]) ?? -1, total = Int64(row[2]) ?? -1
        check(used >= 0 && total > 0 && used <= total, "\(row[0]) used \(used) of \(total)")
        check(FileManager.default.fileExists(atPath: row[3]), "\(row[3]) is mounted")
        check(["granted", "private", "no access"].contains(row[4]), "a known state, got \(row[4])")
    }
    // With no external disk the flag prints nothing; that is a pass too.
}

test("--report ends with a line per external volume") {
    let volumes = try macStats("--volumes").lines.filter { !$0.isEmpty }
    if volumes.isEmpty { try skip("no external disk attached") }
    let report = try macStats("--report", timeout: 600).lines
    for volume in volumes {
        let name = volume.components(separatedBy: "\t")[0]
        check(report.contains { $0.hasPrefix(name + "\t") && $0.contains(" of ") }, "a line for \(name)")
    }
}

test("knows which build it is") {
    // Its designated requirement (`cdhash H"…"` here, built on this Mac), or unsigned.
    let suite = "sh.csarko.MacStats.tests.\(UUID().uuidString.prefix(8))"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let build = fields(try macStats("--grants", "--defaults-suite", suite).lines, "build")?.first ?? ""
    check(!build.isEmpty, "a requirement or unsigned, got nothing")
}

test("forgets grants made by another build") {
    let suite = "sh.csarko.MacStats.tests.\(UUID().uuidString.prefix(8))"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    _ = try macStats("--grants", "--defaults-suite", suite, "--as-build", "aaa", "--add-folder", "/Users/alice/Downloads",
                     "--add-volume", "1234-ABCD")
    let same = try macStats("--grants", "--defaults-suite", suite, "--as-build", "aaa").lines
    checkEqual(fields(same, "folder")?.first, "/Users/alice/Downloads", "remembered in the same build")
    checkEqual(fields(same, "volume")?.first, "1234-ABCD", "the disk remembered by its UUID")
    let other = try macStats("--grants", "--defaults-suite", suite, "--as-build", "bbb").lines
    check(fields(other, "folder") == nil, "a different build starts with no folder grants")
    check(fields(other, "volume") == nil, "nor disk grants")
    let unsigned = try macStats("--grants", "--defaults-suite", suite, "--as-build", "unsigned", "--add-folder", "/Users/alice/Desktop").lines
    check(fields(unsigned, "folder") == nil, "an unsigned build remembers nothing")
    // A suite flag with no name stops, rather than writing the real grants.
    let missing = try macStats("--grants", "--defaults-suite", "--add-folder", "/Users/alice/Desktop", ok: false)
    checkEqual(missing.status, 2, "--defaults-suite without a name fails")
}

test("never opens a remembered grant from the command line") {
    // A grant remembered under this very build, in a throwaway suite: the flags still treat
    // the folder as private, since a binary started from a terminal would open it on the
    // terminal's behalf.
    let suite = "sh.csarko.MacStats.tests.\(UUID().uuidString.prefix(8))"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let env = ["MACSTATS_DEFAULTS_SUITE": suite]
    let dir = try tempDir("remembered")
    try writeTree(dir, [("Users/alice/Downloads/a.bin", 2), ("Users/alice/Code/c.bin", 1)])
    let downloads = dir.path + "/Users/alice/Downloads"
    let grants = try macStats("--grants", "--add-folder", downloads, env: env).lines
    if fields(grants, "build")?.first != "unsigned" {
        checkEqual(fields(grants, "folder")?.first, downloads, "the grant is remembered in the suite")
    }
    let lines = try macStats("--report", dir.path, "--min-mb", "1", env: env).lines.map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 1 MB", "  alice | ≥ 1 MB", "    Code | 1 MB", "    Downloads | private"], "the rows")
}

test("ships the menu bar items' order, CPU to Disk from the left") {
    let rows = try macStats("--item-positions").lines.map { $0.components(separatedBy: "\t") }
    checkEqual(rows.map { $0[0] }, ["MacStatsCPU", "MacStatsGPU", "MacStatsRAM", "MacStatsTemp", "MacStatsDisk"], "the names")
    let positions = rows.compactMap { Double($0[1]) }
    check(positions == positions.sorted(by: >), "a larger number sits further left, so they descend")
    checkEqual(positions.count, 5, "every item has a position")
}

/// Writes files of the given sizes under a fresh folder and returns the Disk panel's report of it.
/// Writes each file (path under `dir`, size in megabytes) with random contents.
func writeTree(_ dir: URL, _ files: [(String, Double)]) throws {
    for (path, megabytes) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: Int(megabytes * 1024 * 1024))
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: url)
    }
}

func tree(_ files: [(String, Double)]) throws -> [String] {
    let dir = try tempDir("tree")
    try writeTree(dir, files)
    return try macStats("--report", dir.path, "--min-mb", "1").lines.map { $0.replacingOccurrences(of: "\t", with: " | ") }
}

test("lists folders three deep, biggest first, with an app as one row") {
    let lines = try tree([
        ("small/a/b/c/four-deep.bin", 3), ("big/one.bin", 5), ("Thing.app/Contents/MacOS/thing", 2), ("tiny/under-the-cut-off.bin", 0.25),
    ])
    checkEqual(lines.map { $0.components(separatedBy: " | ")[0] }, ["big", "small", "  a", "    b", "Thing.app"], "the rows")
}

test("lists private folders by name without counting what is in them") {
    let lines = try tree([
        ("Users/alice/Projects/code.bin", 3), ("Users/alice/Documents/secret.bin", 9), ("Users/alice/Music/song.bin", 9),
        ("Users/alice/Library/Containers/app/data.bin", 9), ("Users/alice/Library/Caches/cache.bin", 2),
        ("Users/alice/Pictures/Photos Library.photoslibrary/photo.bin", 9), ("Users/alice/Pictures/mine.bin", 2),
    ])
    checkEqual(lines, [
        "Users | ≥ 7 MB", "  alice | ≥ 7 MB", "    Projects | 3 MB", "    Library | ≥ 2 MB", "    Pictures | ≥ 2 MB",
        "    Documents | private", "    Music | private",
    ], "the rows")
}

test("says which private rows can be granted") {
    let home = "/Users/" + NSUserName()
    checkEqual(try macStats("--grantable", home + "/Downloads").lines, ["dialog"], "Downloads")
    checkEqual(try macStats("--grantable", home + "/Music").lines, ["dialog"], "Music")
    checkEqual(try macStats("--grantable", "/Volumes/Some Disk").lines, ["dialog"], "a volume")
    checkEqual(try macStats("--grantable", home + "/Library/Mail").lines, ["none"], "Mail")
    checkEqual(try macStats("--grantable", home + "/Library/Containers").lines, ["none"], "containers")
    checkEqual(try macStats("--grantable", home + "/Pictures/Photos Library.photoslibrary").lines, ["none"], "a photos library")
    checkEqual(try macStats("--grantable", "/System/Volumes/Data" + home + "/Documents").lines, ["dialog"], "the data volume's spelling")
    checkEqual(try macStats("--grantable", home + "/Documents/Deeper").lines, ["none"], "below a guarded folder")
    checkEqual(try macStats("--grantable", try tempDir("plain").path).lines, ["not private"], "a plain folder")
}

test("counts a granted private folder and still skips the others") {
    let dir = try tempDir("granted")
    try writeTree(dir, [("Users/alice/Documents/a.bin", 4), ("Users/alice/Downloads/b.bin", 2), ("Users/alice/Code/c.bin", 1)])
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--granted", dir.path + "/Users/alice/Documents").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 5 MB", "  alice | ≥ 5 MB", "    Documents | 4 MB", "    Code | 1 MB", "    Downloads | private"], "the rows")
}

test("grants one folder: its size appears and reaches its parents") {
    let dir = try tempDir("splice")
    try writeTree(dir, [("Users/alice/Documents/a.bin", 4), ("Users/alice/Downloads/b.bin", 2), ("Users/alice/Code/c.bin", 1)])
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--then-grant", dir.path + "/Users/alice/Documents").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 5 MB", "  alice | ≥ 5 MB", "    Documents | 4 MB", "    Code | 1 MB", "    Downloads | private"], "the rows")
}

test("clears ≥ only when nothing unmeasured is left") {
    let dir = try tempDir("splice-clear")
    try writeTree(dir, [("Users/alice/Documents/a.bin", 4), ("Users/alice/Code/c.bin", 1)])
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--then-grant", dir.path + "/Users/alice/Documents").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | 5 MB", "  alice | 5 MB", "    Documents | 4 MB", "    Code | 1 MB"], "no ≥ remains")
}

test("keeps ≥ when a dropped small folder hid a private one") {
    let dir = try tempDir("splice-dropped")
    try writeTree(dir, [("Users/alice/Documents/a.bin", 4), ("Users/alice/Code/c.bin", 1), ("Users/alice/Library/Mail/m.bin", 0.1)])
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--then-grant", dir.path + "/Users/alice/Documents").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 5 MB", "  alice | ≥ 5 MB", "    Documents | 4 MB", "    Code | 1 MB"], "Library stays dropped, ≥ stays")
}

test("shows a refused folder as no access") {
    let dir = try tempDir("refused")
    try writeTree(dir, [("Users/alice/Documents/a.bin", 4), ("Users/alice/Code/c.bin", 1)])
    let documents = dir.path + "/Users/alice/Documents"
    chmod(documents, 0)
    defer { chmod(documents, 0o755) }
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--then-grant", documents).lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 1 MB", "  alice | ≥ 1 MB", "    Code | 1 MB", "    Documents | no access"], "the rows")
}

test("opens only what a granted Music held at the click") {
    // `New` was made after the click (as the Music app makes `Music/Music` the first time it
    // runs), so it was never asked about: left out, and Music's size is a minimum.
    let dir = try tempDir("snapshot")
    try writeTree(dir, [("Users/alice/Music/Old/a.bin", 2), ("Users/alice/Music/New/b.bin", 3)])
    let music = dir.path + "/Users/alice/Music"
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--granted", music, "--snapshot", music + "=Old").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 2 MB", "  alice | ≥ 2 MB", "    Music | ≥ 2 MB"], "the rows")
    // Measured from Music itself, its folders are listed: only Old.
    let inside = try macStats("--report", music, "--min-mb", "1", "--snapshot", music + "=Old").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(inside, ["Old | 2 MB"], "only the folder named at the click")
}

test("keeps a granted Music under the cut when a folder inside it was left out") {
    // Music holds 0.5 MB that was asked about, plus `New`, which the click never asked about.
    // Music is under the 1 MB cut, but its row stays: it is a minimum, and the row is where its
    // Grant button and tooltip live. (`Other` keeps Users and alice over the cut, as a real home is.)
    let dir = try tempDir("snapshot-small")
    try writeTree(dir, [("Users/alice/Other/c.bin", 2), ("Users/alice/Music/Old/a.bin", 0.5), ("Users/alice/Music/New/b.bin", 0.5)])
    let music = dir.path + "/Users/alice/Music"
    let lines = try macStats("--report", dir.path, "--min-mb", "1", "--granted", music, "--snapshot", music + "=Old").lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 3 MB", "  alice | ≥ 3 MB", "    Other | 2 MB", "    Music | ≥ 1 MB"], "the rows")
}

test("keeps refused and droppedUnmeasured through a save, and leaves out a 1.0.0 Volumes row") {
    let json = #"{"measuredAt":0,"folders":["#
        + #"{"title":"Volumes","path":"/System/Volumes/Data/Volumes","bytes":7000000},"#
        + #"{"title":"Users","path":"/Users","bytes":5000000,"partial":true,"droppedUnmeasured":true,"children":["#
        + #"{"title":"alice","path":"/Users/alice","bytes":5000000,"partial":true,"children":["#
        + #"{"title":"Downloads","path":"/Users/alice/Downloads","bytes":0,"note":"no access","refused":true}]}]}]}"#
    let granted = ["--granted", "/Users/alice/Downloads"]
    let lines = try run(macstats, ["--read-measurement", "-"] + granted, stdin: json).lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 5 MB", "  alice | ≥ 5 MB", "    Downloads | no access"], "the rows")
    let saved = try run(macstats, ["--read-measurement", "-", "--json"] + granted, stdin: json).stdout
    let object = try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any]
    let folders = object?["folders"] as? [[String: Any]] ?? []
    checkEqual(folders.compactMap { $0["title"] as? String }, ["Users"], "the Volumes row is left out")
    checkEqual(folders.first?["droppedUnmeasured"] as? Bool, true, "droppedUnmeasured survives")
    let alice = (folders.first?["children"] as? [[String: Any]])?.first
    let downloads = (alice?["children"] as? [[String: Any]])?.first
    checkEqual(downloads?["refused"] as? Bool, true, "refused survives")
    checkEqual(downloads?["note"] as? String, "no access", "the note survives")
}

test("reads a saved measurement without the new keys") {
    // 5000000 bytes: the brief's 5 would print as 0 MB.
    let json = #"{"measuredAt":0,"folders":[{"title":"Users","bytes":5000000,"partial":false,"children":[]}]}"#
    checkEqual(try macStats("--read-measurement", "-", stdin: json).lines, ["Users\t5 MB"], "decodes the old shape")
}

test("reads a saved measurement as the panel shows it: a folder no longer granted is private again") {
    let folder = { (name: String, mb: Int) in #"{"title":"\#(name)","path":"/Users/alice/\#(name)","bytes":\#(mb)000000}"# }
    let json = #"{"measuredAt":0,"folders":[{"title":"Users","path":"/Users","bytes":9000000,"children":["#
        + #"{"title":"alice","path":"/Users/alice","bytes":9000000,"children":["#
        + [folder("Downloads", 4), folder("Desktop", 3), folder("Code", 2)].joined(separator: ",") + "]}]}]}"
    let lines = try macStats("--read-measurement", "-", "--granted", "/Users/alice/Desktop", stdin: json).lines
        .map { $0.replacingOccurrences(of: "\t", with: " | ") }
    checkEqual(lines, ["Users | ≥ 5 MB", "  alice | ≥ 5 MB", "    Desktop | 3 MB", "    Code | 2 MB", "    Downloads | private"], "the rows")
}

test("lists no Volumes row") {
    let lines = try tree([("Volumes/Disk/x.bin", 3), ("Stuff/y.bin", 2)])
    checkEqual(lines, ["Stuff | 2 MB"], "Volumes is neither counted nor listed")
}

// MARK: - The verdict

print("\n\(passed) passed, \(failures.count) failed, \(MacStatsTests.skipped) skipped")
exit(failures.isEmpty ? 0 : 1)
