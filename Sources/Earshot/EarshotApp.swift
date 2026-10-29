import AppKit
import SwiftUI

@main
struct EarshotApp: App {
    @State private var store: BudsStore
    private static var signalSource: DispatchSourceSignal?

    init() {
        // Only one copy may own the control channel; a second launch hands over and quits.
        let me = NSRunningApplication.current
        if let bundleID = me.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0 != me }) {
            exit(0)
        }
        Typeface.registerBundled()
        let store = BudsStore()
        _store = State(initialValue: store)

        // Close the channel on quit, and treat SIGTERM (kill, logout, updates) as a normal quit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { store.shutdown() }
        }
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        Self.signalSource = term

    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Earbuds glyph plus the lowest bud level, so you know when to charge without opening anything.
private struct MenuBarLabel: View {
    let store: BudsStore

    var body: some View {
        // Fixed width: if the item grew when the level appeared or changed, macOS would shift the
        // open popover with it, which reads as a flicker.
        HStack(spacing: 3) {
            Image(systemName: "earbuds")
                .opacity(store.isLinked ? 1 : 0.55)
            Text(store.isLinked ? store.menuBarLevel.map { "\($0)%" } ?? "–" : "–")
                .monospacedDigit()
                .frame(width: 32, alignment: .leading)
        }
        .accessibilityLabel(store.menuBarLevel.map { "Earshot, buds at \($0) percent" } ?? "Earshot")
        .task { await DevShots.runIfRequested(store: store) }
    }
}
