import Foundation

/// The tag is not shaped the way the specification says.
public struct ID3Error: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// An ID3v2 chapter reader.
///
/// AVFoundation exposes chapter metadata on Apple's own terms, and on watchOS
/// it will not read CHAP frames out of an arbitrary MP3 at all. Books that
/// ship their chapter list inside the tag — which is most DRM-free M4B and a
/// good share of MP3 — therefore need this.
///
/// Written from the ID3v2.3.0 informal standard (§3.1 tag header, §3.3
/// frames), the ID3v2.4.0 structure document (§4 frames, which changed how
/// frame sizes are encoded), and the ID3v2 Chapter Frame Addendum 1.0.
///
/// Mirrors `validation/id3_chapters.py`, which `validation/verify_id3.py`
/// checks against mutagen in both directions: bytes written there are read by
/// mutagen, and bytes written by mutagen are read there. Two independent
/// parsers agreeing on the same bytes is the closest thing to a test vector
/// this format offers.
public enum ID3 {

    public static let notSet: UInt32 = 0xFFFF_FFFF

    public struct ChapterFrame: Sendable, Equatable {
        public let elementID: String
        public let startMS: UInt32
        public let endMS: UInt32
        public let startOffset: UInt32?
        public let endOffset: UInt32?
        public let title: String
    }

    public struct TableOfContents: Sendable, Equatable {
        public let elementID: String
        public let topLevel: Bool
        public let ordered: Bool
        public let children: [String]
        public let title: String
    }

    public struct Tag: Sendable, Equatable {
        public let major: UInt8
        public let revision: UInt8
        public let chapters: [ChapterFrame]
        public let toc: [TableOfContents]
        public let title: String
    }

    // MARK: - Integers

    /// Seven bits per byte, high bit always clear.
    ///
    /// The tag header size is encoded this way in every version, so that a
    /// decoder scanning for an MPEG frame sync never mistakes a size byte for
    /// one. (Hazard T2.)
    public static func syncsafeToInt(_ data: ArraySlice<UInt8>) throws -> UInt32 {
        guard data.count == 4 else {
            throw ID3Error("syncsafe integers are four bytes, got \(data.count)")
        }
        var value: UInt32 = 0
        for byte in data {
            guard byte & 0x80 == 0 else {
                throw ID3Error("syncsafe byte has its high bit set")
            }
            value = (value << 7) | UInt32(byte)
        }
        return value
    }

    public static func intToSyncsafe(_ value: UInt32) throws -> [UInt8] {
        guard value < (1 << 28) else {
            throw ID3Error("\(value) does not fit a syncsafe integer")
        }
        return [21, 14, 7, 0].map { UInt8((value >> UInt32($0)) & 0x7F) }
    }

    public static func plainToInt(_ data: ArraySlice<UInt8>) throws -> UInt32 {
        guard data.count == 4 else {
            throw ID3Error("plain integers are four bytes, got \(data.count)")
        }
        return data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// Insert `$00` after every `$FF` that would otherwise look like a frame
    /// sync.
    public static func unsynchronise(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for byte in data {
            out.append(byte)
            if byte == 0xFF { out.append(0x00) }
        }
        return out
    }

    /// Undo it.
    ///
    /// Leaving it done puts stray nulls inside titles and shifts every
    /// subsequent field by however many `$FF` bytes preceded it. (Hazard T5.)
    public static func deUnsynchronise(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var skip = false
        for (index, byte) in data.enumerated() {
            if skip { skip = false; continue }
            out.append(byte)
            if byte == 0xFF, index + 1 < data.count, data[index + 1] == 0x00 {
                skip = true
            }
        }
        return out
    }

    // MARK: - Text

    /// Decode an ID3 text frame body: one encoding byte, then the string.
    ///
    /// The encoding byte is not advisory. Latin-1 and UTF-8 terminate on a
    /// single null; the two UTF-16 forms terminate on two. A parser that
    /// assumes single-null termination truncates every UTF-16 title to its
    /// first letter, because ASCII in UTF-16LE is letter-then-null: "Chapter
    /// 1" becomes "C". (Hazards T3 and T4.)
    public static func decodeText(_ payload: ArraySlice<UInt8>) -> String {
        guard let marker = payload.first else { return "" }
        var body = Array(payload.dropFirst())

        func truncate(atDoubleNull: Bool) {
            if atDoubleNull {
                // Trim to an even length first, or a trailing stray byte
                // shifts the two-byte search by one.
                if body.count % 2 == 1 { body.removeLast() }
                var index = 0
                while index + 1 < body.count {
                    if body[index] == 0 && body[index + 1] == 0 {
                        body = Array(body[..<index])
                        return
                    }
                    index += 2
                }
            } else if let index = body.firstIndex(of: 0) {
                body = Array(body[..<index])
            }
        }

        switch marker {
        case 0x00:
            truncate(atDoubleNull: false)
            return String(body.map { Character(UnicodeScalar($0)) })
        case 0x01:
            truncate(atDoubleNull: true)
            return decodeUTF16(body, bigEndian: nil)
        case 0x02:
            truncate(atDoubleNull: true)
            return decodeUTF16(body, bigEndian: true)
        case 0x03:
            truncate(atDoubleNull: false)
            return String(decoding: body, as: UTF8.self)
        default:
            // Some writers omit the encoding byte entirely. A printable first
            // byte cannot be one of the four markers, so treating the whole
            // payload as Latin-1 recovers those without corrupting valid
            // frames.
            var all = Array(payload)
            if let index = all.firstIndex(of: 0) { all = Array(all[..<index]) }
            return String(all.map { Character(UnicodeScalar($0)) })
        }
    }

    /// `bigEndian: nil` means "look for a byte order mark", which is what
    /// encoding `$01` promises and encoding `$02` forbids.
    private static func decodeUTF16(_ body: [UInt8], bigEndian: Bool?) -> String {
        var bytes = body
        var isBigEndian = bigEndian ?? true
        if bigEndian == nil, bytes.count >= 2 {
            if bytes[0] == 0xFF && bytes[1] == 0xFE {
                isBigEndian = false
                bytes.removeFirst(2)
            } else if bytes[0] == 0xFE && bytes[1] == 0xFF {
                isBigEndian = true
                bytes.removeFirst(2)
            }
        }
        if bytes.count % 2 == 1 { bytes.removeLast() }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let high = UInt16(bytes[index])
            let low = UInt16(bytes[index + 1])
            units.append(isBigEndian ? (high << 8) | low : (low << 8) | high)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Element ids are Latin-1 and null terminated, whatever the text frames
    /// alongside them use.
    static func readLatin1Terminated(
        _ data: ArraySlice<UInt8>,
        from start: Int
    ) throws -> (String, Int) {
        guard let end = data[start...].firstIndex(of: 0) else {
            throw ID3Error("unterminated element id")
        }
        let text = String(data[start..<end].map { Character(UnicodeScalar($0)) })
        return (text, end + 1)
    }

    // MARK: - Frames

    /// The one difference between v2.3 and v2.4 that silently corrupts.
    ///
    /// v2.3 sizes are a plain 32-bit big-endian count; v2.4 made them
    /// syncsafe. Apply the wrong rule and every frame at or past 128 bytes
    /// lands at the wrong offset — under 128 the two encodings agree exactly,
    /// which is why this survives casual testing and fails on a real book.
    /// (Hazard T1.)
    static func frameSize(_ raw: ArraySlice<UInt8>, major: UInt8) throws -> UInt32 {
        major >= 4 ? try syncsafeToInt(raw) : try plainToInt(raw)
    }

    /// Walk frames in order, stopping at padding.
    static func walkFrames(
        _ body: ArraySlice<UInt8>,
        major: UInt8,
        _ visit: (String, ArraySlice<UInt8>) throws -> Void
    ) throws {
        let base = body.startIndex
        var pos = base
        let headerLength = major == 2 ? 6 : 10
        while pos + headerLength <= body.endIndex {
            let frameID: String
            let size: UInt32
            let payloadAt: Int
            if major == 2 {
                frameID = String(body[pos..<(pos + 3)].map { Character(UnicodeScalar($0)) })
                if body[pos] == 0 { return }
                size = UInt32(body[pos + 3]) << 16 | UInt32(body[pos + 4]) << 8 | UInt32(body[pos + 5])
                payloadAt = pos + 6
            } else {
                if body[pos] == 0 { return }  // padding
                frameID = String(body[pos..<(pos + 4)].map { Character(UnicodeScalar($0)) })
                size = try frameSize(body[(pos + 4)..<(pos + 8)], major: major)
                payloadAt = pos + 10
            }
            guard payloadAt + Int(size) <= body.endIndex else {
                throw ID3Error(
                    "frame \(frameID) claims \(size) bytes but only "
                        + "\(body.endIndex - payloadAt) remain; wrong size encoding for v2.\(major)?"
                )
            }
            try visit(frameID, body[payloadAt..<(payloadAt + Int(size))])
            pos = payloadAt + Int(size)
        }
    }

    private static func isTitleFrame(_ id: String) -> Bool {
        id == "TIT2" || id == "TT2"
    }

    static func parseCHAP(_ payload: ArraySlice<UInt8>, major: UInt8) throws -> ChapterFrame {
        let (elementID, afterID) = try readLatin1Terminated(payload, from: payload.startIndex)
        guard afterID + 16 <= payload.endIndex else {
            throw ID3Error("CHAP \(elementID) is too short for its four times")
        }
        func word(_ at: Int) -> UInt32 {
            payload[at..<(at + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        let startMS = word(afterID)
        let endMS = word(afterID + 4)
        let startOffset = word(afterID + 8)
        let endOffset = word(afterID + 12)

        var title = ""
        // Subframes use the same size rule as the frame containing them, not
        // a fresh guess. (Hazard T7.)
        try walkFrames(payload[(afterID + 16)...], major: major) { id, sub in
            if isTitleFrame(id) && title.isEmpty { title = decodeText(sub) }
        }
        return ChapterFrame(
            elementID: elementID,
            startMS: startMS,
            endMS: endMS,
            // `$FFFFFFFF` means "not set". Treating it as a real offset is a
            // four-billion-byte seek. (Hazard T6.)
            startOffset: startOffset == notSet ? nil : startOffset,
            endOffset: endOffset == notSet ? nil : endOffset,
            title: title
        )
    }

    static func parseCTOC(_ payload: ArraySlice<UInt8>, major: UInt8) throws -> TableOfContents {
        let (elementID, afterID) = try readLatin1Terminated(payload, from: payload.startIndex)
        var pos = afterID
        guard pos + 2 <= payload.endIndex else {
            throw ID3Error("CTOC \(elementID) is too short for flags and count")
        }
        let flags = payload[pos]
        let count = payload[pos + 1]
        pos += 2
        var children: [String] = []
        for _ in 0..<count {
            let (child, next) = try readLatin1Terminated(payload, from: pos)
            children.append(child)
            pos = next
        }
        var title = ""
        try walkFrames(payload[pos...], major: major) { id, sub in
            if isTitleFrame(id) && title.isEmpty { title = decodeText(sub) }
        }
        return TableOfContents(
            elementID: elementID,
            topLevel: flags & 0x02 != 0,
            ordered: flags & 0x01 != 0,
            children: children,
            title: title
        )
    }

    /// Read an ID3v2 tag from the start of a file.
    public static func parseTag(_ data: [UInt8]) throws -> Tag {
        guard data.count >= 10, data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else {
            throw ID3Error("no ID3v2 tag at the start of the data")
        }
        let major = data[3]
        let revision = data[4]
        guard (2...4).contains(major) else {
            throw ID3Error("unsupported ID3v2 major version \(major)")
        }
        let flags = data[5]
        let size = try syncsafeToInt(data[6..<10])  // always syncsafe (T2)
        guard data.count >= 10 + Int(size) else {
            throw ID3Error("tag claims \(size) bytes, only \(data.count - 10) present")
        }
        var body = Array(data[10..<(10 + Int(size))])

        if flags & 0x80 != 0 {  // unsynchronisation, whole tag
            body = deUnsynchronise(body)
        }
        if flags & 0x40 != 0 {  // extended header
            if major >= 4 {
                let ext = try syncsafeToInt(body[0..<4])
                body = Array(body.dropFirst(Int(ext)))
            } else {
                let ext = try plainToInt(body[0..<4])
                body = Array(body.dropFirst(4 + Int(ext)))
            }
        }

        var chapters: [ChapterFrame] = []
        var toc: [TableOfContents] = []
        var title = ""
        try walkFrames(body[...], major: major) { id, payload in
            switch id {
            case "CHAP": chapters.append(try parseCHAP(payload, major: major))
            case "CTOC": toc.append(try parseCTOC(payload, major: major))
            default:
                if isTitleFrame(id) && title.isEmpty { title = decodeText(payload) }
            }
        }
        return Tag(major: major, revision: revision, chapters: chapters, toc: toc, title: title)
    }

    /// Chapters in playing order.
    ///
    /// An ordered top-level CTOC states the order. Without one, the order the
    /// CHAP frames appear in is the only signal available — sorting by start
    /// time looks tidier and is wrong for books whose chapters were written
    /// out of order, which is exactly the case a CTOC exists to describe.
    public static func orderedChapters(_ tag: Tag) -> [ChapterFrame] {
        guard let top = tag.toc.first(where: { $0.topLevel && $0.ordered }) else {
            return tag.chapters
        }
        var byID: [String: ChapterFrame] = [:]
        for chapter in tag.chapters { byID[chapter.elementID] = chapter }
        var out = top.children.compactMap { byID[$0] }
        let named = Set(top.children)
        out.append(contentsOf: tag.chapters.filter { !named.contains($0.elementID) })
        return out
    }
}
