import Foundation

/// Joins the per-chunk transcripts back into one.
///
/// Because the windows overlap, consecutive chunks end and begin with the same
/// few seconds of speech. Concatenating them naively repeats a phrase at every
/// seam. Trimming a fixed number of characters instead drops real words,
/// because the recogniser does not produce identical text for the same audio in
/// two different contexts.
///
/// So the seam is found by content: take the tail of what we have so far and
/// the head of the next chunk, and find the longest run of tokens that matches
/// both. That run is the duplicated overlap, and the next chunk contributes
/// only what follows it.
public enum TranscriptStitcher {

    /// Longest token sequence that is both a suffix of `left` and a prefix of
    /// `right`, searched within `maxTokens`.
    ///
    /// Bounded because an unbounded search would happily "find" a spurious
    /// match between two unrelated sentences that happen to share a common
    /// filler word, and delete real content on the strength of it.
    static func overlapLength(
        left: [String],
        right: [String],
        maxTokens: Int
    ) -> Int {
        let limit = min(maxTokens, min(left.count, right.count))
        guard limit > 0 else { return 0 }

        // Longest first: prefer the biggest genuine overlap over a short
        // coincidental one.
        var length = limit
        while length > 0 {
            if Array(left.suffix(length)) == Array(right.prefix(length)) {
                return length
            }
            length -= 1
        }
        return 0
    }

    /// Normalised tokens used only for *matching*. The original text is what
    /// gets emitted, so this never alters the output — it only decides where
    /// the seam is. Case and punctuation differ across chunk boundaries all the
    /// time and must not prevent a match.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
    }

    /// Stitch chunk transcripts in order.
    ///
    /// - Parameter maxOverlapTokens: ceiling on the seam search. Roughly the
    ///   number of words that fit in the plan's overlap window; three words a
    ///   second is fast speech.
    public static func stitch(_ pieces: [String], maxOverlapTokens: Int = 24) -> String {
        let usable = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard var result = usable.first else { return "" }
        var resultTokens = tokens(result)

        for piece in usable.dropFirst() {
            let pieceTokens = tokens(piece)
            let shared = overlapLength(
                left: resultTokens,
                right: pieceTokens,
                maxTokens: maxOverlapTokens
            )

            if shared == 0 {
                // No detectable seam. Keep everything — losing real speech is
                // far worse than an occasional repeated phrase, and the user
                // can see and fix a repetition but cannot recover a deletion.
                result += " " + piece
                resultTokens += pieceTokens
                continue
            }

            // Drop the duplicated tokens from the front of the incoming piece,
            // by walking the original string so the surviving text keeps its
            // original casing and punctuation.
            let remainder = dropLeadingTokens(shared, from: piece)
            if !remainder.isEmpty {
                result += " " + remainder
            }
            resultTokens += Array(pieceTokens.dropFirst(shared))
        }

        return result
    }

    /// Remove the first `count` tokens from `text`, preserving everything else
    /// exactly as written.
    private static func dropLeadingTokens(_ count: Int, from text: String) -> String {
        guard count > 0 else { return text }

        var seen = 0
        var index = text.startIndex
        var insideToken = false

        while index < text.endIndex {
            let character = text[index]
            let isSeparator = character.isWhitespace || character.isPunctuation

            if isSeparator {
                if insideToken {
                    seen += 1
                    insideToken = false
                    if seen == count {
                        // Skip the run of separators that follows, so the join
                        // does not leave a leading space or comma.
                        var after = index
                        while after < text.endIndex,
                              text[after].isWhitespace || text[after].isPunctuation {
                            after = text.index(after: after)
                        }
                        return String(text[after...])
                    }
                }
            } else {
                insideToken = true
            }
            index = text.index(after: index)
        }

        // Reached the end without finding the boundary, which means the whole
        // piece was inside the overlap and contributes nothing new.
        return ""
    }
}
