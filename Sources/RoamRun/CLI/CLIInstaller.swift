import Foundation

/// Links /usr/local/bin/roamrun to this app's binary (the app doubles as the
/// CLI), like VS Code's "Install 'code' command in PATH".
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/roamrun"
    /// Where the Homebrew cask links it.
    static let homebrewLink = "/opt/homebrew/bin/roamrun"

    enum State: Equatable {
        case notInstalled
        case installed               // points at this copy of the app
        case pointsElsewhere(String) // a link to another copy of RoamRun (e.g. the app moved)
        case blockedByFile           // a file or another tool's link — never overwritten
    }

    static var target: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
    }

    /// A link to this copy, ours or Homebrew's.
    static var installedPath: String? {
        [linkPath, homebrewLink].first { path in
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path))
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == target } ?? false
        }
    }

    static var state: State { installedPath != nil ? .installed : linkState }

    /// linkPath alone — what install() would replace.
    private static var linkState: State {
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
        // Opened from the dmg or Downloads, macOS runs a temporary copy (App
        // Translocation) or the dmg's own, both gone once the app quits.
        let readOnly = (try? URL(fileURLWithPath: target).resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        guard !target.contains("/AppTranslocation/"), !readOnly else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                "Move RoamRun to /Applications and open it from there first — this copy is temporary."])
        }
        guard linkState != .blockedByFile else {
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
