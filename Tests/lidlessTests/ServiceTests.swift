// The launchd side: the agent's file, reading launchctl, and Homebrew.

import Testing
@testable import lidless

@Suite("Service")
struct ServiceTests {
    @Test("the agent runs this binary's `run` at login, restarted after a crash but not a clean exit")
    func agent() {
        let agent = Service.agent(binary: "/Users/me/.local/bin/lidless", log: "/Users/me/Library/Logs/lidless.log")
        #expect(agent["Label"] as? String == "io.github.np25071984.lidless")
        #expect(agent["ProgramArguments"] as? [String] == ["/Users/me/.local/bin/lidless", "run"])
        #expect(agent["RunAtLoad"] as? Bool == true)
        #expect(agent["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(agent["LimitLoadToSessionType"] as? String == "Aqua")
        #expect(agent["StandardErrorPath"] as? String == "/Users/me/Library/Logs/lidless.log")
    }

    @Test("launchctl print: pid and last exit code from the service's own lines, not nested blocks")
    func parseRunning() {
        let output = """
            gui/501/io.github.np25071984.lidless = {
            \tactive count = 1
            \tstate = running
            \tpid = 4242
            \tlast exit code = (never exited)
            \tendpoints = {
            \t\tpid = 1
            \t}
            }
            """
        let state = Service.parseState(output)
        #expect(state.loaded)
        #expect(state.pid == 4242)
        #expect(state.lastExit == "(never exited)")
    }

    @Test("loaded but not running: no pid")
    func parseStopped() {
        let state = Service.parseState("x = {\n\tstate = not running\n\tlast exit code = 1\n}")
        #expect(state.loaded)
        #expect(state.pid == nil)
        #expect(state.lastExit == "1")
    }
}

@Suite("Homebrew")
struct HomebrewTests {
    @Test("a binary in the Cellar belongs to Homebrew", arguments: [
        "/opt/homebrew/Cellar/lidless/0.2.0/bin/lidless",
        "/usr/local/Cellar/lidless/0.2.0/bin/lidless",
    ])
    func homebrewPaths(path: String) {
        #expect(Service.isHomebrewPath(path))
    }

    @Test("anywhere else, lidless runs its own agent", arguments: [
        "/Users/me/.local/bin/lidless",
        "/opt/homebrew/Cellar/other/1.0/bin/lidless",
    ])
    func otherPaths(path: String) {
        #expect(!Service.isHomebrewPath(path))
    }

    @Test("both the current and the older brew services label are recognised")
    func labels() {
        #expect(Service.brewLabels == ["sh.brew.lidless", "homebrew.mxcl.lidless"])
    }
}
