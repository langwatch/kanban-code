import SwiftUI
import VisionKit
import KanbanCodeRemoteKit

struct PairingView: View {
    var isFirstRun = false
    @Environment(ServerStore.self) private var servers
    @Environment(PairingCoordinator.self) private var pairing
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var tokenText = ""
    @State private var showScanner = false

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text("Pair with your Mac")
                        .font(.title2.bold())
                    Text("On the Mac, open Kanban Code, then Settings > Remote Control > Add device. Scan the code it shows, or paste the link.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            Section {
                if scannerAvailable {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                }
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { await pair(text) }
                }
                .accessibilityIdentifier("pasteLink")
            } footer: {
                if !scannerAvailable {
                    Text("Scanning needs the camera, which is not available here. Paste the link instead.")
                }
            }

            Section("Enter manually") {
                TextField("Mac address, like 100.64.0.1:7780", text: $urlText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverURL")
                SecureField("Token (kc_...)", text: $tokenText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverToken")
                Button("Pair") {
                    Task { await pairManually() }
                }
                .disabled(RemoteServerURL.normalize(urlText) == nil || tokenText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error = pairing.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }
        }
        .navigationTitle(isFirstRun ? "Kanban Code" : "Add a Mac")
        .navigationBarTitleDisplayMode(isFirstRun ? .large : .inline)
        .toolbar {
            if !isFirstRun {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            QRScannerSheet { payload in
                showScanner = false
                Task { await pair(payload) }
            }
        }
        .onAppear { pairing.error = nil }
    }

    private func pair(_ text: String) async {
        guard let link = RemotePairLink.parse(text) else {
            pairing.error = "That is not a Kanban Code pairing link."
            return
        }
        if await pairing.pair(link, into: servers) { dismiss() }
    }

    private func pairManually() async {
        guard let url = RemoteServerURL.normalize(urlText) else { return }
        let link = RemotePairLink(baseURL: url, token: tokenText.trimmingCharacters(in: .whitespacesAndNewlines))
        if await pairing.pair(link, into: servers) { dismiss() }
    }
}

/// Full-screen camera that reports the first Kanban Code link it sees.
struct QRScannerSheet: View {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            QRScanner(onFound: onFound)
                .ignoresSafeArea()
                .navigationTitle("Scan QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var done = false

        init(onFound: @escaping (String) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let payload = code.payloadStringValue,
                   RemotePairLink.parse(payload) != nil {
                    done = true
                    scanner.stopScanning()
                    onFound(payload)
                    return
                }
            }
        }
    }
}
