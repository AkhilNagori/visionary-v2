import SwiftUI
import AVFoundation
import VisionKit

/// AirPods-style pairing: a radar hero searches the network, discovered
/// glasses spring in as cards, one tap asks for the spoken 6-digit code, and
/// success is a full-screen moment (RootView's splash). QR scan and manual
/// URL+code entry remain as fallback paths.
struct PairingView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var discovery = DeviceDiscovery()

    @State private var showScanner = false
    @State private var cameraMessage: String?
    @State private var isPairing = false
    @State private var codePromptDevice: DiscoveredDevice?
    @State private var showManual = false

    @State private var manualAddress = ""
    @State private var manualCode = ""

    var body: some View {
        ZStack {
            DS.Palette.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    header
                    if let error = appState.lastError, !isPairing, codePromptDevice == nil {
                        errorCard(error)
                    }
                    nearbySection
                    scanCard
                    manualSection
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            if isPairing && codePromptDevice == nil {
                pairingOverlay
            }
        }
        .animation(DS.Motion.spring, value: discovery.devices)
        .animation(DS.Motion.gentle, value: showManual)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
        .sheet(isPresented: $showScanner) {
            ScannerSheet { payload in pair(payload) }
        }
        .sheet(item: $codePromptDevice) { device in
            CodeEntrySheet(device: device, isPairing: $isPairing) { code in
                pair(PairingPayload(url: device.url.absoluteString, token: code))
            }
            .presentationDetents([.medium, .large])
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

    // MARK: - Radar hero

    private var header: some View {
        VStack(spacing: DS.Space.l) {
            RadarView(searching: discovery.devices.isEmpty)
            Text(discovery.devices.isEmpty ? "Looking for your glasses" : "Glasses found")
                .font(DS.Text.hero)
                .multilineTextAlignment(.center)
            Text(discovery.devices.isEmpty
                 ? "Power the glasses on and keep them on the same Wi-Fi as this phone. They'll appear here on their own."
                 : "Tap your glasses below, then enter the 6-digit code they speak aloud.")
                .font(DS.Text.subhead)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DS.Space.l)
        .accessibilityElement(children: .combine)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            IconTile(icon: "exclamationmark.triangle.fill", tint: DS.Palette.attention, size: 32)
            Text(message)
                .font(DS.Text.subhead)
                .foregroundStyle(.secondary)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Discovered devices

    @ViewBuilder
    private var nearbySection: some View {
        if !discovery.devices.isEmpty {
            VStack(spacing: DS.Space.m) {
                ForEach(discovery.devices) { device in
                    deviceCard(device)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
        }
    }

    private func deviceCard(_ device: DiscoveredDevice) -> some View {
        Button {
            Haptics.tap()
            appState.lastError = nil
            codePromptDevice = device
        } label: {
            HStack(spacing: DS.Space.l) {
                IconTile(icon: "eyeglasses", size: 52, prominent: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(DS.Text.cardTitle)
                        .foregroundColor(.primary)
                    Text(device.url.host ?? device.url.absoluteString)
                        .font(DS.Text.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Connect")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.vertical, DS.Space.s)
                    .background(DS.Palette.accent, in: Capsule())
            }
            .cardStyle()
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connect to \(device.name)")
        .accessibilityHint("Asks for this device's 6-digit pairing code.")
    }

    // MARK: - Fallback paths

    private var scanCard: some View {
        Button(action: openScanner) {
            HStack(spacing: DS.Space.l) {
                IconTile(icon: "qrcode.viewfinder", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan Pairing Code")
                        .font(DS.Text.cardTitle)
                        .foregroundColor(.primary)
                    Text("The QR code on the setup sheet, or pairing_qr.png on the glasses.")
                        .font(DS.Text.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .cardStyle()
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Opens the camera to scan the pairing QR code.")
    }

    private var manualSection: some View {
        VStack(spacing: DS.Space.m) {
            Button {
                Haptics.selection()
                showManual.toggle()
            } label: {
                HStack(spacing: DS.Space.s) {
                    Text("Pair manually")
                        .font(.subheadline.weight(.medium))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(showManual ? 180 : 0))
                }
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
            }
            .accessibilityHint(showManual ? "Hides the manual address form."
                                          : "Shows a form to type the glasses' address and code.")
            if showManual {
                manualCard
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var manualCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
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
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty
                      || manualCode.trimmingCharacters(in: .whitespaces).isEmpty
                      || isPairing)
            Text("The glasses speak their 6-digit code out loud the first time they start.")
                .font(DS.Text.caption)
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }

    private var pairingOverlay: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(spacing: DS.Space.m) {
                ProgressView().controlSize(.large)
                Text("Connecting to your glasses…")
                    .font(.subheadline.weight(.medium))
            }
            .padding(DS.Space.xl)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connecting to your glasses")
    }

    // MARK: - Actions

    private func openScanner() {
        Haptics.tap()
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
            if !ok {
                Haptics.error()
            }
            // success haptic + moment live in RootView's PairSuccessSplash
        }
    }
}

// MARK: - Code entry

/// Focused one-thing screen: the device you tapped, a large code field, and a
/// Connect button. Errors from a failed attempt surface right here.
private struct CodeEntrySheet: View {
    let device: DiscoveredDevice
    @Binding var isPairing: Bool
    let onConnect: (String) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @FocusState private var focused: Bool

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DS.Space.xl) {
                    IconTile(icon: "eyeglasses", size: 64, prominent: true)
                    VStack(spacing: DS.Space.s) {
                        Text(device.name)
                            .font(DS.Text.title)
                            .multilineTextAlignment(.center)
                        Text("Enter the 6-digit code the glasses speak aloud when they start. It's also on the setup sheet.")
                            .font(DS.Text.subhead)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    TextField("6-digit code", text: $code)
                        .keyboardType(.numberPad)
                        .font(Font.title.weight(.semibold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .padding(.vertical, DS.Space.m)
                        .background(
                            DS.Palette.fill,
                            in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        )
                        .focused($focused)
                        .accessibilityLabel("6-digit pairing code")
                    if let error = appState.lastError, !isPairing {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(DS.Text.caption)
                            .foregroundStyle(DS.Palette.attention)
                            .multilineTextAlignment(.leading)
                    }
                    Button {
                        Haptics.tap()
                        onConnect(trimmedCode)
                    } label: {
                        Group {
                            if isPairing {
                                ProgressView().tint(.white)
                            } else {
                                Text("Connect")
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedCode.isEmpty || isPairing)
                }
                .padding(DS.Space.xl)
            }
            .background(DS.Palette.canvas)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                appState.lastError = nil
                focused = true
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
                        .padding(.horizontal, DS.Space.l)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, DS.Space.xl)
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

// MARK: - Radar

/// Concentric rings exhale outward from a glasses tile while searching, and
/// settle to a calm badge once something is found.
private struct RadarView: View {
    let searching: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if searching {
                ForEach(0..<3, id: \.self) { ring in
                    Circle()
                        .stroke(DS.Palette.accent.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 110, height: 110)
                        .scaleEffect(pulse ? 2.1 : 0.85)
                        .opacity(pulse ? 0 : 0.9)
                        .animation(
                            .easeOut(duration: 2.4)
                                .repeatForever(autoreverses: false)
                                .delay(Double(ring) * 0.8),
                            value: pulse
                        )
                }
            }
            IconTile(icon: "eyeglasses", size: 96)
        }
        .frame(height: 190)
        .onAppear { pulse = true }
        .accessibilityHidden(true)
    }
}
