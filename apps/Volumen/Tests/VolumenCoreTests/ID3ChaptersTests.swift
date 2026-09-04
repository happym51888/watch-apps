import Foundation
import XCTest
@testable import VolumenCore

/// ID3 chapter frames, and the four or five ways to read them slightly wrong.
///
/// Every case here has a counterpart in `validation/verify_id3.py`, which
/// checks the same bytes against mutagen in both directions. This suite exists
/// so the Swift port cannot drift away from the Python one that was checked.
final class ID3ChaptersTests: XCTestCase {

    // MARK: - Builders
    //
    // Writing tags rather than committing binary fixtures: the size encoding
    // is the thing under test, so the test has to be able to produce both
    // versions of it on demand.

    private func syncsafe(_ value: UInt32) -> [UInt8] {
        [21, 14, 7, 0].map { UInt8((value >> UInt32($0)) & 0x7F) }
    }

    private func plain(_ value: UInt32) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    }

    private func frameSizeBytes(_ length: Int, major: UInt8) -> [UInt8] {
        major >= 4 ? syncsafe(UInt32(length)) : plain(UInt32(length))
    }

    private func encodeText(_ text: String, marker: UInt8) -> [UInt8] {
        switch marker {
        case 0x00: return [marker] + Array(text.unicodeScalars.map { UInt8($0.value & 0xFF) }) + [0]
        case 0x01:
            var out: [UInt8] = [marker, 0xFF, 0xFE]  // UTF-16LE with BOM
            for unit in Array(text.utf16) {
                out.append(UInt8(unit & 0xFF))
                out.append(UInt8(unit >> 8))
            }
            return out + [0, 0]
        case 0x02:
            var out: [UInt8] = [marker]
            for unit in Array(text.utf16) {
                out.append(UInt8(unit >> 8))
                out.append(UInt8(unit & 0xFF))
            }
            return out + [0, 0]
        default: return [0x03] + Array(text.utf8) + [0]
        }
    }

    private func buildCHAP(
        elementID: String,
        startMS: UInt32,
        endMS: UInt32,
        title: String?,
        startOffset: UInt32 = ID3.notSet,
        endOffset: UInt32 = ID3.notSet,
        major: UInt8 = 4,
        textMarker: UInt8 = 0x03
    ) -> [UInt8] {
        var payload = Array(elementID.utf8) + [0]
        payload += plain(startMS) + plain(endMS) + plain(startOffset) + plain(endOffset)
        if let title {
            let sub = encodeText(title, marker: textMarker)
            payload += Array("TIT2".utf8) + frameSizeBytes(sub.count, major: major) + [0, 0] + sub
        }
        return payload
    }

    private func buildCTOC(
        elementID: String,
        children: [String],
        topLevel: Bool = true,
        ordered: Bool = true,
        major: UInt8 = 4
    ) -> [UInt8] {
        var payload = Array(elementID.utf8) + [0]
        payload.append((topLevel ? 0x02 : 0) | (ordered ? 0x01 : 0))
        payload.append(UInt8(children.count))
        for child in children { payload += Array(child.utf8) + [0] }
        return payload
    }

    private func buildTag(
        _ frames: [(String, [UInt8])],
        major: UInt8 = 4,
        flags: UInt8 = 0,
        padding: Int = 0
    ) -> [UInt8] {
        var body: [UInt8] = []
        for (id, payload) in frames {
            body += Array(id.utf8) + frameSizeBytes(payload.count, major: major) + [0, 0] + payload
        }
        body += [UInt8](repeating: 0, count: padding)
        if flags & 0x80 != 0 { body = ID3.unsynchronise(body) }
        return Array("ID3".utf8) + [major, 0, flags] + syncsafe(UInt32(body.count)) + body
    }

    // MARK: - T1, the size encoding

    func testSyncsafeAndPlainAgreeOnlyBelow128() throws {
        for value: UInt32 in [0, 1, 127] {
            XCTAssertEqual(try ID3.syncsafeToInt(syncsafe(value)[...]), value)
            XCTAssertEqual(try ID3.plainToInt(plain(value)[...]), value)
            XCTAssertEqual(syncsafe(value), plain(value), "identical below 128")
        }
        // At 128 the encodings diverge, and stay diverged. This is the exact
        // point where a version-blind parser starts landing on the wrong byte.
        XCTAssertNotEqual(syncsafe(128), plain(128))
        XCTAssertEqual(syncsafe(128), [0x00, 0x00, 0x01, 0x00])
        XCTAssertEqual(plain(128), [0x00, 0x00, 0x00, 0x80])

        // Reading a plain 128 as syncsafe is not merely wrong, it is invalid:
        // the high bit is set, which a syncsafe byte may never have.
        XCTAssertThrowsError(try ID3.syncsafeToInt(plain(128)[...]))
        XCTAssertThrowsError(try ID3.intToSyncsafe(1 << 28))
    }

    func testALongChapterIsReadCorrectlyInBothVersions() throws {
        // The title has to push the frame past 128 bytes, or both size rules
        // give the same answer and the test proves nothing.
        let longTitle = String(repeating: "Chapter the first, in which nothing happens. ", count: 4)
        XCTAssertGreaterThan(longTitle.utf8.count, 128)

        for major: UInt8 in [3, 4] {
            let chap = buildCHAP(
                elementID: "ch0",
                startMS: 1_000,
                endMS: 2_000,
                title: longTitle,
                major: major
            )
            let tag = try ID3.parseTag(buildTag([("CHAP", chap)], major: major))
            XCTAssertEqual(tag.major, major)
            XCTAssertEqual(tag.chapters.count, 1, "v2.\(major)")
            XCTAssertEqual(tag.chapters[0].startMS, 1_000)
            XCTAssertEqual(tag.chapters[0].title, longTitle, "v2.\(major)")
        }
    }

    func testTheWrongVersionIsRefusedRatherThanGuessedAt() {
        let longTitle = String(repeating: "x", count: 200)
        // Bytes written as v2.3 but labelled v2.4, and the reverse. Neither
        // may quietly return a half-read chapter list.
        for (writtenAs, labelledAs) in [(UInt8(3), UInt8(4)), (UInt8(4), UInt8(3))] {
            var bytes = buildTag(
                [("CHAP", buildCHAP(
                    elementID: "ch0", startMS: 0, endMS: 1, title: longTitle, major: writtenAs
                ))],
                major: writtenAs
            )
            bytes[3] = labelledAs
            XCTAssertThrowsError(
                try ID3.parseTag(bytes),
                "v2.\(writtenAs) bytes read as v2.\(labelledAs) should be refused"
            )
        }
    }

    // MARK: - T2, the header size

    func testTheHeaderSizeIsSyncsafeInBothVersions() throws {
        for major: UInt8 in [3, 4] {
            let bytes = buildTag(
                [("CHAP", buildCHAP(elementID: "c", startMS: 5, endMS: 6, title: "t", major: major))],
                major: major,
                padding: 300
            )
            // If the header size were read as plain, the padding would be
            // mis-measured and the body would be truncated or overrun.
            let tag = try ID3.parseTag(bytes)
            XCTAssertEqual(tag.chapters.count, 1, "v2.\(major)")
        }
    }

    // MARK: - T3 and T4, text encodings

    func testEveryEncodingMarkerRoundTrips() {
        for marker: UInt8 in [0x00, 0x01, 0x02, 0x03] {
            let text = marker == 0x00 ? "Chapter 1" : "Chapter 1 鈥?脺nicode"
            let encoded = encodeText(text, marker: marker)
            XCTAssertEqual(ID3.decodeText(encoded[...]), text, "marker \(marker)")
        }
    }

    func testUTF16ReadAsLatin1LosesTheTitle() {
        // The failure this guards against: ASCII in UTF-16LE is letter, null,
        // letter, null. A parser that stops at the first null keeps one
        // character. Decoding the same bytes correctly must not.
        let utf16 = encodeText("Chapter 1", marker: 0x01)
        XCTAssertEqual(ID3.decodeText(utf16[...]), "Chapter 1")

        // Mislabel the same bytes as Latin-1 and watch it truncate 鈥?this is
        // what a parser ignoring the marker byte would produce.
        var mislabelled = utf16
        mislabelled[0] = 0x00
        let wrong = ID3.decodeText(mislabelled[...])
        XCTAssertNotEqual(wrong, "Chapter 1")
        XCTAssertFalse(wrong.contains("hapter"))
    }

    func testUTF16WithAndWithoutAByteOrderMark() {
        // Marker 0x01 carries a BOM; 0x02 is big-endian with none. Guessing
        // wrong swaps every character into the CJK range rather than failing.
        XCTAssertEqual(ID3.decodeText(encodeText("AB", marker: 0x01)[...]), "AB")
        XCTAssertEqual(ID3.decodeText(encodeText("AB", marker: 0x02)[...]), "AB")

        // A big-endian BOM under marker 0x01 must also work.
        let beWithBOM: [UInt8] = [0x01, 0xFE, 0xFF, 0x00, 0x41, 0x00, 0x42, 0x00, 0x00]
        XCTAssertEqual(ID3.decodeText(beWithBOM[...]), "AB")
    }

    func testAnAbsentEncodingByteFallsBackToLatin1() {
        // Some writers omit the marker. A printable first byte cannot be one
        // of the four markers, so this is recoverable without risk.
        let noMarker = Array("Prologue".utf8) + [0]
        XCTAssertEqual(ID3.decodeText(noMarker[...]), "Prologue")
    }

    // MARK: - T5, unsynchronisation

    func testUnsynchronisationRoundTripsAndIsUndoneWhenFlagged() throws {
        let awkward: [UInt8] = [0x00, 0xFF, 0x00, 0xFF, 0xFB, 0xFF]
        XCTAssertEqual(ID3.deUnsynchronise(ID3.unsynchronise(awkward)), awkward)

        // A start time of 0xFF00FF00 forces $FF bytes into the times, which is
        // where a missed de-unsynchronisation shifts every later field.
        let chap = buildCHAP(elementID: "c", startMS: 0xFF00_FF00, endMS: 0xFFFF_0000, title: "T")
        let tag = try ID3.parseTag(buildTag([("CHAP", chap)], flags: 0x80))
        XCTAssertEqual(tag.chapters[0].startMS, 0xFF00_FF00)
        XCTAssertEqual(tag.chapters[0].endMS, 0xFFFF_0000)
        XCTAssertEqual(tag.chapters[0].title, "T")
    }

    // MARK: - T6, offsets that are not offsets

    func testTheNotSetOffsetIsNotAFourBillionByteSeek() throws {
        let unset = buildCHAP(elementID: "c", startMS: 0, endMS: 1_000, title: nil)
        XCTAssertNil(try ID3.parseTag(buildTag([("CHAP", unset)])).chapters[0].startOffset)

        let real = buildCHAP(
            elementID: "c", startMS: 0, endMS: 1_000, title: nil,
            startOffset: 4_096, endOffset: 8_192
        )
        let parsed = try ID3.parseTag(buildTag([("CHAP", real)])).chapters[0]
        XCTAssertEqual(parsed.startOffset, 4_096)
        XCTAssertEqual(parsed.endOffset, 8_192)
    }

    // MARK: - T7 and ordering

    func testAnOrderedTableOfContentsDecidesPlayingOrder() throws {
        // CHAP frames written out of order, with a CTOC that states the real
        // one. Sorting by start time would look tidier and be wrong.
        let frames: [(String, [UInt8])] = [
            ("CTOC", buildCTOC(elementID: "toc", children: ["c2", "c1"])),
            ("CHAP", buildCHAP(elementID: "c1", startMS: 0, endMS: 1_000, title: "First")),
            ("CHAP", buildCHAP(elementID: "c2", startMS: 1_000, endMS: 2_000, title: "Second"))
        ]
        let tag = try ID3.parseTag(buildTag(frames))
        XCTAssertEqual(tag.toc.count, 1)
        XCTAssertTrue(tag.toc[0].topLevel)
        XCTAssertEqual(ID3.orderedChapters(tag).map(\.elementID), ["c2", "c1"])
    }

    func testChaptersMissingFromTheTableOfContentsAreStillPlayable() throws {
        let frames: [(String, [UInt8])] = [
            ("CTOC", buildCTOC(elementID: "toc", children: ["c1"])),
            ("CHAP", buildCHAP(elementID: "c1", startMS: 0, endMS: 1_000, title: "First")),
            ("CHAP", buildCHAP(elementID: "orphan", startMS: 1_000, endMS: 2_000, title: "Lost"))
        ]
        let tag = try ID3.parseTag(buildTag(frames))
        XCTAssertEqual(ID3.orderedChapters(tag).map(\.elementID), ["c1", "orphan"])
    }

    func testAnUnorderedTableOfContentsDoesNotReorderAnything() throws {
        let frames: [(String, [UInt8])] = [
            ("CTOC", buildCTOC(elementID: "toc", children: ["c2", "c1"], ordered: false)),
            ("CHAP", buildCHAP(elementID: "c1", startMS: 0, endMS: 1_000, title: "First")),
            ("CHAP", buildCHAP(elementID: "c2", startMS: 1_000, endMS: 2_000, title: "Second"))
        ]
        let tag = try ID3.parseTag(buildTag(frames))
        XCTAssertEqual(ID3.orderedChapters(tag).map(\.elementID), ["c1", "c2"])
    }

    // MARK: - Malformed input

    func testMalformedTagsAreRefusedRatherThanGuessedAt() {
        XCTAssertThrowsError(try ID3.parseTag([]))
        XCTAssertThrowsError(try ID3.parseTag(Array("NOTATAG___".utf8)))

        var wrongVersion = buildTag([])
        wrongVersion[3] = 9
        XCTAssertThrowsError(try ID3.parseTag(wrongVersion))

        // A CHAP too short to hold its four times.
        let stunted: [UInt8] = Array("c".utf8) + [0, 0, 0, 0]
        XCTAssertThrowsError(try ID3.parseTag(buildTag([("CHAP", stunted)])))

        // A tag header claiming more body than is present.
        var truncated = buildTag([("CHAP", buildCHAP(
            elementID: "c", startMS: 0, endMS: 1, title: "t"
        ))])
        truncated.removeLast(5)
        XCTAssertThrowsError(try ID3.parseTag(truncated))
    }

    func testPaddingEndsTheFrameWalkInsteadOfBeingParsed() throws {
        let tag = try ID3.parseTag(
            buildTag(
                [("CHAP", buildCHAP(elementID: "c", startMS: 0, endMS: 1, title: "t"))],
                padding: 2_048
            )
        )
        XCTAssertEqual(tag.chapters.count, 1)
    }
}
