import Foundation
import Testing
@testable import RoamRun

@Test func onlyOurOutdatedSkillsAreReported() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("roamrun-home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let current = Data("---\nname: roamrun\ndescription: now\n---\n".utf8)
    func put(_ client: String, _ text: String) throws {
        let dir = home.appendingPathComponent("\(client)/skills/roamrun")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
    }
    try put(".claude", "---\nname: roamrun\ndescription: older\n---\n")   // ours, another version
    try put(".codex", String(decoding: current, as: UTF8.self))              // ours, this version
    try put(".cursor", "---\nname: something-else\n---\n")                // not ours
    let linked = home.appendingPathComponent(".gemini/skills")                  // managed by another tool
    try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("roamrun"),
                                               withDestinationURL: home.appendingPathComponent(".claude/skills/roamrun"))
    #expect(CLI.staleSkills(home: home, bundled: current) == [home.appendingPathComponent(".claude/skills/roamrun").path])
}

@Test func infoPlistMatchesAppID() throws {
    // AppID.bundle names the defaults domain, log subsystem and notifications: it must be the real id.
    let plist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Info.plist")
    let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any]
    #expect(info?["CFBundleIdentifier"] as? String == AppID.bundle)
}

/// Agents run SKILL.md's commands as written, and people copy the READMEs': each `roamrun …`
/// in their code (fenced blocks and inline code) must be a command the CLI knows, with options it takes.
@Test(arguments: ["skills/roamrun/SKILL.md", "skills/roamrunctl/SKILL.md", "README.md", "README.ja.md", "docs/another-mac.md"])
func everyDocumentedCommandParses(_ doc: String) throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: root.appendingPathComponent(doc), encoding: .utf8)
    var code: [String] = []
    var fenced = false
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("```") { fenced.toggle(); continue }
        if fenced { code.append(String(line)) } else { code += line.matches(of: #/`([^`]+)`/#).map { String($0.1) } }
    }
    var checked = 0
    for snippet in code {
        // Only where `roamrun` starts a command, not as another tool's argument; comments dropped.
        // Placeholders (<name>) become a word first: their ">" isn't a redirection.
        let line = (snippet.split(separator: " #", maxSplits: 1).first.map(String.init) ?? snippet)
            .replacing(#/<[^<>\s]+>/#, with: "x")
        for m in line.matches(of: #/(?:^\s*|[(;&|]\s*)roamrun\s+([^|;&>)\n]*)/#) {
            var words = m.1.split(whereSeparator: \.isWhitespace).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]'\"")).replacingOccurrences(of: "...", with: "")
                    .replacingOccurrences(of: "…", with: "")
            }.filter { !$0.isEmpty }
            // A placeholder value (--wait N, --url URL) stands for a valid one.
            for i in words.indices.dropFirst() where words[i].allSatisfy({ $0.isUppercase }) {
                switch words[i - 1] {
                case "--wait": words[i] = "1"
                case "--url": words[i] = "x://y"
                case "--env": words[i] = "A=b"
                default: break
                }
            }
            guard let command = words.first else { continue }
            #expect(CLI.commands.contains(command), "\(doc): roamrun \(m.1)")
            checked += 1
            if command == "init" {
                let known: Set = ["--client", "--print", "--uninstall", "claude", "codex", "cursor", "gemini", "copilot", "devin", "x"]
                let given = words.dropFirst().map { $0.hasPrefix("--client=") ? "--client" : $0 }
                #expect(Set(given).isSubset(of: known), "\(doc): roamrun \(m.1)")
            } else if case .failure(let e) = CLI.parse(words) {
                Issue.record("\(doc): roamrun \(m.1) — \(e.message)")
            }
        }
    }
    // The extraction itself still finds them; roamrunctl's skill shows few of `roamrun`'s own.
    #expect(checked > (doc.hasPrefix("docs/") || doc.contains("roamrunctl") ? 5 : 15))
}
