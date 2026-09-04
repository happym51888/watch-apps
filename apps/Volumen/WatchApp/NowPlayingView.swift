import SwiftUI

/// The player screen.
///
/// Designed for a wrist in a coat pocket: the play/pause target is the largest
/// thing on screen, the two skip buttons flank it, and everything else is a
/// scroll or a crown turn away. Nothing here is more than one tap deep,
/// because the realistic interaction is done without looking.
struct NowPlayingView: View {
    let book: Book

    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let notice = player.jumpNotice {
                    JumpNotice(text: notice) { player.dismissNotice() }
                }
                if let failure = player.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                chapterHeading
                transport
                progress
                sleepRow
                chapterList
                disagreementNote
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { player.open(book, in: library) }
    }

    // MARK: - Heading

    @ViewBuilder
    private var chapterHeading: some View {
        if let state = player.state {
            VStack(spacing: 2) {
                Text(state.currentChapter.title.isEmpty
                     ? "Chapter \(state.chapterIndex + 1)"
                     : state.currentChapter.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("\(state.chapterIndex + 1) of \(state.chapters.count) · \(format(state.chapterRemainingMS)) left")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 10) {
            SkipButton(seconds: -30) { player.skip(-30) }

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 62, height: 62)
                    Image(systemName: player.state?.isPlaying == true ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.state?.isPlaying == true ? "Pause" : "Play")

            SkipButton(seconds: 30) { player.skip(30) }
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progress: some View {
        if let state = player.state {
            VStack(spacing: 2) {
                ProgressView(
                    value: Double(state.absoluteMS),
                    total: Double(max(1, book.totalMS))
                )
                .tint(Color.accentColor)

                HStack {
                    Text(format(state.absoluteMS))
                    Spacer()
                    Text("−\(format(state.remainingMS))")
                }
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Sleep timer

    // watchOS has no `Menu` — a pushed screen is the platform's answer, and it
    // is the better one here anyway: picking a sleep timer in the dark is
    // easier against five full-width rows than a popover.
    @ViewBuilder
    private var sleepRow: some View {
        if let state = player.state {
            NavigationLink {
                SleepTimerView()
            } label: {
                Label(
                    state.sleepRemainingMS.map { "Sleep in \(format($0))" } ?? "Sleep timer",
                    systemImage: "moon.zzz"
                )
                .font(.system(size: 11))
            }
        }
    }

    // MARK: - Chapters

    // `DisclosureGroup` is unavailable on watchOS too, and expanding a long
    // chapter list inline would push the transport controls off the screen
    // that exists to hold them.
    @ViewBuilder
    private var chapterList: some View {
        if let state = player.state, state.chapters.count > 1 {
            NavigationLink {
                ChapterListView()
            } label: {
                Label("Chapters", systemImage: "list.bullet")
                    .font(.system(size: 11))
            }
        }
    }

    /// When the publisher's running time disagrees with the files, say so.
    ///
    /// Not a warning about anything the listener did — it is here because a
    /// book that claims 49 hours and contains 55 will otherwise look like the
    /// app is miscounting, and 103 of the 234 books in the reference corpus
    /// disagree with themselves this way.
    @ViewBuilder
    private var disagreementNote: some View {
        let drift = book.declaredDisagreementMS
        if abs(drift) > 60_000 {
            Text("This book lists \(format(book.declaredTotalMS ?? 0)) but the files run \(format(book.totalMS)). Timings follow the files.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Pushed screens

private struct SleepTimerView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    private static let choices: [(String, SleepTimer)] = [
        ("Off", .off),
        ("15 minutes", .after(playingMS: 15 * 60_000)),
        ("30 minutes", .after(playingMS: 30 * 60_000)),
        ("45 minutes", .after(playingMS: 45 * 60_000)),
        ("End of chapter", .endOfChapter),
    ]

    var body: some View {
        List {
            ForEach(Self.choices, id: \.0) { label, timer in
                Button(label) {
                    player.setSleepTimer(timer)
                    dismiss()
                }
            }
        }
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ChapterListView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(Array((player.state?.chapters ?? []).enumerated()), id: \.offset) { index, chapter in
                Button {
                    player.jump(toChapter: index)
                    dismiss()
                } label: {
                    HStack {
                        Text(chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title)
                            .lineLimit(1)
                        Spacer()
                        Text(format(chapter.durationMS))
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .navigationTitle("Chapters")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Pieces

private struct SkipButton: View {
    let seconds: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: seconds < 0 ? "gobackward.30" : "goforward.30")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds < 0 ? "Back 30 seconds" : "Forward 30 seconds")
    }
}

private struct JumpNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                Text(text)
                    .multilineTextAlignment(.leading)
            }
            .font(.system(size: 10))
            .foregroundStyle(.yellow)
            .padding(6)
            .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
