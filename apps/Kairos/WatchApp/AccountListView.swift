import SwiftUI
import KairosCore

/// The screen the whole app exists for: raise your wrist, read the code.
///
/// Codes are shown inline rather than behind a tap. Hiding them would be
/// security theatre — the watch is already unlocked and on your wrist, and the
/// competing app's exact complaint is that it makes you reach for the phone.
/// Every extra tap here gives the user their phone back.
struct AccountListView: View {
    @Environment(CodeModel.self) private var model
    @Environment(SyncSession.self) private var sync

    var body: some View {
        NavigationStack {
            Group {
                if let failure = model.loadFailure {
                    ErrorState(message: failure)
                } else if model.accounts.isEmpty {
                    EmptyState(isPhoneReachable: sync.isPhoneReachable)
                } else {
                    accountList
                }
            }
            .navigationTitle("Kairos")
            .onAppear { model.startRefreshing() }
            .onDisappear { model.stopRefreshing() }
        }
    }

    private var accountList: some View {
        List {
            ForEach(model.accounts) { account in
                NavigationLink {
                    CodeDetailView(account: account)
                } label: {
                    AccountRow(account: account)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        model.delete(account)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            NavigationLink {
                AboutView()
            } label: {
                Label("About", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Row

private struct AccountRow: View {
    @Environment(CodeModel.self) private var model
    let account: Account

    var body: some View {
        // TimelineView drives only the ring. The code text comes from the
        // model, which recomputes on step boundaries, so we are not running
        // HMAC once a second per account.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                CountdownRing(
                    fraction: model.fractionRemaining(for: account, at: context.date)
                )
                .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(account.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(Account.group(model.codes[account.id] ?? "······"))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Countdown ring

/// A ring rather than a number, because at a glance "nearly gone" is a shape,
/// not a digit you have to read and compare.
struct CountdownRing: View {
    let fraction: Double

    private var tint: Color {
        // Turning amber under 25% is the signal to wait for the next code
        // instead of starting to type this one.
        fraction < 0.25 ? .orange : .accentColor
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.tertiary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
        }
    }
}

// MARK: - Empty and error states

private struct EmptyState: View {
    let isPhoneReachable: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "lock.rotation")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)

                Text("No accounts yet")
                    .font(.headline)

                Text("Scan a QR code in Kairos on your iPhone. Accounts move to the watch once, then work with the phone off, dead, or in a locker.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if !isPhoneReachable {
                    Label("iPhone not reachable", systemImage: "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct ErrorState: View {
    let message: String

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Keychain unavailable")
                    .font(.headline)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("Your accounts are still there. This is a read problem, not a loss.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
