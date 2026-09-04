import Foundation
import Compression

/// A read-only ZIP reader, enough for a GTFS feed.
///
/// Foundation has no public zip API on iOS, and a GTFS feed is always a zip.
/// This reads the central directory rather than scanning for local headers,
/// which is the difference between working and appearing to work:
///
///   * A local header may carry zero for the sizes and a CRC, with the real
///     values in a data descriptor *after* the compressed bytes. Trusting the
///     local header there reads zero bytes and yields an empty file, silently.
///   * The central directory is the authoritative index. It is also where the
///     archive says how many entries it has, so a truncated download is
///     detectable instead of just short.
///
/// Only the two compression methods GTFS publishers actually use are
/// supported: stored, and deflate.
enum ZipReader {

    struct Entry {
        let name: String
        let compressedRange: Range<Int>
        let method: UInt16
        let uncompressedSize: Int
        let crc32: UInt32
    }

    enum ZipError: LocalizedError {
        case notAZip
        case truncated(String)
        case unsupportedMethod(UInt16, String)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .notAZip:
                return "That file is not a zip archive."
            case .truncated(let detail):
                return "The archive is incomplete (\(detail)). Try downloading it again."
            case .unsupportedMethod(let method, let name):
                return "\(name) uses compression method \(method), which this app cannot read."
            case .checksumMismatch(let name):
                return "\(name) failed its checksum. The download is corrupt."
            }
        }
    }

    /// Read every entry's name and location from the central directory.
    static func index(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count > 22 else { throw ZipError.notAZip }

        // The end-of-central-directory record is last, but may be followed by
        // up to 64 KB of comment, so it has to be searched for backwards.
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        var eocd = -1
        var index = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65_535)
        while index >= floor {
            if Array(bytes[index..<(index + 4)]) == signature { eocd = index; break }
            index -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let expectedCount = Int(u16(bytes, eocd + 10))
        let directorySize = Int(u32(bytes, eocd + 12))
        let directoryStart = Int(u32(bytes, eocd + 16))
        guard directoryStart >= 0, directoryStart + directorySize <= bytes.count else {
            throw ZipError.truncated("central directory runs past the end of the file")
        }

        var entries: [Entry] = []
        var cursor = directoryStart
        while cursor + 46 <= directoryStart + directorySize {
            guard u32(bytes, cursor) == 0x0201_4B50 else { break }
            let method = u16(bytes, cursor + 10)
            let crc = u32(bytes, cursor + 16)
            let compressedSize = Int(u32(bytes, cursor + 20))
            let uncompressedSize = Int(u32(bytes, cursor + 24))
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let localOffset = Int(u32(bytes, cursor + 42))

            let name = String(
                decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self
            )

            // The local header's own name and extra lengths decide where the
            // data starts; they are allowed to differ from the ones here.
            guard localOffset + 30 <= bytes.count, u32(bytes, localOffset) == 0x0403_4B50 else {
                throw ZipError.truncated("local header for \(name)")
            }
            let localNameLength = Int(u16(bytes, localOffset + 26))
            let localExtraLength = Int(u16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= bytes.count else {
                throw ZipError.truncated(name)
            }

            entries.append(
                Entry(
                    name: name,
                    compressedRange: dataStart..<(dataStart + compressedSize),
                    method: method,
                    uncompressedSize: uncompressedSize,
                    crc32: crc
                )
            )
            cursor += 46 + nameLength + extraLength + commentLength
        }

        guard entries.count == expectedCount else {
            throw ZipError.truncated("\(entries.count) of \(expectedCount) entries")
        }
        return entries
    }

    /// Decompress one entry and check it against the archive's own checksum.
    ///
    /// The CRC is verified rather than ignored because the failure it catches
    /// is exactly the kind this repo is about: a partial download inflates
    /// into plausible-looking CSV with a few thousand rows missing, and the
    /// board is then quietly wrong rather than obviously broken.
    static func extract(_ entry: Entry, from data: Data) throws -> Data {
        let compressed = data.subdata(in: entry.compressedRange)
        let output: Data
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            output = try inflate(compressed, expecting: entry.uncompressedSize, name: entry.name)
        default:
            throw ZipError.unsupportedMethod(entry.method, entry.name)
        }
        guard crc32(output) == entry.crc32 else {
            throw ZipError.checksumMismatch(entry.name)
        }
        return output
    }

    /// Raw deflate, which is what a zip member holds — no zlib wrapper.
    private static func inflate(_ data: Data, expecting size: Int, name: String) throws -> Data {
        // A little headroom, because an entry may legitimately declare a size
        // of zero when the real one lives in a data descriptor.
        let capacity = max(size, data.count * 8, 64 * 1024)
        var output = Data()
        try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return }
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { destination.deallocate() }
            let written = compression_decode_buffer(
                destination, capacity, base, data.count, nil, COMPRESSION_ZLIB
            )
            guard written > 0 else { throw ZipError.truncated(name) }
            output = Data(bytes: destination, count: written)
        }
        return output
    }

    // MARK: - Little-endian reads

    private static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    // MARK: - CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }
}
