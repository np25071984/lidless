// The displays, and the built-in panel's backlight.

import CoreGraphics
import Foundation

enum Display {
    // MARK: DisplayServices
    // The only way to drive built-in brightness on Apple Silicon. It lives in a
    // private framework, so it is resolved at runtime rather than linked.

    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    static let services: (set: SetBrightness, get: GetBrightness)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let set = dlsym(handle, "DisplayServicesSetBrightness"),
              let get = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return (unsafeBitCast(set, to: SetBrightness.self), unsafeBitCast(get, to: GetBrightness.self))
    }()

    // MARK: Enumeration

    // Online rather than active: with the lid shut, or while mirroring, the
    // built-in panel drops out of the active list but is still online and still
    // the one whose backlight needs driving.
    static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func builtin() -> CGDirectDisplayID? {
        online().first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func docked() -> Bool {
        online().contains { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsAsleep($0) == 0 }
    }

    static func brightness(_ display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        guard let services, services.get(display, &value) == 0 else { return nil }
        return value
    }

    // MARK: The panel

    static func darken(_ display: CGDirectDisplayID) {
        guard let services else { return }
        let current = brightness(display)
        // Only a level worth restoring is noted; already dark, the old note stays.
        if Policy.isLit(current), let current { Saved.store(current) }
        let rc = services.set(display, 0)
        log("built-in \(display) off (was \(current.map { "\($0)" } ?? "?"), rc \(rc))")
    }

    static func light(_ display: CGDirectDisplayID) {
        guard let services else { return }
        let target = Saved.level()
        let rc = services.set(display, target)
        log("built-in \(display) on (target \(target), rc \(rc))")
    }

    /// Lights the panel if it is dark: after the service stops, nothing would.
    static func lightIfDark() {
        guard let panel = builtin(), !Policy.isLit(brightness(panel)) else { return }
        light(panel)
    }
}

/// The brightness to restore on undock, kept across runs.
enum Saved {
    static let path = NSHomeDirectory() + "/.local/state/lidless-brightness"

    /// What is on disk, so the steady-state poll does not rewrite the same
    /// value every 2 seconds. nil until first read.
    nonisolated(unsafe) private static var cached: Float?

    static func level() -> Float {
        SavedLevel.parse(try? String(contentsOfFile: path, encoding: .utf8))
    }

    static func store(_ value: Float) {
        if cached == nil, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            cached = Float(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let cached, abs(cached - value) < 0.001 { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(value).write(to: url, atomically: true, encoding: .utf8)
        cached = value
    }
}
