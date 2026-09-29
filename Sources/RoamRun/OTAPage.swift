import Foundation

/// The manifest iOS installs from, and the page you open on the device. Both are
/// made when they're asked for: the base URL comes from the request, so nothing
/// goes stale when the tailnet name or the served path changes.
extension OTA {
    /// `itms-services` fetches this, reads where the .ipa is, and installs it.
    static func manifest(for build: Build, base: String) -> Data? {
        let plist: [String: Any] = [
            "items": [[
                "assets": [["kind": "software-package", "url": "\(base)/\(build.bundleID)/\(build.slug)/app.ipa"]],
                "metadata": [
                    "bundle-identifier": build.bundleID,
                    // CFBundleVersion, which is what Apple's key means; the page
                    // shows the marketing version beside it.
                    // From the archive's Info.plist, like the title: no control characters in XML.
                    "bundle-version": printable(build.build.isEmpty ? build.version : build.build),
                    "kind": "software",
                    "title": printable(build.title),
                ],
            ]],
        ]
        // nil, not empty: a 200 carrying no manifest is an install that fails
        // with nothing to go on, which is the failure this whole path avoids.
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    /// XML 1.0 can't carry most control characters, and the title comes out of
    /// someone else's .ipa. Whether Foundation refuses them or emits them anyway
    /// turns out to depend on the machine, so they don't get that far.
    static func printable(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter {
            !(($0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r") || $0.value == 0xFFFE || $0.value == 0xFFFF)
        }))
    }

    static func installLink(for build: Build, base: String) -> String {
        "itms-services://?action=download-manifest&url=\(base)/\(build.bundleID)/\(build.slug)/manifest.plist"
    }

    /// One page for everything, so the URL can be a bookmark: the newest build of
    /// each app is open, older ones fold away. Read one-handed, so the newest
    /// build's button is the big one.
    static func indexHTML(_ groups: [(bundleID: String, builds: [Build])], base: String,
                          now: Date = .now, in root: URL? = nil) -> String {
        let body = groups.isEmpty ? """
            <p class="empty">No builds yet. Run <code>roamrun ota &lt;name&gt; &lt;App.ipa&gt;</code> on the Mac.</p>
            """ : groups.map { app in
            let newest = app.builds[0]
            let older = app.builds.dropFirst()
            let olderHTML = older.isEmpty ? "" : """
                <details><summary>\(older.count) earlier \(older.count == 1 ? "build" : "builds")</summary>
                \(older.map { row($0, base: base, now: now, newest: false) }.joined(separator: "\n"))
                </details>
                """
            let icon = OTA.hasIcon(newest, in: root)
                ? #"<img class="icon" width="60" height="60" src="\#(escape(base))/\#(escape(app.bundleID))/\#(escape(newest.slug))/icon.png" alt="">"# : ""
            return """
                <section>
                  <div class="app">\(icon)<div>
                    <h2>\(escape(newest.title))</h2>
                    <p class="bundle">\(escape(app.bundleID))</p>
                  </div></div>
                  \(row(newest, base: base, now: now, newest: true))
                  \(olderHTML)
                </section>
                """
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html lang="en"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <title>RoamRun</title>
        <style>
        :root { color-scheme: light dark; --bg: #fff; --fg: #111; --dim: #666; --card: #f4f4f6; --line: #e3e3e8; --tint: #0060df; }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #000; --fg: #f2f2f7; --dim: #98989f; --card: #1c1c1e; --line: #2c2c2e; --tint: #0a84ff; }
        }
        * { box-sizing: border-box; }
        body { margin: 0 auto; max-width: 34rem;
               padding: max(24px, env(safe-area-inset-top)) max(16px, env(safe-area-inset-right))
                        calc(24px + env(safe-area-inset-bottom)) max(16px, env(safe-area-inset-left));
               background: var(--bg); color: var(--fg); font: 17px/1.5 -apple-system, BlinkMacSystemFont, sans-serif; }
        header { margin: 0 0 28px; font-size: 15px; color: var(--dim); }
        section { margin: 0 0 36px; }
        .app { display: flex; align-items: center; gap: 14px; margin: 0 0 16px; }
        .icon { width: 60px; height: 60px; border-radius: 13px; flex: none; background: var(--card); }
        h2 { margin: 0; font-size: 26px; letter-spacing: -0.02em; overflow-wrap: anywhere; }
        .bundle { margin: 2px 0 0; font-size: 13px; color: var(--dim); word-break: break-all; }
        .build { background: var(--card); border-radius: 14px; padding: 14px 16px; margin: 0 0 10px; }
        .build .top { display: flex; align-items: baseline; gap: 8px; flex-wrap: wrap; }
        .ver { font-size: 19px; font-weight: 600; }
        .tag { font-size: 12px; font-weight: 600; color: var(--tint); }
        .meta { margin: 2px 0 12px; font-size: 14px; color: var(--dim); }
        a.install { display: block; text-align: center; text-decoration: none; font-weight: 600;
                    background: var(--tint); color: #fff; border-radius: 11px; padding: 13px; }
        .newest a.install { font-size: 19px; padding: 16px; }
        details { margin-top: 6px; }
        summary { font-size: 15px; color: var(--tint); padding: 8px 2px; cursor: pointer; }
        footer { margin-top: 40px; padding-top: 16px; border-top: 1px solid var(--line); font-size: 14px; color: var(--dim); }
        code { font-size: 14px; }
        .empty { color: var(--dim); }
        .gone { margin: 0; font-size: 15px; }
        </style>
        </head><body>
        <header>RoamRun</header>
        \(body)
        <footer>Tapping Install adds the app to your Home Screen. Safari shows no progress — watch the icon
        there, and keep the screen on until it finishes: the VPN pauses when the device sleeps.
        If it installs but won't open: an Ad Hoc build needs Developer Mode on, under Settings ›
        Privacy &amp; Security, where the switch appears once the app is there; an Enterprise one needs
        its developer trusted, under Settings › General › VPN &amp; Device Management.
        Everyone on this tailnet can open this page and install these builds.</footer>
        </body></html>
        """
    }

    private static func row(_ build: Build, base: String, now: Date, newest: Bool) -> String {
        var bits = [when(build.added, now: now), size(build.size)]
        // Checked when it was stored, but a profile only lasts a year and these
        // are kept for months: the device would just refuse it with nothing said.
        let expired = (build.expires ?? .distantFuture) < now
        if expired, let expires = build.expires {
            bits.append("EXPIRED \(expires.formatted(date: .abbreviated, time: .omitted))")
        }
        let action = expired
            ? #"<p class="gone">Can't be installed any more — its provisioning profile expired. Export the build again on the Mac.</p>"#
            : #"<a class="install" href="\#(escape(installLink(for: build, base: base)))">Install</a>"#
        return """
            <div class="build\(newest ? " newest" : "")">
              <div class="top"><span class="ver">\(escape(build.label))</span>\(newest ? #"<span class="tag">NEWEST</span>"# : "")</div>
              <div class="meta">\(escape(bits.joined(separator: " · ")))</div>
              \(action)
            </div>
            """
    }

    /// Read faster than a timestamp when you're walking.
    static func when(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The title comes from the .ipa, and the bundle id from its Info.plist.
    static func escape(_ s: String) -> String {
        printable(s).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
