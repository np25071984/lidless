import Foundation

let version = "0.2.1"

extension CommandLine {
    /// This binary's absolute path, symlinks resolved: what launchd must run,
    /// and how a Homebrew install is recognised.
    static var executable: String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return arguments[0] }
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(buffer, &resolved) != nil ? String(cString: resolved) : String(cString: buffer)
    }
}

/// The service's log is its stderr, which launchd sends to a file
/// (`Service.logPath`); `lidless logs` follows it.
func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}
