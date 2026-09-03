import Foundation

/// RFC 4648 base32 (the "standard" alphabet, A-Z2-7), which is how every
/// authenticator on earth encodes a TOTP shared secret.
///
/// Real-world secrets are pasted by humans off web pages, so the decoder is
/// deliberately forgiving about the things humans do: lowercase, spaces every
/// four characters, missing `=` padding. It is *not* forgiving about characters
/// outside the alphabet, because silently dropping one would produce a key that
/// generates plausible-looking codes that never work.
public enum Base32 {

    public enum DecodeError: Error, Equatable {
        /// A character that is not in the RFC 4648 alphabet and is not
        /// ignorable whitespace or padding.
        case invalidCharacter(Character)
        /// The bit count left over is not a valid base32 quantum. RFC 4648
        /// permits 1–5 leftover bytes per 8-character group; anything else
        /// means characters were lost.
        case truncated
        /// Leftover bits were non-zero. A conforming encoder always pads with
        /// zero bits, so this means the string is corrupt rather than merely
        /// unpadded.
        case nonCanonicalPadding
    }

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// Reverse lookup, built once. Index is the ASCII value.
    private static let reverse: [Int8] = {
        var table = [Int8](repeating: -1, count: 128)
        for (index, character) in alphabet.enumerated() {
            let ascii = Int(character.asciiValue!)
            table[ascii] = Int8(index)
            // Accept lowercase too.
            let lower = Int(Character(character.lowercased()).asciiValue!)
            table[lower] = Int8(index)
        }
        // RFC 4648 §3.4 warns about these confusions; some providers print
        // secrets in fonts where they are ambiguous. Mapping them is a
        // deliberate usability choice, not a spec behaviour.
        table[Int(Character("0").asciiValue!)] = table[Int(Character("O").asciiValue!)]
        table[Int(Character("1").asciiValue!)] = table[Int(Character("L").asciiValue!)]
        table[Int(Character("8").asciiValue!)] = table[Int(Character("B").asciiValue!)]
        return table
    }()

    /// Decode a base32 string into raw key bytes.
    public static func decode(_ input: String) throws -> [UInt8] {
        var output: [UInt8] = []
        var buffer: UInt32 = 0
        var bitsInBuffer: UInt32 = 0

        for character in input {
            if character == "=" { continue }
            if character == " " || character == "-" || character == "\t"
                || character == "\n" || character == "\r" { continue }

            guard let ascii = character.asciiValue, ascii < 128 else {
                throw DecodeError.invalidCharacter(character)
            }
            let value = reverse[Int(ascii)]
            guard value >= 0 else { throw DecodeError.invalidCharacter(character) }

            buffer = (buffer << 5) | UInt32(value)
            bitsInBuffer += 5

            if bitsInBuffer >= 8 {
                bitsInBuffer -= 8
                output.append(UInt8((buffer >> bitsInBuffer) & 0xFF))
            }
        }

        // Whatever is left must be fewer than 8 bits and must be zero.
        if bitsInBuffer >= 5 {
            // 5, 6 or 7 leftover bits means a whole character's worth of data
            // is dangling, which only happens if the string was cut short.
            throw DecodeError.truncated
        }
        if bitsInBuffer > 0 {
            let leftover = buffer & ((1 << bitsInBuffer) - 1)
            if leftover != 0 { throw DecodeError.nonCanonicalPadding }
        }

        return output
    }

    /// Encode raw bytes as unpadded base32. Only used for round-trip tests and
    /// for exporting an account back out; the app never needs padded output.
    public static func encode(_ bytes: [UInt8]) -> String {
        var result = ""
        var buffer: UInt32 = 0
        var bitsInBuffer: UInt32 = 0

        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bitsInBuffer += 8
            while bitsInBuffer >= 5 {
                bitsInBuffer -= 5
                result.append(alphabet[Int((buffer >> bitsInBuffer) & 0x1F)])
            }
        }
        if bitsInBuffer > 0 {
            let index = Int((buffer << (5 - bitsInBuffer)) & 0x1F)
            result.append(alphabet[index])
        }
        return result
    }
}
