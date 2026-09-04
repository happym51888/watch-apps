import Foundation

/// How a track's stable id is derived.
///
/// Every saved place in the library is anchored to a track id, so the id has
/// to mean the same thing after the file has been deleted and copied back,
/// after the library has been rebuilt, and after the user has renamed things.
/// The tempting choices are all wrong in a way that only shows up later:
///
/// * **List position** — "book 3, file 7" moves the moment a forgotten
///   prologue is added, and every bookmark in the book shifts by one file.
/// * **File path** — changes when the container is renamed, and on watchOS the
///   app's data directory path is not stable across reinstalls anyway.
/// * **Title metadata** — absent or duplicated in a large share of real files;
///   LibriVox books routinely ship several sections titled just "Part 2".
///
/// What is left is the bytes. A prefix hash plus the exact byte count
/// identifies a file cheaply — no need to read a 60 MB chapter to name it —
/// and survives everything above. Re-encoding the audio does change the id,
/// which is correct: it is a different file, and `Book.rebase` exists for that
/// case.
public enum TrackIdentity {

    /// Bytes read from the head of the file to form the hash.
    ///
    /// Large enough to cover the ID3 tag and the first audio frames, so two
    /// chapters of the same book differ; small enough to run over a whole
    /// library on a watch without spinning the disk.
    public static let probeLength = 64 * 1024

    /// Derive an id from a file's leading bytes and its total size.
    ///
    /// The size is included separately because a truncated download shares its
    /// prefix with the complete file and must not share its id — that is the
    /// case where a stale bookmark would point past the end of the audio.
    public static func make(prefix: [UInt8], totalBytes: Int64) -> String {
        let digest = fnv1a64(prefix)
        return String(format: "%016llx-%llx", digest, UInt64(bitPattern: totalBytes))
    }

    /// FNV-1a, 64-bit.
    ///
    /// Not a cryptographic hash and not trying to be: nothing here defends
    /// against a chosen collision, it only has to separate the files in one
    /// person's library. CryptoKit would work too but is unavailable on Linux,
    /// where `swift test` runs.
    public static func fnv1a64(_ bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
