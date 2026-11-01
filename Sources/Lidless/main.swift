// lidless: keep the built-in MacBook display dark while an external display is
// connected, and restore its brightness when it is unplugged. Run as a launchd
// service and controlled from the command line.

import CoreGraphics
import Foundation

let usage = """
    lidless \(version) - keep the built-in display dark while docked

    usage: lidless <command>

      start       start the service (writes its launchd file if needed)
      stop        stop it and relight the panel; it starts again at the next login
      restart     restart it
      status      the service, the displays and their brightness
      logs        follow the service's log
      once        apply the right state now, without the service
      off         switch the built-in display off
      on          switch it back on, at the remembered brightness
      run         the service itself, in the foreground (what launchd runs)
      uninstall   stop the service and remove lidless
      version     print the version
    """

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    fputs("lidless: \(message)\n", stderr)
    exit(code)
}

/// The built-in panel, for the commands that drive it.
func panel() -> CGDirectDisplayID {
    guard Display.services != nil else { fail("could not load DisplayServices") }
    guard let panel = Display.builtin() else { fail("no built-in display is online") }
    return panel
}

switch args.first {
case "run":
    Daemon().run()

case "start":
    let code = Service.start()
    exit(code == 0 ? Service.awaitRunning() : code)

case "stop":
    exit(Service.stop())

case "restart":
    let code = Service.restart()
    exit(code == 0 ? Service.awaitRunning() : code)

case "status":
    let label = Service.label
    let state = Service.state(label)
    let how = Service.isHomebrew ? "brew services" : "launchd"
    print("service:  \(label) (\(how), \(Service.plist(label)))")
    switch (state.loaded, state.pid) {
    case (true, let pid?): print("state:    running, pid \(pid)")
    case (true, nil): print("state:    loaded, not running (last exit \(state.lastExit ?? "?"))")
    default: print("state:    not loaded")
    }
    print("log:      \(Service.logPath)")
    print("docked:   \(Display.docked() ? "yes" : "no")")
    print("restores: \(Saved.level())")
    for id in Display.online() {
        let kind = CGDisplayIsBuiltin(id) != 0 ? "built-in" : "external"
        let level = Display.brightness(id).map { "brightness \($0)" } ?? "no brightness"
        let active = CGDisplayIsActive(id) != 0 ? "active" : "inactive"
        print("display:  \(id) \(kind), \(active), \(level)")
    }
    exit(state.pid == nil ? 3 : 0)

case "logs":
    let path = Service.logPath
    guard FileManager.default.fileExists(atPath: path) else { fail("no log yet at \(path)") }
    let command = ["/usr/bin/tail", "-n", "20", "-F", path]
    let argv = command.map { strdup($0) } + [nil]
    execv(command[0], argv)
    fail("cannot run /usr/bin/tail: \(String(cString: strerror(errno)))")

case "once":
    let panel = panel()
    var policy = Policy()
    Daemon.perform(policy.next(docked: Display.docked(), brightness: Display.brightness(panel)), on: panel)

case "off":
    Display.darken(panel())

case "on":
    Display.light(panel())

case "uninstall":
    exit(Service.uninstall())

case "version", "--version", "-v":
    print("lidless \(version)")

case nil, "help", "--help", "-h":
    print(usage)

default:
    fputs(usage + "\n", stderr)
    fail("unknown command `\(args[0])`", 2)
}
