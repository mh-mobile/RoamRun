import Foundation

/// Links /usr/local/bin/roamrun to this app's binary (the app doubles as the
/// CLI), like VS Code's "Install 'code' command in PATH".
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/roamrun"

    enum State: Equatable {
        case notInstalled
        case installed               // points at this copy of the app
        case pointsElsewhere(String) // a link to another copy of RoamRun (e.g. the app moved)
        case blockedByFile           // a file or another tool's link — never overwritten
    }

    static var target: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    static var state: State {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath) else {
            return fm.fileExists(atPath: linkPath) ? .blockedByFile : .notInstalled
        }
        if URL(fileURLWithPath: dest).resolvingSymlinksInPath().path == target { return .installed }
        return (dest as NSString).lastPathComponent == "RoamRun" ? .pointsElsewhere(dest) : .blockedByFile
    }

    /// Plain FileManager first; if /usr/local/bin is missing or not writable
    /// (no Homebrew), retry once through an admin-password prompt.
    static func install() throws {
        guard state != .blockedByFile else {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                "\(linkPath) belongs to something else. Remove it yourself if you want RoamRun's CLI there."])
        }
        let fm = FileManager.default
        do {
            try? fm.removeItem(atPath: linkPath)
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)
        } catch {
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            // Same rule as root: only an absent path or a link to RoamRun may be replaced.
            let l = q(linkPath)
            let shell = "mkdir -p /usr/local/bin && { { [ ! -e \(l) ] && [ ! -L \(l) ]; } || { [ -L \(l) ] && readlink \(l) | grep -q '/RoamRun$'; }; } && ln -sfh \(q(target)) \(l)"
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
