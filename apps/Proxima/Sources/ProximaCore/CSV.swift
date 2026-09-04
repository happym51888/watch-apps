import Foundation

/// A CSV reader for GTFS files.
///
/// GTFS says its files are comma-separated with optional double quotes, and
/// real feeds use every part of that: headsigns contain commas, stop names
/// contain quotes, and files arrive with a UTF-8 byte order mark and CRLF line
/// endings because they were exported from a spreadsheet on Windows.
///
/// Splitting on commas gets you most of the way and then puts half a headsign
/// in the direction column of one row in a thousand. Nothing raises; the board
/// just says something slightly wrong about one bus.
public struct CSV {

    public let header: [String]
    private let indexOf: [String: Int]

    /// Rows as raw field arrays, in file order.
    public let rows: [[String]]

    public init(_ text: String) {
        var content = Substring(text)
        // A byte order mark on the first header field makes it "\u{FEFF}stop_id",
        // which then never matches a column lookup and quietly yields empty
        // stop ids for the whole file.
        if content.hasPrefix("\u{FEFF}") { content = content.dropFirst() }

        var parsed = CSV.parse(String(content))
        let head = parsed.isEmpty ? [] : parsed.removeFirst()
        self.header = head.map { $0.trimmingCharacters(in: .whitespaces) }
        self.rows = parsed
        var map: [String: Int] = [:]
        for (index, name) in self.header.enumerated() where map[name] == nil {
            map[name] = index
        }
        self.indexOf = map
    }

    public var count: Int { rows.count }

    public func has(_ column: String) -> Bool { indexOf[column] != nil }

    /// A field by column name, or "" if the column or the value is absent.
    ///
    /// Missing rather than throwing, because GTFS makes most columns optional
    /// and a feed omitting `trip_headsign` entirely is normal, not broken.
    public func value(_ row: [String], _ column: String) -> String {
        guard let index = indexOf[column], index < row.count else { return "" }
        return row[index]
    }

    public func int(_ row: [String], _ column: String, default fallback: Int = 0) -> Int {
        let text = value(row, column).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? fallback : (Int(text) ?? fallback)
    }

    /// RFC 4180 with the parts GTFS actually uses.
    ///
    /// Written as an explicit scanner rather than a regular expression or a
    /// split, because a quoted field can contain the delimiter, a newline, and
    /// an escaped quote, and none of those survive a split.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            row.append(field)
            field = ""
        }
        func endRow() {
            endField()
            // A trailing newline at the end of the file would otherwise add a
            // row containing one empty field.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while true {
            let character: Character
            if let held = pending {
                character = held
                pending = nil
            } else if let next = iterator.next() {
                character = next
            } else {
                break
            }

            if inQuotes {
                if character == "\"" {
                    // Two quotes inside a quoted field mean one literal quote.
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
            case ",":
                endField()
            case "\n", "\r\n", "\r":
                // Swift treats CRLF as a single `Character`, so the Windows
                // line ending most GTFS exports use never matches a bare "\r"
                // or "\n" and has to be named outright. Miss it and every last
                // field on every row keeps a trailing carriage return, so "0"
                // is not "0" and every pickup_type comparison quietly fails.
                endRow()
            default:
                field.append(character)
            }
        }

        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
