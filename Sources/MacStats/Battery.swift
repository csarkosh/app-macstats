// The battery's charge: what a full charge holds and how much is left, from the
// AppleSmartBattery entry in the I/O Registry. Reading it needs no permission.

import Foundation
import IOKit

struct BatteryCharge {
    /// What a full charge holds now, in watt-hours.
    let fullWh: Double
    /// What it held when new.
    let designWh: Double
    let leftWh: Double
    /// The percentage the battery icon shows.
    let percent: Int
    let cycles: Int
}

/// Nil on a Mac without a battery.
func batteryCharge() -> BatteryCharge? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let battery = properties?.takeRetainedValue() as? [String: Any] else { return nil }
    let number = { (key: String) in (battery[key] as? NSNumber)?.doubleValue ?? 0 }
    // Capacities are in mAh; at the cells' rated voltage they give watt-hours. The live
    // voltage would make the figures swing with charging (11.4 V on battery, 11.9 V on
    // the charger), so use the rated one: 3.87 V a cell gives Apple's own ratings
    // (4,629 mAh is the M4 MacBook Air's 53.8 Wh) and reads about 2% high on older cells.
    let cells = ((battery["BatteryData"] as? [String: Any])?["CellVoltage"] as? [Any])?.count ?? 3
    let volts = 3.87 * Double(max(cells, 1))
    let fullMah = number("AppleRawMaxCapacity"), designMah = number("DesignCapacity")
    guard fullMah > 0 else { return nil }
    // Apple silicon reports the charge as a percentage (out of 100), older Macs in mAh.
    let current = number("CurrentCapacity"), maximum = number("MaxCapacity")
    guard maximum > 0 else { return nil }
    let percent = Int((current / maximum * 100).rounded())
    let fullWh = fullMah * volts / 1000
    return BatteryCharge(fullWh: fullWh, designWh: designMah * volts / 1000,
                         leftWh: fullWh * Double(percent) / 100, percent: percent, cycles: Int(number("CycleCount")))
}
