import SwiftUI

@main
struct VolumenApp: App {
    @State private var library = LibraryStore()
    @State private var player = Player()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(player)
        }
    }
}

/// The shelf.
///
/// Books first, everything else behind them. The realistic use is putting
/// headphones in and tapping the one book you are part way through, so that
/// book is at the top and one tap from playing.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    EmptyShelf(error: library.lastError)
                } else {
                    List {
                        ForEach(library.books) { book in
                            NavigationLink {
                                NowPlayingView(book: book)
                            } label: {
                                BookRow(book: book, place: library.place(in: book))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Volumen")
            .task { await library.rescan() }
        }
    }
}

private struct BookRow: View {
    let book: Book
    let place: Bookmark?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(book.title)
                .font(.headline)
                .lineLimit(2)

            if let place {
                let played = book.absolute(place)
                ProgressView(value: Double(played), total: Double(book.totalMS))
                    .tint(Color.accentColor)
                Text("\(format(book.totalMS - played)) left")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(book.tracks.count) files · \(format(book.totalMS))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EmptyShelf: View {
    let error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "books.vertical")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("No books yet")
                    .font(.headline)
                Text("Send one from Volumen on your iPhone. It keeps your place here even when the phone is at home.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let error {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

/// Milliseconds as a listener reads them: "4:31", "1:12:05".
///
/// Rounds down, deliberately. "1 minute left" that becomes "0 minutes left"
/// while a minute of audio is still playing reads as a bug even though the
/// rounding is defensible.
func format(_ ms: Int64) -> String {
    let total = Int(max(0, ms) / 1000)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
        : String(format: "%d:%02d", minutes, seconds)
}
