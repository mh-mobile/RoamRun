import SwiftUI
import VisionKit

/// The camera, reading the code `roamrun pair xcode --qr` draws; other codes are passed over.
struct Scanner: UIViewControllerRepresentable {
    let found: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let found: (URL) -> Void
        init(found: @escaping (URL) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in added {
                guard let url = code.payloadStringValue.flatMap(URL.init(string:)), url.scheme == "roamrun-introducer" else { continue }
                scanner.stopScanning()
                found(url)
                return
            }
        }
    }
}
