import SwiftUI
import AVFoundation
import VisionKit

struct PairingView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var discovery = DeviceDiscovery()

    @State private var showScanner = false
    @State private var cameraMessage: String?
    @State private var isPairing = false

    @State private var showCodePrompt = false
    @State private var codePromptDevice: DiscoveredDevice?
    @State private var codeInput = ""

    @State private var manualAddress = ""
    @State private var manualCode = ""

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if let error = appState.lastError, !isPairing {
                        errorCard(error)
                    }
                    scanCard
                    nearbyCard
                    manualCard
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            if isPairing {
                pairingOverlay
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $showScanner) {
            ScannerSheet { payload in pair(payload) }
        }
        .alert("Enter Pairing Code", isPresented: $showCodePrompt) {
            TextField("6-digit code", text: $codeInput)
                .keyboardType(.numberPad)
            Button("Connect") {
                if let device = codePromptDevice {
                    pair(PairingPayload(url: device.url.absoluteString,
                                        token: codeInput.trimmingCharacters(in: .whitespaces)))
                }
                codeInput = ""
            }
            Button("Cancel", role: .cancel) { codeInput = "" }
        } message: {
            Text("The glasses speak this code aloud the first time they start. It's also on the setup sheet.")
        }
        .alert("Camera Unavailable", isPresented: cameraMessageBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cameraMessage ?? "")
        }
    }

    private var cameraMessageBinding: Binding<Bool> {
        Binding(get: { cameraMessage != nil }, set: { if !$0 { cameraMessage = nil } })
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: "eyeglasses")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityHidden(true)
            Text("Welcome to Visionary")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Let's connect this phone to your glasses. Everything stays on your local network — no accounts, no cloud.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private var scanCard: some View {
        Button(action: openScanner) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 52, height: 52)
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Scan Pairing Code")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("The QR code on the setup sheet, or pairing_qr.png on the glasses.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .cardStyle()
        .accessibilityHint("Opens the camera to scan the pairing QR code.")
    }

    private var nearbyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Glasses Nearby", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
            if discovery.devices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for glasses on your network…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Make sure the glasses are powered on and on the same Wi-Fi as this phone.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(discovery.devices) { device in
                    Button {
                        codePromptDevice = device
                        codeInput = ""
                        showCodePrompt = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "eyeglasses")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.body)
                                    .foregroundColor(.primary)
                                Text(device.url.host ?? device.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint("Asks for this device's 6-digit pairing code.")
                    if device.id != discovery.devices.last?.id {
                        Divider()
                    }
                }
            }
        }
        .cardStyle()
    }

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Enter Manually", systemImage: "keyboard")
                .font(.headline)
            TextField("Device address (visionary.local)", text: $manualAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityHint("The glasses' network address, like visionary.local.")
            TextField("6-digit pairing code", text: $manualCode)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            Button(action: manualPair) {
                Text("Connect")
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
                      || manualCode.trimmingCharacters(in: .whitespaces).isEmpty
                      || isPairing)
            Text("The glasses speak their 6-digit code out loud the first time they start.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var pairingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Connecting to your glasses…")
                    .font(.subheadline.weight(.medium))
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connecting to your glasses")
    }

    // MARK: - Actions

    private func openScanner() {
        guard DataScannerViewController.isSupported else {
            cameraMessage = "This device can't scan QR codes. Use a nearby device or manual entry instead."
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentScannerIfAvailable()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        presentScannerIfAvailable()
                    } else {
                        cameraMessage = "Camera access was declined. You can pair from the nearby list or manual entry, or allow the camera in Settings."
                    }
                }
            }
        default:
            cameraMessage = "Camera access is off. Allow it in Settings, or pair from the nearby list or manual entry."
        }
    }

    private func presentScannerIfAvailable() {
        if DataScannerViewController.isAvailable {
            showScanner = true
        } else {
            cameraMessage = "The camera isn't available right now. Try the nearby list or manual entry."
        }
    }

    private func manualPair() {
        guard let url = normalizedURL(manualAddress) else {
            appState.lastError = "That address doesn't look right. Try something like visionary.local."
            Haptics.error()
            return
        }
        pair(PairingPayload(url: url, token: manualCode.trimmingCharacters(in: .whitespaces)))
    }

    private func normalizedURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), comps.host != nil else { return nil }
        if comps.port == nil { comps.port = 8321 }
        return comps.url?.absoluteString
    }

    private func pair(_ payload: PairingPayload) {
        guard !isPairing else { return }
        isPairing = true
        Task { @MainActor in
            let ok = await appState.pair(payload: payload)
            isPairing = false
            if ok {
                Haptics.success()
            } else {
                Haptics.error()
            }
        }
    }
}

// MARK: - QR scanner

private struct ScannerSheet: View {
    let onFound: (PairingPayload) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var found = false
    @State private var showBadCodeHint = false

    var body: some View {
        NavigationStack {
            QRScannerRepresentable { code in handle(code) }
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    Text(showBadCodeHint
                         ? "That's not a Visionary pairing code."
                         : "Point the camera at the pairing QR code.")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
                .navigationTitle("Scan Pairing Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    private func handle(_ code: String) {
        guard !found else { return }
        if let payload = try? JSONDecoder().decode(PairingPayload.self, from: Data(code.utf8)) {
            found = true
            Haptics.tap()
            onFound(payload)
            dismiss()
        } else {
            showBadCodeHint = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                showBadCodeHint = false
            }
        }
    }
}

private struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning {
            try? controller.startScanning()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    onScan(value)
                    return
                }
            }
        }
    }
}
