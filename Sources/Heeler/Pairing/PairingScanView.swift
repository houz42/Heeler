import AVFoundation
import SwiftUI
import UIKit
import VisionKit

/// Scan to Pair (#62, #66, #204): the camera entry for Pairing Codes, with
/// a paste path for the same string, the permission prompt, and a usable
/// denied path. Once a code parses, the pairing ceremony runs immediately —
/// one scan or paste, no confirmation step — and on success the persisted
/// Host is handed to `onPaired`, entering the same preflight a manually
/// added Host does.
struct PairingScanView: View {
    let onPaired: (Host) -> Void
    let onAddManually: () -> Void
    @State private var store: PairingScanStore
    @State private var isPastingPairingCode = false
    @State private var cameraAccess: CameraAccess = .undetermined
    @Environment(\.dismiss) private var dismiss

    init(
        catalog: HostStore,
        connector: (any PairingConnector)? = nil,
        onPaired: @escaping (Host) -> Void = { _ in },
        onAddManually: @escaping () -> Void = {}
    ) {
        self.onPaired = onPaired
        self.onAddManually = onAddManually
        _store = State(
            initialValue: connector.map {
                PairingScanStore(catalog: catalog, connector: $0)
            } ?? PairingScanStore(catalog: catalog))
    }

    private enum CameraAccess {
        case undetermined
        case authorized
        case denied
    }

    /// Simulator-only launch argument (DEBUG simulator builds): forces
    /// the camera-authorized scanning layout without the system
    /// camera-permission prompt, which XCUITest cannot answer. Keeps the
    /// paste-path proofs on the same layout a real phone shows after
    /// granting camera access.
    static var forceCameraAuthorizedForTesting: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--uitest-pairing-authorized-camera")
        #else
        false
        #endif
    }
    var body: some View {
        NavigationStack {
            Group {
                if let code = store.pairingCode {
                    PairingCeremonyView(code: code, store: store)
                } else {
                    scanner
                }
            }
            .navigationTitle("Scan to Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $isPastingPairingCode) {
                PairingPasteView(store: store)
            }
            .task { await resolveCameraAccess() }
            .onChange(of: store.pairedHost) { _, paired in
                guard let paired else { return }
                dismiss()
                onPaired(paired)
            }
        }
    }

    @ViewBuilder
    private var scanner: some View {
        // The paste entry is NOT a camera fallback: a remote user who
        // cannot see the Host's screen pairs from a code sent to them,
        // so it stays mounted in every scanning state — including the
        // healthy camera path, where it used to ride only in the
        // scanner's bottom overlay and was easy to miss (or never
        // reached at all when the camera permission prompt interrupted
        // the flow).
        switch cameraAccess {
        case .undetermined:
            // The system permission prompt is up (or about to be). The
            // paste entry must be usable even while (or instead of)
            // answering it — answering is optional for pasting.
            VStack(spacing: 16) {
                ProgressView()
                Text("Waiting for camera permission…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                pasteEntryButton
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            ContentUnavailableView {
                Label("Camera Access Needed", systemImage: "camera")
            } description: {
                Text(store.scanFailureMessage ?? deniedCameraCopy)
            } actions: {
                pasteEntryButton
                Button("Open Settings") { openSettings() }
                Button("Add Manually") { addManually() }
            }
        case .authorized:
            if DataScannerViewController.isSupported {
                scannerViewport
            } else {
                ContentUnavailableView {
                    Label("Scanning Unavailable", systemImage: "camera")
                } description: {
                    Text(
                        store.scanFailureMessage
                            ?? "This device cannot scan QR codes. "
                            + "Paste a Pairing Code, or add the Host manually instead.")
                } actions: {
                    pasteEntryButton
                    Button("Add Manually") { addManually() }
                }
            }
        }
    }

    /// The manual fallback: hand off to the presenter (which owns the manual
    /// Host form) and close this sheet, mirroring the `onPaired` hand-off.
    private func addManually() {
        onAddManually()
        dismiss()
    }

    private var scannerViewport: some View {
        PairingCodeScanner { store.submit(scannedCode: $0) }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                VStack(spacing: 12) {
                    pasteEntryButton
                    Text(
                        store.scanFailureMessage
                            ?? "Point the camera at the Pairing Code shown by herdr.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
                .padding()
            }
    }

    /// The always-mounted paste entry ("Paste Pairing Code"). One tap opens
    /// a sheet with both ways to bring the code in: paste from the
    /// clipboard (a user-initiated paste so iOS shows its pasteboard
    /// prompt against a tap, not a background read — #204) and a text
    /// field to type or paste the code by hand. A remote user's code
    /// arrives over any channel; the sheet keeps both within reach
    /// without dismissing the scanner.
    private var pasteEntryButton: some View {
        Button("Paste Pairing Code") { isPastingPairingCode = true }
            .buttonStyle(.borderedProminent)
    }

    private var deniedCameraCopy: String {
        "Scanning a Pairing Code uses the camera. Allow camera access in Settings, "
            + "paste a Pairing Code, or add the Host manually instead."
    }

    private func resolveCameraAccess() async {
        if Self.forceCameraAuthorizedForTesting {
            cameraAccess = .authorized
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAccess = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraAccess = granted ? .authorized : .denied
        default:
            cameraAccess = .denied
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// The paste entry sheet (#204, remote pairing): both ways to bring a
/// Pairing Code in without the camera. "Paste from Clipboard" is a
/// user-initiated paste so iOS shows its pasteboard prompt against the
/// tap (never a background read); the field covers codes typed by hand
/// or arriving over any other channel. A code pasted here rides the
/// SAME `submit` path a scan uses — decode, ceremony, Host persisted —
/// and the sheet closes itself once the code parses.
private struct PairingPasteView: View {
    let store: PairingScanStore
    @Environment(\.dismiss) private var dismiss
    @State private var typedCode = ""
    @State private var pasteFromClipboardFailed = false
    @FocusState private var fieldIsFocused: Bool

    /// The clipboard was empty (or whitespace). Shown inline instead of
    /// surfacing a decode error for a non-code.
    private var clipboardEmptyCopy: String {
        "The clipboard is empty. Copy the Pairing Code first — herdr shows it "
            + "next to its QR code, with a Copy action."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        pasteFromClipboardTapped()
                    } label: {
                        Label("Paste from Clipboard", systemImage: "clipboard")
                    }
                    if pasteFromClipboardFailed {
                        Text(clipboardEmptyCopy)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Pairing Code")
                } footer: {
                    Text(
                        "Remote setup: ask the person at the computer to run herdr's "
                        + "pair command and send you the code. It is the same code as "
                        + "the QR; pasting it here pairs exactly like scanning it.")
                }

                Section("Or type / paste the code") {
                    TextField(
                        "HERDR-PAIR:1:…",
                        text: $typedCode,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .focused($fieldIsFocused)
                    .lineLimit(2...4)
                    Button("Pair with This Code") { submitTyped() }
                        .disabled(typedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let failure = store.scanFailureMessage {
                    // Honest parse feedback from the same submit path —
                    // this is where a malformed / expired / wrong QR's
                    // copy surfaces.
                    Section {
                        Text(failure)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Paste Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: store.pairingCode) { _, parsed in
                // The code parsed: the ceremony starts behind this sheet.
                // Close so the user sees it; keep the parse failure up
                // otherwise.
                if parsed != nil { dismiss() }
            }
            .onAppear { fieldIsFocused = true }
        }
    }

    /// A user-initiated paste (the tap is the user gesture iOS requires
    /// for the pasteboard prompt, #204). An empty clipboard is honest
    /// inline feedback, not a silent no-op the old single button had.
    private func pasteFromClipboardTapped() {
        let pasted = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !pasted.isEmpty else {
            pasteFromClipboardFailed = true
            return
        }
        pasteFromClipboardFailed = false
        store.submit(scannedCode: pasted)
    }

    private func submitTyped() {
        let code = typedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        store.submit(scannedCode: code)
    }
}

/// The ceremony in flight (#66): the scanned Host, per-step progress, and on
/// failure that step's copy with its recovery actions. The ceremony starts on
/// arrival; Try Again reruns it with the same code while its TTL holds, so a
/// network blip never forces a rescan.
private struct PairingCeremonyView: View {
    let code: PairingCode
    let store: PairingScanStore
    @State private var attempt = 0

    private enum StepStatus {
        case pending
        case active
        case done
        case failed
    }

    var body: some View {
        List {
            Section("Host") {
                LabeledContent("User", value: code.username)
                LabeledContent(
                    "Address",
                    value: code.addresses.count == 1
                        ? code.addresses[0] : "\(code.addresses.count) candidates")
                if code.port != 22 {
                    LabeledContent("Port", value: String(code.port))
                }
            }

            Section {
                ForEach(ceremonySteps, id: \.self) { step in
                    stepRow(step)
                }
            } header: {
                Text("Pairing")
            } footer: {
                if store.failure == nil {
                    Text("Host key pinned from the Pairing Code — no fingerprint prompt.")
                }
            }

            if let failure = store.failure {
                Section {
                    Text(failure.message)
                    if failure.canRetry {
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            attempt += 1
                        }
                    }
                    Button("Scan Again", systemImage: "qrcode.viewfinder") {
                        store.rescan()
                    }
                }
            }
        }
        .task(id: attempt) { await store.pair() }
    }

    /// The steps this code's ceremony performs. A config-only code carries no
    /// Bootstrap Key: the Device Key reconnect is the whole ceremony.
    private var ceremonySteps: [PairingStep] {
        code.bootstrap == nil
            ? [.reach, .verify]
            : [.reach, .authenticate, .enroll, .verify]
    }

    private func stepRow(_ step: PairingStep) -> some View {
        HStack {
            Text(title(for: step))
            Spacer()
            switch status(for: step) {
            case .pending:
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            case .active:
                ProgressView()
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func title(for step: PairingStep) -> String {
        switch step {
        case .parse: "Read the code"
        case .reach: "Reach the Host"
        case .authenticate: "Authenticate with the Pairing Code"
        case .enroll: "Enroll this device"
        case .verify: "Verify the new key"
        }
    }

    private func status(for step: PairingStep) -> StepStatus {
        if store.pairedHost != nil {
            return .done
        }
        if let failure = store.failure {
            // `.parse` failures precede the ceremony: every row stays pending.
            if step == failure.step { return .failed }
            return rank(step) < rank(failure.step) ? .done : .pending
        }
        guard let current = store.step else {
            return store.isPairing && step == ceremonySteps.first ? .active : .pending
        }
        // The connector reports a step as it begins; earlier ones finished.
        if step == current { return .active }
        return rank(step) < rank(current) ? .done : .pending
    }

    private func rank(_ step: PairingStep) -> Int {
        PairingStep.allCases.firstIndex(of: step) ?? 0
    }
}

/// The system scanner (VisionKit), narrowed to QR codes. Reports every newly
/// recognized payload string; filtering and parsing belong to the store.
private struct PairingCodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        // Fails only when capture is unavailable (already gated on
        // authorization and isSupported); the denied path covers the rest.
        try? scanner.startScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for case .barcode(let barcode) in addedItems {
                if let payload = barcode.payloadStringValue {
                    onScan(payload)
                }
            }
        }
    }
}
