import Foundation
import IOKit

/// System power capabilities, read from IOPMrootDomain.
///
/// Dark wake is macOS waking itself for maintenance — TCPKeepAlive, Power Nap,
/// SleepService — with no user session behind it. The process keeps ticking and
/// the input clock is stale, so a tracker that only knows "awake" and "no input"
/// files every one of them as Away: 88 wakes and 3.32h of phantom Away in a
/// single night on this machine.
///
/// The capability bitfield names the state directly instead of inferring it from
/// a proxy like display power. Reading it out of the registry means it can be
/// polled on the sample tick, rather than needing a push-based IOPMConnection
/// and the state-tracking that implies.
enum PowerState {
    /// Bits from IOKit's IOPM.h (`kIOPMSystemCapability*`, IOPM.h:941-944).
    /// Redeclared because that enum lives in a header Swift doesn't surface.
    private static let capabilityCPU: UInt32 = 0x01
    private static let capabilityGraphics: UInt32 = 0x02

    /// Raw capability mask, or nil if the registry can't be read.
    static func systemCapabilities() -> UInt32? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(
            entry, "System Capabilities" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber else { return nil }
        return value.uint32Value
    }

    /// CPU up, graphics down — awake for maintenance rather than for a person.
    /// An unreadable mask returns false: logging Away during a maintenance wake
    /// is a smaller error than inventing Sleep while someone is working.
    static var isDarkWake: Bool {
        guard let caps = systemCapabilities() else { return false }
        return caps & capabilityCPU != 0 && caps & capabilityGraphics == 0
    }
}
