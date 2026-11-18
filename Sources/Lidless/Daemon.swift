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
    /// macOS relights the panel a moment after the notification for: system
    /// wake; display wake alone (the displays slept on idle, the Mac did not);
    /// and a power source change, where its dim-on-battery rule raises a dark
    /// panel by one step on plugging in the charger. Act once it has.
    static let relightDelay: TimeInterval = 3
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
    /// From macOS's display sleep notification until a while after the wake
    /// one: an external display that reports asleep meanwhile is not unplugged.
    private var screensAsleep = false
    /// Counts display sleeps, so that clearing `screensAsleep` after a wake
    /// is skipped when the displays have slept again meanwhile.
    private var sleeps = 0
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
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.screensAsleep = true
                self?.sleeps += 1
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                log("\(note.name.rawValue)")
                self.schedule(after: Daemon.relightDelay, reassert: true)
                // An external display may still report asleep for a moment
                // after the wake notification; until then it is not unplugged.
                let sleeps = self.sleeps
                DispatchQueue.main.asyncAfter(deadline: .now() + Daemon.relightDelay) { [weak self] in
                    if self?.sleeps == sleeps { self?.screensAsleep = false }
                }
            }
        }
        // Sent for restart and shut down too, which log out first.
        let distributed = DistributedNotificationCenter.default()
        for (name, ending) in [("com.apple.logoutInitiated", true), ("com.apple.logoutCancelled", false)] {
            distributed.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                log(name)
                self?.policy.loggingOut = ending
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

        // Stopping relights the panel, unless logging out: see `Policy.relightsOnStop`.
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
        schedule(after: Daemon.relightDelay, reassert: true)
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
        let docked = Display.docked(screensAsleep: screensAsleep)
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
        if policy.relightsOnStop, let panel = Display.builtin() { Display.light(panel) }
        exit(0)
    }
}
