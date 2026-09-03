import SwiftUI
import WatchKit

/// One account, filling the screen.
///
/// The feature worth pointing at is the next-code preview. Typing a six-digit
/// code off a watch takes most people four to six seconds; starting one with
/// three seconds left means it is rejected and you have no idea why. When the
/// current code is nearly dead, Kairos shows the upcoming one dimmed, so you
/// can simply wait or type ahead.
struct CodeDetailView: View {
    @Environment(CodeModel.self) private var model
    let account: Account

    private let hmac = CryptoKitHMAC()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = model.secondsRemaining(for: account, at: context.date)
            let fraction = model.fractionRemaining(for: account, at: context.date)

            ScrollView {
                VStack(spacing: 6) {
                    header

                    Text(Account.group(model.codes[account.id] ?? "······"))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.codes[account.id])

                    switch account.kind {
                    case .totp:
                        totpFooter(remaining: remaining, fraction: fraction, at: context.date)
                    case .hotp(let counter):
                        hotpFooter(counter: counter)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .navigationTitle(account.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.startRefreshing() }
    }

    private var header: some View {
        Group {
            if let subtitle = account.displaySubtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder
    private func totpFooter(remaining: Int, fraction: Double, at date: Date) -> some View {
        HStack(spacing: 6) {
            CountdownRing(fraction: fraction)
                .frame(width: 14, height: 14)
            Text("\(remaining)s")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(remaining <= 7 ? .orange : .secondary)
        }

        // Only appears in the last few seconds, where it is the difference
        // between a successful login and a mystifying rejection.
        if remaining <= 7 {
            VStack(spacing: 1) {
                Text("NEXT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(Account.group(nextCode(after: date)))
                    .font(.system(.title3, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func hotpFooter(counter: UInt64) -> some View {
        VStack(spacing: 4) {
            Text("Counter \(counter)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                // Haptic confirmation matters here: burning a counter is
                // destructive in a way a time-based code never is.
                WKInterfaceDevice.current().play(.success)
                model.advance(account)
            } label: {
                Label("Next code", systemImage: "arrow.forward.circle")
            }
            .buttonStyle(.bordered)

            Text("Each tap uses up a code. Only tap if the last one didn't work.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    /// The code for the step after the one currently displayed.
    private func nextCode(after date: Date) -> String {
        guard case .totp(let period) = account.kind else { return "" }
        let next = date.addingTimeInterval(OTP.secondsRemaining(at: date, period: period) + 0.5)
        return account.code(at: next, hmac: hmac)
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Kairos")
                    .font(.headline)

                Text("Codes are generated on this watch. Your iPhone does not need to be nearby, unlocked, charged, or even switched on.")
                    .font(.caption2)

                Divider()

                Label("Secrets stay on this watch", systemImage: "lock.shield")
                    .font(.caption2)
                Text("Stored in the keychain as device-only, so they are never copied to iCloud and never included in a backup. Removing the app removes them.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Divider()

                Label("Clock accuracy", systemImage: "clock.badge.checkmark")
                    .font(.caption2)
                Text("Codes tolerate about 30 seconds of clock drift, and up to a minute depending on timing. If codes are rejected everywhere at once, the watch clock is the first thing to check.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Divider()

                Label("No code on the watch face", systemImage: "eye.slash")
                    .font(.caption2)
                Text("The complication opens Kairos rather than showing a code, so a glance over your shoulder does not hand someone a working second factor.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
