// The launchd side: `lidless start`, `stop`, `restart`, `uninstall` and the
// service half of `status`.
//
// Installed by install.sh or build.sh, lidless is its own LaunchAgent,
// ~/Library/LaunchAgents/io.github.np25071984.lidless.plist, which `lidless
// start` writes (or rewrites, when the binary has moved) and loads. RunAtLoad
// starts it at every login; KeepAlive restarts it after a crash but not after
// a clean exit.
//
// Installed by Homebrew, the agent belongs to `brew services`, so start, stop
// and restart are handed to it and the two never disagree.

import Foundation

enum Service {
    static let ownLabel = "io.github.np25071984.lidless"
    /// What `brew services` calls it: `sh.brew.` since Homebrew 7,
    /// `homebrew.mxcl.` for services started by older versions.
    static let brewLabels = ["sh.brew.lidless", "homebrew.mxcl.lidless"]

    static var agents: String { NSHomeDirectory() + "/Library/LaunchAgents" }
    static func plist(_ label: String) -> String { "\(agents)/\(label).plist" }
    static var ownLog: String { NSHomeDirectory() + "/Library/Logs/lidless.log" }
    static var domain: String { "gui/\(getuid())" }

    /// launchd needs a moment after `bootout` before the same label can be
    /// bootstrapped again; until then bootstrap fails with an I/O error.
    static let bootstrapRetry: useconds_t = 200_000
    static let bootstrapAttempts = 15

    /// Homebrew's agent file, if `brew services` has written one.
    static var brewLabel: String? {
        brewLabels.first { FileManager.default.fileExists(atPath: plist($0)) }
    }

    /// A binary in Homebrew's Cellar. `brew services` then owns the service,
    /// even before it has been started once (`brew services stop` removes
    /// its agent file).
    static func isHomebrewPath(_ path: String) -> Bool {
        path.contains("/Cellar/lidless/")
    }

    static var isHomebrew: Bool { brewLabel != nil || isHomebrewPath(CommandLine.executable) }

    /// Homebrew's agent when Homebrew owns the service, else lidless's own.
    static var label: String {
        brewLabel ?? (isHomebrewPath(CommandLine.executable) ? brewLabels[0] : ownLabel)
    }

    /// Where the running service's log goes: what its agent file says.
    static var logPath: String {
        let url = URL(fileURLWithPath: plist(label))
        guard let data = try? Data(contentsOf: url),
              let agent = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = agent["StandardErrorPath"] as? String
        else { return ownLog }
        return path
    }

    struct State {
        var loaded = false
        var pid: Int?
        var lastExit: String?
    }

    static func state(_ label: String = Service.label) -> State {
        let (code, out) = run("/bin/launchctl", ["print", "\(domain)/\(label)"])
        return code == 0 ? parseState(out) : State()
    }

    /// The state in `launchctl print gui/<uid>/<label>` output.
    static func parseState(_ output: String) -> State {
        var state = State(loaded: true)
        // Only the service's own top-level lines; nested blocks are indented further.
        for line in output.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            if parts[0] == "pid" { state.pid = Int(parts[1]) }
            if parts[0] == "last exit code" { state.lastExit = parts[1] }
        }
        return state
    }

    // MARK: Commands

    static func start() -> Int32 {
        if isHomebrew { return brew("start") }
        warnAboutHomebrew()
        let changed = writePlist()
        let state = state(ownLabel)
        if state.loaded && changed {
            print("launchd file changed; reloading")
            bootout()
            return bootstrap()
        }
        if !state.loaded { return bootstrap() }
        if let pid = state.pid {
            print("lidless is already running (pid \(pid))")
            return 0
        }
        return launchctl(["kickstart", "\(domain)/\(ownLabel)"])
    }

    /// The service relights the panel as it stops (`Daemon`).
    static func stop() -> Int32 {
        if isHomebrew { return brew("stop") }
        guard state(ownLabel).loaded else {
            print("lidless is not running")
            return 0
        }
        // Unloaded until the next login or `lidless start`; the file stays.
        bootout()
        print("stopped")
        return 0
    }

    static func restart() -> Int32 {
        if isHomebrew { return brew("restart") }
        let changed = writePlist()
        let state = state(ownLabel)
        guard state.loaded else { return bootstrap() }
        if changed {
            bootout()
            return bootstrap()
        }
        let code = launchctl(["kickstart", "-k", "\(domain)/\(ownLabel)"])
        if code == 0 { print("restarted") }
        return code
    }

    /// Stops the service, relights the panel, and removes the launchd file,
    /// the log, the saved brightness and this binary.
    static func uninstall() -> Int32 {
        if isHomebrew {
            fputs("lidless: installed by Homebrew; run `brew services stop lidless && brew uninstall lidless`, "
                + "then `rm -f ~/.local/state/lidless-brightness`\n", stderr)
            return 1
        }
        if state(ownLabel).loaded { bootout() }
        Display.lightIfDark()
        var removed: [String] = []
        for path in [plist(ownLabel), ownLog, Saved.path, CommandLine.executable]
        where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
                removed.append(path)
            } catch {
                fputs("lidless: cannot remove \(path): \(error.localizedDescription)\n", stderr)
            }
        }
        for path in removed { print("removed \(path)") }
        return 0
    }

    /// Waits for a just-started service to get a pid, and says which.
    static func awaitRunning() -> Int32 {
        for _ in 0..<30 {
            if let pid = state().pid {
                print("running, pid \(pid)")
                return 0
            }
            usleep(100_000)
        }
        fputs("lidless: started, but it is not running; see `lidless logs`\n", stderr)
        return 1
    }

    // MARK: launchd

    /// The agent's file for this binary. Returns whether it had to be written.
    @discardableResult
    static func writePlist() -> Bool {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: agent(binary: CommandLine.executable, log: ownLog), format: .xml, options: 0)
        else { return false }
        let path = plist(ownLabel)
        if FileManager.default.contents(atPath: path) == data { return false }
        try? FileManager.default.createDirectory(atPath: agents, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: data)
        print("wrote \(path)")
        return true
    }

    /// The agent's launchd file, as a property list.
    static func agent(binary: String, log: String) -> [String: Any] {
        [
            "Label": ownLabel,
            "ProgramArguments": [binary, "run"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            "StandardOutPath": log,
            "StandardErrorPath": log,
        ]
    }

    private static func bootstrap() -> Int32 {
        var code: Int32 = 0
        var out = ""
        for _ in 0..<bootstrapAttempts {
            (code, out) = run("/bin/launchctl", ["bootstrap", domain, plist(ownLabel)])
            if code == 0 {
                print("started")
                return 0
            }
            usleep(bootstrapRetry)
        }
        fputs(out, stderr)
        return code
    }

    /// Returns once launchd has let go of the label.
    private static func bootout() {
        _ = run("/bin/launchctl", ["bootout", "\(domain)/\(ownLabel)"])
        for _ in 0..<25 where state(ownLabel).loaded { usleep(100_000) }
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let (code, out) = run("/bin/launchctl", args)
        if code != 0 { fputs(out, stderr) }
        return code
    }

    // MARK: Homebrew

    private static func brew(_ command: String) -> Int32 {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            fputs("lidless: installed by Homebrew, but brew was not found\n", stderr)
            return 1
        }
        let (code, out) = run(brew, ["services", command, "lidless"])
        print(out, terminator: "")
        return code
    }

    /// Two copies would fight over the backlight.
    private static func warnAboutHomebrew() {
        for label in brewLabels where state(label).loaded {
            fputs("warning: Homebrew's lidless service (\(label)) is also loaded; "
                + "run `brew services stop lidless`\n", stderr)
        }
    }

    // MARK: Processes

    /// Runs a program to completion; stdout and stderr together.
    static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, "\(path): \(error.localizedDescription)\n") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
