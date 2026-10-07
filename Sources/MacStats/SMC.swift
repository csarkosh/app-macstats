// Reads sensor values from the System Management Controller. Adapted from the
// Stats app's SMC/smc.swift (version 3.0.19, MIT licence, Copyright (c) 2019
// Serhiy Mytrovtsiy; see LICENSE-stats.txt at the repository root), keeping only reading:
// nothing here writes to the SMC or controls fans. Needs no permission.

import Foundation
import IOKit

private struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    struct Version {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct LimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = LimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private enum Selector: UInt8 {
    case kernelIndex = 2
    case readBytes = 5
    case readIndex = 8
    case readKeyInfo = 9
}

private func fourCharCode(_ string: String) -> UInt32 {
    string.utf8.reduce(0) { $0 << 8 | UInt32($1) }
}

private func string(fromFourCharCode code: UInt32) -> String {
    String([24, 16, 8, 0].compactMap { UnicodeScalar(code >> $0 & 0xff).map(Character.init) })
}

final class SMC {
    private var connection: io_connect_t = 0

    /// Nil when the SMC cannot be opened, as in a virtual machine.
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(connection)
    }

    /// Every key the SMC has, such as "Tp01".
    func allKeys() -> [String] {
        guard let count = value("#KEY") else { return [] }
        return (0..<Int(count)).compactMap { index in
            var input = SMCKeyData(), output = SMCKeyData()
            input.data8 = Selector.readIndex.rawValue
            input.data32 = UInt32(index)
            guard call(&input, &output) == kIOReturnSuccess else { return nil }
            return string(fromFourCharCode: output.key)
        }
    }

    /// A key's value as a number, or nil when it is missing, unreadable or all zero
    /// bytes (how the SMC reports a sensor that is not there).
    func value(_ key: String) -> Double? {
        var input = SMCKeyData(), output = SMCKeyData()
        input.key = fourCharCode(key)
        input.data8 = Selector.readKeyInfo.rawValue
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        let size = Int(output.keyInfo.dataSize)
        let type = string(fromFourCharCode: output.keyInfo.dataType)
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = Selector.readBytes.rawValue
        guard call(&input, &output) == kIOReturnSuccess, size > 0 else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(min(size, 32))) }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return decode(bytes, type: type)
    }

    private func decode(_ bytes: [UInt8], type: String) -> Double? {
        let word = bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : 0
        let signed = bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) : 0
        switch type {
        case "ui8 ": return Double(bytes[0])
        case "ui16": return word
        case "ui32" where bytes.count >= 4:
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "sp1e": return word / 16384
        case "sp3c": return word / 4096
        case "sp4b": return word / 2048
        case "sp5a": return word / 1024
        case "sp69": return word / 512
        case "sp78": return signed / 256
        case "sp87": return signed / 128
        case "sp96": return signed / 64
        case "spa5": return word / 32
        case "spb4": return signed / 16
        case "spf0": return signed
        case "flt " where bytes.count >= 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "fpe2": return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        default: return nil
        }
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        let inputSize = MemoryLayout<SMCKeyData>.stride
        var outputSize = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(connection, UInt32(Selector.kernelIndex.rawValue),
                                         &input, inputSize, &output, &outputSize)
    }
}
