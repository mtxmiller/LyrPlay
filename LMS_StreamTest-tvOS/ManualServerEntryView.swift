import SwiftUI
import os.log

struct ManualServerEntryView: View {
    /// See `ServerConnectView.onComplete`. When non-nil, success commits the
    /// host but skips `markAsConfigured()` and calls `onComplete()` so the
    /// caller can rebuild the existing coordinator instead of triggering a
    /// RootView swap.
    var onComplete: (() -> Void)? = nil

    @StateObject private var settings = SettingsManager.shared

    @State private var octet1: String = ""
    @State private var octet2: String = ""
    @State private var octet3: String = ""
    @State private var octet4: String = ""
    @State private var webPort: String = "9000"
    @State private var slimPort: String = "3483"

    @State private var isTesting: Bool = false
    @State private var testTask: Task<Void, Never>? = nil
    @State private var errorMessage: String? = nil
    @State private var didPrefill: Bool = false
    @State private var signInTarget: ServerSignInTarget? = nil

    @FocusState private var focusedField: Field?

    private let logger = OSLog(subsystem: "com.lmsstream", category: "ManualServerEntry")

    private enum Field: Hashable {
        case octet1, octet2, octet3, octet4
        case webPort
        case slimPort
        case connect
    }

    var body: some View {
        VStack(spacing: 40) {
            Text("Enter server address")
                .font(.largeTitle)
                .padding(.top, 40)

            VStack(spacing: 32) {
                octetRow

                portRow

                connectRow

                if let errorMessage {
                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }

            Spacer()
        }
        .frame(maxWidth: 900)
        .padding(.horizontal, 80)
        .onAppear(perform: prefillIfNeeded)
        .onDisappear { testTask?.cancel() }
        .defaultFocus($focusedField, .octet1)
        .navigationDestination(item: $signInTarget) { target in
            ServerSignInView(target: target, onComplete: onComplete)
        }
    }

    private var octetRow: some View {
        HStack(spacing: 16) {
            octetField(text: $octet1, focus: .octet1, position: 1)
            Text(".").font(.title)
            octetField(text: $octet2, focus: .octet2, position: 2)
            Text(".").font(.title)
            octetField(text: $octet3, focus: .octet3, position: 3)
            Text(".").font(.title)
            octetField(text: $octet4, focus: .octet4, position: 4)
        }
    }

    private func octetField(text: Binding<String>, focus: Field, position: Int) -> some View {
        TextField("0", text: text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .frame(width: 140)
            .focused($focusedField, equals: focus)
            .accessibilityLabel("Address octet \(position) of 4")
            .accessibilityValue(text.wrappedValue.isEmpty ? "Empty" : text.wrappedValue)
            .onChange(of: text.wrappedValue) { _, newValue in
                let filtered = String(newValue.filter(\.isNumber).prefix(3))
                if filtered != newValue {
                    text.wrappedValue = filtered
                }
            }
    }

    /// Web port + player (SlimProto) port. The player port is 3483 unless
    /// the server maps it elsewhere (Docker, a second LMS on one host).
    private var portRow: some View {
        HStack(spacing: 48) {
            portField(label: "Web port", placeholder: "9000", text: $webPort, focus: .webPort)
            portField(label: "Player port", placeholder: "3483", text: $slimPort, focus: .slimPort)
        }
    }

    private func portField(label: LocalizedStringKey, placeholder: String, text: Binding<String>, focus: Field) -> some View {
        HStack(spacing: 24) {
            Text(label)
                .font(.title3)
            TextField(placeholder, text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .frame(width: 200)
                .focused($focusedField, equals: focus)
                .accessibilityLabel(Text(label))
                .accessibilityValue(text.wrappedValue.isEmpty ? "Empty" : text.wrappedValue)
                .onChange(of: text.wrappedValue) { _, newValue in
                    let filtered = String(newValue.filter(\.isNumber).prefix(5))
                    if filtered != newValue {
                        text.wrappedValue = filtered
                    }
                }
        }
    }

    private var connectRow: some View {
        HStack(spacing: 24) {
            if isTesting {
                Button {
                    cancelTest()
                } label: {
                    Text("Cancel")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }

            Button {
                runConnectionTest()
            } label: {
                if isTesting {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Testing…")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                } else {
                    Text("Connect")
                        .padding(.horizontal, 32)
                        .padding(.vertical, 8)
                }
            }
            .buttonStyle(.borderedProminent)
            .focused($focusedField, equals: .connect)
            .disabled(!isFormValid || isTesting)
        }
    }

    private var isFormValid: Bool {
        guard validOctet(octet1), validOctet(octet2), validOctet(octet3), validOctet(octet4) else { return false }
        guard let port = Int(webPort), (1...65535).contains(port) else { return false }
        guard let slim = Int(slimPort), (1...65535).contains(slim) else { return false }
        return true
    }

    private func validOctet(_ s: String) -> Bool {
        guard let v = Int(s) else { return false }
        return (0...255).contains(v)
    }

    private var assembledHost: String {
        "\(octet1).\(octet2).\(octet3).\(octet4)"
    }

    private func prefillIfNeeded() {
        guard !didPrefill else { return }
        didPrefill = true

        if let parts = parseIPv4(settings.serverHost) {
            octet1 = parts.0
            octet2 = parts.1
            octet3 = parts.2
            octet4 = parts.3
        }
        if settings.serverWebPort > 0 {
            webPort = String(settings.serverWebPort)
        }
        if settings.serverSlimProtoPort > 0 {
            slimPort = String(settings.serverSlimProtoPort)
        }
    }

    private func parseIPv4(_ s: String) -> (String, String, String, String)? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        guard parts.allSatisfy(validOctet) else { return nil }
        return (parts[0], parts[1], parts[2], parts[3])
    }

    private func runConnectionTest() {
        guard isFormValid else { return }
        errorMessage = nil
        isTesting = true

        let host = assembledHost
        let port = Int(webPort) ?? 9000
        let slim = Int(slimPort) ?? 3483

        testTask = Task {
            let result = await ServerSetup.test(host: host, port: port, slimPort: slim, settings: settings)

            if Task.isCancelled { return }

            await MainActor.run {
                if Task.isCancelled { return }
                isTesting = false
                testTask = nil
                handleTestResult(result, host: host, port: port, slimPort: slim)
            }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
        os_log(.info, log: logger, "User cancelled connection test")
    }

    private func handleTestResult(_ result: SettingsManager.ConnectionTestResult, host: String, port: Int, slimPort: Int) {
        switch result {
        case .success:
            os_log(.info, log: logger, "Manual entry succeeded for %{public}s:%ld", host, port)
            let login = ServerSetup.savedLogin(for: host, port: port, settings: settings)
            ServerSetup.commit(host: host, port: port, slimPort: slimPort, username: login.username, password: login.password,
                               settings: settings, onComplete: onComplete)

        case _ where ServerSetup.needsSignIn(result):
            os_log(.info, log: logger, "%{public}s:%ld requires sign-in", host, port)
            signInTarget = ServerSignInTarget(host: host, port: port, slimPort: slimPort)

        case .webPortFailure:
            errorMessage = "\(host):\(port) answered, but it doesn't look like LMS."

        case .slimProtoPortFailure:
            errorMessage = "\(host) answered on the web port, but the player port (\(slimPort)) didn't. Make sure LMS is fully running."

        case .networkError, .timeout:
            errorMessage = "Couldn't reach \(host):\(port). Check the address and that LMS is on the same network."

        case .invalidHost(let msg):
            errorMessage = msg
        }
    }
}

#Preview {
    NavigationStack {
        ManualServerEntryView()
    }
}
