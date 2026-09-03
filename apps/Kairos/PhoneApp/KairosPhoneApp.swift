import SwiftUI
import AVFoundation
import WatchConnectivity

/// The iPhone side exists for exactly two reasons: it has a camera, and the
/// App Store needs somewhere to put the product page. It is deliberately not a
/// second authenticator — it enrols accounts and pushes them to the watch.
@main
struct KairosPhoneApp: App {
    @State private var bridge = PhoneBridge()

    var body: some Scene {
        WindowGroup {
            EnrolmentView()
                .environment(bridge)
        }
    }
}

// MARK: - Bridge

@MainActor
@Observable
final class PhoneBridge: NSObject {

    enum SendState: Equatable {
        case idle
        case queued(String)
        case delivered(String)
        case failed(String)
    }

    private(set) var state: SendState = .idle
    private(set) var isWatchAppInstalled = false

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ account: Account) {
        let uri = OTPAuthURI.render(account)
        let payload = ["accounts": [uri]]
        let session = WCSession.default

        // Queue it unconditionally: this survives the watch being asleep, on a
        // charger, or out of range, which covers most real enrolments.
        session.transferUserInfo(payload)
        state = .queued(account.displayTitle)

        // And if the watch happens to be awake, deliver immediately so the
        // account appears while the user is still looking at the screen.
        guard session.isReachable else { return }
        session.sendMessage(payload) { [weak self] _ in
            Task { @MainActor in self?.state = .delivered(account.displayTitle) }
        } errorHandler: { _ in
            // Not a failure: the queued transfer above still applies.
        }
    }
}

extension PhoneBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let installed = session.isWatchAppInstalled
        Task { @MainActor in self.isWatchAppInstalled = installed }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS: reactivate so a newly paired watch works without a
        // relaunch.
        WCSession.default.activate()
    }
}

// MARK: - Enrolment

struct EnrolmentView: View {
    @Environment(PhoneBridge.self) private var bridge
    @State private var scanned: Account?
    @State private var scanError: String?
    @State private var manualEntry = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScannerView { result in
                    switch result {
                    case .success(let text):
                        do {
                            scanned = try OTPAuthURI.parse(text)
                            scanError = nil
                        } catch {
                            scanError = describe(error)
                        }
                    case .failure(let error):
                        scanError = error.localizedDescription
                    }
                }
                .overlay(alignment: .bottom) {
                    if let scanError {
                        Text(scanError)
                            .font(.footnote)
                            .padding(8)
                            .background(.thinMaterial, in: .rect(cornerRadius: 8))
                            .padding()
                    }
                }

                footer
            }
            .navigationTitle("Add account")
            .sheet(item: $scanned) { account in
                ConfirmSheet(account: account) {
                    bridge.send(account)
                    scanned = nil
                }
            }
            .sheet(isPresented: $manualEntry) {
                ManualEntryView { account in
                    bridge.send(account)
                    manualEntry = false
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            switch bridge.state {
            case .idle:
                Text(bridge.isWatchAppInstalled
                     ? "Point the camera at the QR code your service shows you."
                     : "Install Kairos on your Apple Watch to receive accounts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .queued(let name):
                Label("\(name) queued for your watch", systemImage: "clock.arrow.circlepath")
                    .font(.footnote)
            case .delivered(let name):
                Label("\(name) is on your watch", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            Button("Enter a key manually") { manualEntry = true }
                .font(.footnote)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }

    private func describe(_ error: Error) -> String {
        guard let parseError = error as? OTPAuthURI.ParseError else {
            return "That QR code couldn't be read."
        }
        // Specific messages, because "invalid QR code" tells the user nothing
        // about whether to retry or to go back to the website.
        return switch parseError {
        case .notAnOTPAuthURI:
            "That's a QR code, but not a two-factor setup code."
        case .unsupportedType(let type):
            "Unsupported code type '\(type)'."
        case .missingSecret, .emptySecret:
            "That setup code has no key in it."
        case .invalidSecret:
            "The key in that code isn't valid base32."
        case .invalidDigits(let value):
            "Unsupported code length '\(value)'."
        case .invalidAlgorithm(let value):
            "Unsupported algorithm '\(value)'."
        case .invalidPeriod(let value):
            "Unsupported refresh period '\(value)'."
        case .missingCounter, .invalidCounter:
            "That counter-based code is missing its counter."
        }
    }
}

// MARK: - Confirm

private struct ConfirmSheet: View {
    let account: Account
    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Service", value: account.issuer.isEmpty ? "—" : account.issuer)
                    LabeledContent("Name", value: account.accountName)
                }
                // Shown because a mismatch here is the difference between an
                // account that works and one that produces six wrong digits
                // forever, and it is invisible otherwise.
                Section("Settings from the QR code") {
                    LabeledContent("Algorithm", value: account.algorithm.rawValue)
                    LabeledContent("Digits", value: String(account.digits))
                    switch account.kind {
                    case .totp(let period):
                        LabeledContent("Refreshes", value: "every \(period)s")
                    case .hotp(let counter):
                        LabeledContent("Counter", value: String(counter))
                    }
                }
                Section {
                    Button("Send to Apple Watch", action: onConfirm)
                }
            }
            .navigationTitle("Confirm")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Manual entry

private struct ManualEntryView: View {
    let onSave: (Account) -> Void

    @State private var issuer = ""
    @State private var name = ""
    @State private var secret = ""
    @State private var algorithm = OTPAlgorithm.sha1
    @State private var digits = 6
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Service", text: $issuer)
                    TextField("Name", text: $name)
                }
                Section("Key") {
                    TextField("Base32 key", text: $secret)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Text("Spaces and lower case are fine.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("Advanced") {
                    Picker("Algorithm", selection: $algorithm) {
                        ForEach(OTPAlgorithm.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    Stepper("\(digits) digits", value: $digits, in: 6...8)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                Section {
                    Button("Send to Apple Watch") { save() }
                        .disabled(secret.isEmpty)
                }
            }
            .navigationTitle("Manual entry")
        }
    }

    private func save() {
        do {
            let bytes = try Base32.decode(secret)
            guard !bytes.isEmpty else {
                error = "That key is empty."
                return
            }
            onSave(
                Account(
                    issuer: issuer.trimmingCharacters(in: .whitespaces),
                    accountName: name.trimmingCharacters(in: .whitespaces),
                    secret: bytes,
                    algorithm: algorithm,
                    digits: digits
                )
            )
        } catch Base32.DecodeError.invalidCharacter(let character) {
            error = "'\(character)' isn't part of a base32 key."
        } catch Base32.DecodeError.truncated {
            error = "That key looks cut short — check for a missing character."
        } catch {
            error = "That key isn't valid base32."
        }
    }
}
