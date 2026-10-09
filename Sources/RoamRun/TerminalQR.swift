import CoreImage

/// A QR code drawn in a terminal's characters.
enum TerminalQR {
    /// The code's modules, top row first, dark as true, with the one-module margin CoreImage gives it.
    /// `level`: L, M, Q or H — how much of it may be lost; less makes a smaller code.
    static func modules(_ text: String, level: String = "M") -> [[Bool]] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return [] }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(level, forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return [] }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        CIContext(options: [.useSoftwareRenderer: true])
            .render(image, toBitmap: &pixels, rowBytes: w * 4, bounds: image.extent, format: .RGBA8, colorSpace: nil)
        return (0..<h).map { y in (0..<w).map { x in pixels[(y * w + x) * 4] < 128 } }
    }

    /// Two rows of modules to a line, black on white whatever the terminal's own colours are.
    static func lines(_ text: String, level: String = "M") -> [String] {
        var rows = modules(text, level: level)
        guard let width = rows.first?.count else { return [] }
        let side = [Bool](repeating: false, count: 3), blank = [Bool](repeating: false, count: width + 6)
        rows = [blank, blank, blank] + rows.map { side + $0 + side } + [blank, blank, blank]
        if rows.count % 2 == 1 { rows.append(blank) }
        return stride(from: 0, to: rows.count, by: 2).map { y in
            on + zip(rows[y], rows[y + 1]).map { $0 ? ($1 ? "█" : "▀") : ($1 ? "▄" : " ") }.joined() + off
        }
    }

    private static let on = "\u{1B}[30;107m", off = "\u{1B}[0m"

    /// The window those lines take: their own width, and two rows more for what is said around them.
    static func room(for lines: [String]) -> (across: Int, down: Int) {
        (max(0, (lines.first?.unicodeScalars.count ?? 0) - on.unicodeScalars.count - off.unicodeScalars.count), lines.count + 2)
    }
}
