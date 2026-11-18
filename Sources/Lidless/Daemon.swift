// `lidless run`: the service, as launchd runs it.

import AppKit
import IOKit.ps

final class Daemon {
    /// Docking is polled: the reconfiguration callback is not reliably
    /// delivered to a background launchd agent, which then fails silently.
    static let pollInterval: TimeInterval = 2
    /// Nothing here is urgent, so macOS may coalesce the poll's wakeup with
    /// other timers.
    static let pollTolerance: TimeInterval = 1
    /// One plug-in fires several reconfiguration callbacks (begin, mode set,
    /// end); act once they have settled.
    static let settleDelay: TimeInterval = 1
    /// macOS relights the panel on wake, a moment after the wake notification:
    /// on system wake, and on display wake alone (the displays slept on idle,
    /// the Mac did not), which has its own notification.
    static let wakeDelay: TimeInterval = 3
    /// macOS changes the panel's level when the power source changes (its
    /// dim-on-battery rule), raising a dark panel by one step on plugging in
    /// the charger. Act once it has.
    static let powerDelay: TimeInterval = 3
    /// macOS also relights the panel as a login session finishes loading,
    /// after the service has started and darkened it, with no notification
    /// to follow. So the service darkens again at these delays after it
    /// starts; how late macOS does it varies, hence more than one.
    static let startDelays: [TimeInterval] = [3, 10, 30]

    private var policy = Policy()
    private var pending: DispatchWorkItem?
    /// Survives coalescing, so a reconfiguration callback cannot cancel a
    /// wake's reassert.
    private var pendingReassert = false
    /// When the pending check runs. Coalescing never brings it forward: the
    /// reconfiguration callbacks that come with a wake would otherwise run
    /// the reassert after `settleDelay`, before macOS has relit the panel.
    private var pendingDeadline = DispatchTime.now()
    private var signals: [DispatchSourceSignal] = []
    /// "AC Power" or "Battery Power". The power-source notification fires on
    /// every battery reading too; only a change of source matters.
    private var powerSource = Daemon.currentPowerSource()

    nonisolated(unsafe) static var shared: Daemon?

    func run() -> Never {
        guard Display.services != nil else {
            fputs("lidless: could not load DisplayServices\n", stderr)
            exit(1)
        }
        Daemon.shared = self

        // Must be a non-capturing closure to convert to a C function pointer.
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            Daemon.shared?.schedule(after: Daemon.settleDelay)
        }, nil)

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                log("\(note.name.rawValue)")
                self?.schedule(after: Daemon.wakeDelay, reassert: true)
            }
        }

        // Must be a non-capturing closure to convert to a C function pointer.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            Daemon.shared?.powerChanged()
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let poll = Timer.scheduledTimer(withTimeInterval: Daemon.pollInterval, repeats: true) {
            [weak self] _ in self?.check()
        }
        poll.tolerance = Daemon.pollTolerance

        // Stopped (`lidless stop`, `brew services stop`, logout), the panel
        // would stay dark with nothing to relight it on undock.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }
            source.resume()
            signals.append(source)
        }

        let displays = Display.online()
            .map { "\($0)\(CGDisplayIsBuiltin($0) != 0 ? " (built-in)" : "")" }
            .joined(separator: ", ")
        log("lidless \(version) started; displays: \(displays)")
        check()
        for delay in Daemon.startDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.check(reassert: true)
            }
        }
        // A full app event loop, not just the run loop: without it the
        // NSWorkspace display wake notification never arrives.
        // `.prohibited`: no Dock icon, no menu bar.
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
        exit(0)
    }

    static func currentPowerSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        return IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
    }

    private func powerChanged() {
        let now = Daemon.currentPowerSource()
        guard now != powerSource else { return }
        log("power source: \(powerSource ?? "unknown") -> \(now ?? "unknown")")
        powerSource = now
        schedule(after: Daemon.powerDelay, reassert: true)
    }

    private func schedule(after delay: TimeInterval, reassert: Bool = false) {
        pending?.cancel()
        if reassert { pendingReassert = true }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let reassert = self.pendingReassert
            self.pendingReassert = false
            self.pending = nil
            self.check(reassert: reassert)
        }
        let deadline = DispatchTime.now() + delay
        if pending == nil || deadline > pendingDeadline { pendingDeadline = deadline }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: pendingDeadline, execute: work)
    }

    private func check(reassert: Bool = false) {
        guard let panel = Display.builtin() else { return }
        let before = policy.docked
        let docked = Display.docked()
        let action = policy.next(docked: docked, brightness: Display.brightness(panel), reassert: reassert)
        if before != docked {
            log("docked: \(before.map { "\($0)" } ?? "unknown") -> \(docked)")
        }
        Daemon.perform(action, on: panel)
    }

    static func perform(_ action: Policy.Action, on panel: CGDirectDisplayID) {
        switch action {
        case .nothing: break
        case .darken: Display.darken(panel)
        case .light: Display.light(panel)
        case .remember(let level): Saved.store(level)
        case .darkenAgain: Display.darken(panel, noting: false)
        }
    }

    private func stop() {
        log("stopping")
        // Only a panel this service darkened; one dimmed by hand stays as it is.
        if policy.docked == true, let panel = Display.builtin() { Display.light(panel) }
        exit(0)
    }
}
