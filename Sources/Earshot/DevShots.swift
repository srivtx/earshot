import AppKit
import os
import SwiftUI

/// Developer tool for README screenshots: with EARSHOT_SHOTS=<folder> set, renders each tab in
/// each theme from the live app state once linked, writes PNGs, and logs what it did.
@MainActor
enum DevShots {
    private static let log = Logger(subsystem: "xyz.srivtx.earshot", category: "shots")

    static func runIfRequested(store: BudsStore) async {
        guard let folder = ProcessInfo.processInfo.environment["EARSHOT_SHOTS"] else { return }
        // Wait until the buds are linked and have reported their state, so shots show real data.
        for _ in 0..<60 where !(store.isLinked && !store.battery.isEmpty && store.eq != nil && !store.touch.isEmpty) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(1))
        let defaults = UserDefaults.standard
        let savedTab = defaults.string(forKey: "tab")
        let savedTheme = defaults.string(forKey: "theme")

        for theme in ["dark", "light"] {
            for tab in ["buds", "sound", "taps"] {
                defaults.set(theme, forKey: "theme")
                defaults.set(tab, forKey: "tab")
                let renderer = ImageRenderer(content: PopoverView().environment(store).environment(\.isSnapshot, true))
                renderer.scale = 2
                let path = "\(folder)/\(tab)-\(theme).png"
                guard let cg = renderer.cgImage else {
                    log.error("shot \(path, privacy: .public): renderer returned nil")
                    continue
                }
                let rep = NSBitmapImageRep(cgImage: cg)
                do {
                    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    log.info("shot \(path, privacy: .public): ok")
                } catch {
                    log.error("shot \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        defaults.set(savedTab, forKey: "tab")
        defaults.set(savedTheme, forKey: "theme")
    }
}
