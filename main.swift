// lidless - turn the built-in MacBook display off whenever an external display
// is connected, and restore its previous brightness when it is unplugged.
//
// Build: swiftc -O -o ~/.local/bin/lidless main.swift
// Run:   lidless            (daemon: watches for display changes)
//        lidless --once     (apply the correct state right now, then exit)
//        lidless --off      (force the built-in display off)
//        lidless --on       (force the built-in display back on)

import Foundation
import AppKit

enum Lidless {

    static let version = "0.1.0"

    static let usage = """
    lidless \(version) - keep the built-in display dark while docked

    usage: lidless [option]

      (no option)  run as a daemon, watching for displays being plugged in
      --once       apply the correct state right now, then exit
      --off        force the built-in display off
      --on         force the built-in display back on
      --status     list online displays, their brightness, and dock state
      --version    print the version
      --help       print this message
    """

    // MARK: - DisplayServices
    // The only way to drive built-in brightness on Apple Silicon; it lives in a
    // private framework, so it is resolved by hand rather than linked against.

    typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    static let displayServices: (set: SetBrightnessFn, get: GetBrightnessFn)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let setSym = dlsym(handle, "DisplayServicesSetBrightness"),
              let getSym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return (unsafeBitCast(setSym, to: SetBrightnessFn.self),
                unsafeBitCast(getSym, to: GetBrightnessFn.self))
    }()

    // MARK: - Display enumeration

    // Online rather than active: with the lid shut, or while mirroring, the
    // built-in panel drops out of the active list but is still online and still
    // the thing whose backlight needs driving.
    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func builtinDisplay() -> CGDirectDisplayID? {
        onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func hasExternalDisplay() -> Bool {
        onlineDisplays().contains { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsAsleep($0) == 0 }
    }

    // MARK: - Remembering the brightness we dimmed away from

    static let stateFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/lidless-brightness")

    /// Mirror of what is on disk, so the steady-state poll does not rewrite the
    /// same value thousands of times a day. nil means "not yet read".
    nonisolated(unsafe) static var cachedSaved: Float?

    static func saveBrightness(_ value: Float) {
        if cachedSaved == nil,
           let text = try? String(contentsOf: stateFile, encoding: .utf8) {
            cachedSaved = Float(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let cached = cachedSaved, abs(cached - value) < 0.001 { return }

        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? String(value).write(to: stateFile, atomically: true, encoding: .utf8)
        cachedSaved = value
    }

    static func savedBrightness() -> Float {
        guard let text = try? String(contentsOf: stateFile, encoding: .utf8),
              let value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value > 0.05 else { return 0.6 }
        return min(value, 1.0)
    }

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }

    // MARK: - Actions

    static func turnOff(_ display: CGDirectDisplayID) {
        guard let ds = displayServices else { return }
        var current: Float = 0
        // Only note a level worth restoring; if it is already dark, keep the old note.
        if ds.get(display, &current) == 0 && current > 0.05 {
            saveBrightness(current)
        }
        let rc = ds.set(display, 0.0)
        log("built-in \(display) off (was \(current), rc \(rc))")
    }

    static func turnOn(_ display: CGDirectDisplayID) {
        guard let ds = displayServices else { return }
        let target = savedBrightness()
        let rc = ds.set(display, target)
        log("built-in \(display) on (target \(target), rc \(rc))")
    }

    /// Last observed docking state; nil until the first observation.
    nonisolated(unsafe) static var lastExternal: Bool?

    /// Acts only on a *change* in docking state, so a manual brightness tweak
    /// while docked is never fought or overwritten.
    static func apply() {
        guard let builtin = builtinDisplay() else { return }
        let external = hasExternalDisplay()

        if lastExternal != external {
            log("transition: external \(lastExternal.map(String.init(describing:)) ?? "unknown") -> \(external)")
            lastExternal = external
            if external { turnOff(builtin) } else { turnOn(builtin) }
            return
        }

        // Steady state, undocked: quietly note the brightness the user prefers
        // so that undocking later restores it. Read-only; it never writes.
        if !external, let ds = displayServices {
            var current: Float = 0
            if ds.get(builtin, &current) == 0 && current > 0.05 { saveBrightness(current) }
        }
    }

    // MARK: - Daemon
    // One plug-in event fires several reconfiguration callbacks (begin, mode set,
    // end), so they get coalesced and acted on once things have settled.

    nonisolated(unsafe) static var pendingApply: DispatchWorkItem?

    static func scheduleApply(after delay: TimeInterval = 1.0) {
        pendingApply?.cancel()
        let work = DispatchWorkItem { apply() }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func runDaemon() {
        // Must be a non-capturing literal closure to convert to a C function pointer.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            Lidless.scheduleApply()
        }, nil)

        // macOS restores the panel's own brightness on wake, so re-assert afterwards.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in scheduleApply(after: 3.0) }

        // The callback above is not reliably delivered to a background launchd
        // agent, so a cheap poll is what actually drives this. Both funnel into
        // apply(), which is a no-op unless the docking state has changed.
        let poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in apply() }
        // Nothing here is time-critical, so let macOS coalesce this wakeup with
        // other timers rather than waking the CPU on its own schedule.
        poll.tolerance = 1.0

        log("daemon started; displays: \(onlineDisplays().map { "\($0)\(CGDisplayIsBuiltin($0) != 0 ? "(builtin)" : "")" }.joined(separator: ", "))")
        apply()
        RunLoop.main.run()
    }

    static func main() {
        guard displayServices != nil else {
            FileHandle.standardError.write(Data("lidless: could not load DisplayServices\n".utf8))
            exit(1)
        }
        let args = Set(CommandLine.arguments.dropFirst())
        switch true {
        case args.contains("--once"):
            if let builtin = builtinDisplay() {
                hasExternalDisplay() ? turnOff(builtin) : turnOn(builtin)
            }
        case args.contains("--off"):  builtinDisplay().map(turnOff)
        case args.contains("--on"):   builtinDisplay().map(turnOn)
        case args.contains("--version"): print(version)
        case args.contains("--help"), args.contains("-h"): print(usage)
        case args.contains("--status"):
            for id in onlineDisplays() {
                var b: Float = -1
                let rc = displayServices?.get(id, &b) ?? -1
                let kind = CGDisplayIsBuiltin(id) != 0 ? "built-in" : "external"
                print("display \(id)  \(kind)  active=\(CGDisplayIsActive(id))  brightness=\(b) (rc \(rc))")
            }
            print("external present: \(hasExternalDisplay())")
        default: runDaemon()
        }
    }
}

Lidless.main()
