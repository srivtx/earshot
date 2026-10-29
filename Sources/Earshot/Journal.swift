import AppKit
import EarshotCore

/// The last few hundred messages to and from the buds, so an owner of untested buds can send a
/// report that shows what their model actually says. Holds no Bluetooth addresses.
@MainActor
final class Journal {
    enum Direction: String {
        case sent = "→"
        case received = "←"
        case note = "·"
    }

    private struct Entry {
        var time: Date
        var direction: Direction
        var text: String
    }

    private var entries: [Entry] = []
    private var budsName = "—"
    private var brand = "—"
    private var tested = false
    private static let limit = 600

    func begin(name: String, profile: Profile) {
        budsName = name
        brand = profile.brand.title
        tested = profile.tested
        note("linked")
    }

    func record(_ direction: Direction, _ bytes: [UInt8]) {
        append(Entry(time: .now, direction: direction, text: bytes.hex))
    }

    func note(_ text: String) {
        append(Entry(time: .now, direction: .note, text: text))
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    var isEmpty: Bool { !entries.contains { $0.direction != .note } }

    /// A plain-text report: what the app knows about the buds, then the traffic.
    func report(firmware: String?, capabilities: Capabilities?) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let time = Date.FormatStyle(date: .omitted, time: .standard)
        var lines = [
            "Earshot report",
            "Buds: \(budsName) (\(brand)\(tested ? ", tested" : ", experimental"))",
            "Firmware: \(firmware ?? "unknown")",
            "Earshot \(version), macOS \(os)",
        ]
        if let capabilities {
            lines.append("Shown: noise \(capabilities.noiseModes.count), EQ \(capabilities.eqPresets.count), "
                         + "gestures \(capabilities.gestures.count), find \(capabilities.find)")
        }
        lines.append("")
        lines.append("What worked and what didn't (please fill in):")
        lines.append("")
        lines.append("")
        lines.append("Traffic (→ sent, ← received):")
        for entry in entries {
            lines.append("\(entry.time.formatted(time)) \(entry.direction.rawValue) \(entry.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
