import Foundation

/// Links /usr/local/bin/roamrun to this app's binary (the app doubles as the
/// CLI), like VS Code's "Install 'code' command in PATH".
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/roamrun"

    enum State: Equatable {
        case notInstalled
        case installed               // points at this copy of the app
        case pointsElsewhere(String) // stale link, e.g. the app was moved
        case blockedByFile           // a real file we won't overwrite
    }

    static var target: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    static var state: State {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
            return fm.fileExists(atPath: linkPath) ? .blockedByFile : .notInstalled
        }
        return URL(fileURLWithPath: dest).resolvingSymlinksInPath().path == target ? .installed : .pointsElsewhere(dest)
    }

    /// Plain FileManager first; if /usr/local/bin is missing or not writable
    /// (no Homebrew), retry once through an admin-password prompt.
    static func install() throws {
        guard state != .blockedByFile else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                "\(linkPath) is a regular file, not a link. Remove it yourself if you want RoamRun's CLI there."])
        }
        let fm = FileManager.default
        do {
            try? fm.removeItem(atPath: linkPath)
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
        } catch {
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let shell = "mkdir -p /usr/local/bin && ln -sfh \(q(target)) \(q(linkPath))"
            let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let err {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey:
                    (err[NSAppleScript.errorMessage] as? String) ?? "Could not install the command line tool."])
            }
        }
    }
}
