import SwiftUI
import os.log

/// A server address that answered with "sign-in required" (HTTP 401).
struct ServerSignInTarget: Hashable, Identifiable {
    let host: String
    let port: Int
    var slimPort: Int = 3483
    var id: String { "\(host):\(port):\(slimPort)" }
}

/// Shared by server discovery, manual entry and sign-in (bd dtz).
enum ServerSetup {
    /// LMS answers 401 on the web port when Settings › Advanced › Security
    /// password protection is on. Same check as iOS onboarding.
    static func needsSignIn(_ result: SettingsManager.ConnectionTestResult) -> Bool {
        if case .webPortFailure(let error) = result { return error.contains("401") }
        return false
    }

    /// The saved login, if it belongs to this host. Lets the user re-pick
    /// their current server without typing the password again.
    static func savedLogin(for host: String, settings: SettingsManager) -> (username: String, password: String) {
        guard host == settings.serverHost, !settings.serverUsername.isEmpty else { return ("", "") }
        return (settings.serverUsername, settings.serverPassword)
    }

    /// Tests `host` with the saved login for it (if any).
    static func test(host: String, port: Int, slimPort: Int = 3483,
                     settings: SettingsManager) async -> SettingsManager.ConnectionTestResult {
        let login = savedLogin(for: host, settings: settings)
        return await settings.testConnection(
            host: host,
            webPort: port,
            slimProtoPort: slimPort,
            webUseHTTPS: false,
            allowSelfSignedCert: false,
            authHeader: SettingsManager.generateAuthHeader(username: login.username, password: login.password)
        )
    }

    /// Saves the server and its login. An empty username means "no login"
    /// and removes a stored one, so a previous server's password never
    /// follows the user to a new server.
    static func commit(host: String, port: Int, slimPort: Int = 3483, username: String, password: String,
                       settings: SettingsManager, onComplete: (() -> Void)?) {
        settings.serverHost = host
        settings.serverWebPort = port
        settings.serverSlimProtoPort = slimPort
        settings.serverUsername = username
        settings.serverPassword = username.isEmpty ? "" : password
        settings.saveSettings()
        if let onComplete {
            onComplete()
        } else {
            settings.markAsConfigured()
        }
    }
}

/// Username + password for an LMS server with password protection on.
/// Pushed by discovery or manual entry when the server answers 401.
struct ServerSignInView: View {
    let target: ServerSignInTarget
    /// See `ServerConnectView.onComplete`.
    var onComplete: (() -> Void)? = nil

    @StateObject private var settings = SettingsManager.shared

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>? = nil
    @State private var errorMessage: String? = nil
    @State private var didPrefill = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case username, password, signIn }

    private let logger = OSLog(subsystem: "com.lmsstream", category: "ServerSignIn")

    var body: some View {
        VStack(spacing: 40) {
            VStack(spacing: 16) {
                Text("Sign in")
                    .font(.largeTitle)
                Text(verbatim: "\(target.host):\(target.port)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("This server has password protection on. Enter the username and password set in LMS Settings › Advanced › Security.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)

            VStack(spacing: 24) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .onSubmit { focusedField = .signIn }

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
                        signIn()
                    } label: {
                        if isTesting {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Signing in…")
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                        } else {
                            Text("Sign In")
                                .padding(.horizontal, 32)
                                .padding(.vertical, 8)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .focused($focusedField, equals: .signIn)
                    .disabled(trimmedUsername.isEmpty || isTesting)
                }

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
        .defaultFocus($focusedField, .username)
    }

    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func prefillIfNeeded() {
        guard !didPrefill else { return }
        didPrefill = true
        // Same server as before: offer the saved username (it was refused
        // or the password changed). Never prefill the password.
        if target.host == settings.serverHost {
            username = settings.serverUsername
        }
        if !username.isEmpty { focusedField = .password }
    }

    private func signIn() {
        let user = trimmedUsername
        guard !user.isEmpty else { return }
        errorMessage = nil
        isTesting = true
        let pass = password

        testTask = Task {
            let result = await settings.testConnection(
                host: target.host,
                webPort: target.port,
                slimProtoPort: target.slimPort,
                webUseHTTPS: false,
                allowSelfSignedCert: false,
                authHeader: SettingsManager.generateAuthHeader(username: user, password: pass)
            )
            if Task.isCancelled { return }

            await MainActor.run {
                if Task.isCancelled { return }
                isTesting = false
                testTask = nil
                handle(result, username: user, password: pass)
            }
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
    }

    private func handle(_ result: SettingsManager.ConnectionTestResult, username: String, password: String) {
        let host = target.host
        switch result {
        case .success:
            os_log(.info, log: logger, "Signed in to %{public}s:%ld as %{public}s", host, target.port, username)
            ServerSetup.commit(host: host, port: target.port, slimPort: target.slimPort,
                               username: username, password: password,
                               settings: settings, onComplete: onComplete)

        case _ where ServerSetup.needsSignIn(result):
            errorMessage = "Wrong username or password."
            focusedField = .password

        case .webPortFailure:
            errorMessage = "\(host):\(target.port) answered, but it doesn't look like LMS."

        case .slimProtoPortFailure:
            errorMessage = "\(host) answered on the web port, but the player port (\(target.slimPort)) didn't. Make sure LMS is fully running."

        case .networkError, .timeout:
            errorMessage = "Couldn't reach \(host):\(target.port). Check that LMS is running."

        case .invalidHost(let msg):
            errorMessage = msg
        }
    }
}

#Preview {
    NavigationStack {
        ServerSignInView(target: ServerSignInTarget(host: "192.168.1.8", port: 9000))
    }
}
