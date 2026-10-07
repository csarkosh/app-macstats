// IOReport: the counters macOS keeps for its hardware (energy, frames, how long each
// CPU cluster spent at each clock speed). It is a private macOS library, so it is
// looked up at run time rather than linked; on a Mac without it, the rows that need
// it read "–". Read the way the Stats app reads it (MIT; see LICENSE-stats.txt at the repository root).

import Foundation

private let ioReport = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
private func ioReportFunction<T>(_ name: String, as type: T.Type) -> T? {
    guard let ioReport, let pointer = dlsym(ioReport, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
}
private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFDictionary, CFTypeRef?) -> Void
private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                                                       UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias ChannelInteger = @convention(c) (CFDictionary) -> Int32
private typealias IndexedInteger = @convention(c) (CFDictionary, Int32) -> Int64
private typealias IndexedString = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

private let copyChannelsInGroup = ioReportFunction("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self)
private let mergeChannels = ioReportFunction("IOReportMergeChannels", as: MergeChannels.self)
private let createSubscription = ioReportFunction("IOReportCreateSubscription", as: CreateSubscription.self)
private let createSamples = ioReportFunction("IOReportCreateSamples", as: CreateSamples.self)
private let channelGroup = ioReportFunction("IOReportChannelGetGroup", as: ChannelString.self)
private let channelSubGroup = ioReportFunction("IOReportChannelGetSubGroup", as: ChannelString.self)
private let channelName = ioReportFunction("IOReportChannelGetChannelName", as: ChannelString.self)
private let channelUnit = ioReportFunction("IOReportChannelGetUnitLabel", as: ChannelString.self)
private let channelFormat = ioReportFunction("IOReportChannelGetFormat", as: ChannelInteger.self)
private let simpleIntegerValue = ioReportFunction("IOReportSimpleGetIntegerValue", as: IndexedInteger.self)
private let stateCount = ioReportFunction("IOReportStateGetCount", as: ChannelInteger.self)
private let stateName = ioReportFunction("IOReportStateGetNameForIndex", as: IndexedString.self)
private let stateResidency = ioReportFunction("IOReportStateGetResidency", as: IndexedInteger.self)

/// IOReport's format for a channel that counts time spent in each of its states.
private let stateFormat: Int32 = 2

/// One channel's running totals: a value for a simple channel, or for a state channel
/// the time spent in each state so far.
struct ReportChannel {
    let group: String
    let subGroup: String
    let name: String
    let unit: String
    let value: Int64
    let states: [(name: String, residency: Int64)]
}

/// A subscription to some IOReport channels, read as running totals.
final class ReportSubscription {
    private let channels: CFMutableDictionary
    private let subscription: OpaquePointer

    /// The channels of `groups`, with `subGroup` if given, merged into one subscription.
    convenience init?(groups: [String], subGroup: String?) {
        self.init(groups.map { ($0, subGroup) })
    }

    /// The channels of each group and subgroup, merged into one subscription.
    init?(_ groups: [(group: String, subGroup: String?)]) {
        guard let copyChannelsInGroup, let mergeChannels, let createSubscription else { return nil }
        var merged: CFMutableDictionary?
        for (group, subGroup) in groups {
            guard let channel = copyChannelsInGroup(group as CFString, subGroup as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let merged { mergeChannels(merged, channel, nil) } else { merged = channel }
        }
        guard let merged, (merged as NSDictionary)["IOReportChannels"] != nil else { return nil }
        var unused: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, merged, &unused, 0, nil) else { return nil }
        unused?.release()
        channels = merged
        self.subscription = subscription
    }

    /// Each channel now.
    func sample() -> [ReportChannel] {
        guard let createSamples, let channelGroup, let channelSubGroup, let channelName, let channelUnit, let channelFormat,
              let simpleIntegerValue, let stateCount, let stateName, let stateResidency,
              let sample = createSamples(subscription, channels, nil)?.takeRetainedValue(),
              let list = (sample as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return [] }
        return list.map { item in
            let isState = channelFormat(item) == stateFormat
            let states = isState ? (0..<stateCount(item)).map { index in
                (stateName(item, index)?.takeUnretainedValue() as String? ?? "", stateResidency(item, index))
            } : []
            return ReportChannel(group: channelGroup(item)?.takeUnretainedValue() as String? ?? "",
                                 subGroup: channelSubGroup(item)?.takeUnretainedValue() as String? ?? "",
                                 name: channelName(item)?.takeUnretainedValue() as String? ?? "",
                                 unit: (channelUnit(item)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces),
                                 value: isState ? 0 : simpleIntegerValue(item, 0), states: states)
        }
    }
}
