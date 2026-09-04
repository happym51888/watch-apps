import Foundation
import XCTest
@testable import ProximaCore

/// The CSV reader. Every case here comes from something real feeds do.
final class CSVTests: XCTestCase {

    func testPlainRows() {
        let csv = CSV("a,b,c\n1,2,3\n4,5,6\n")
        XCTAssertEqual(csv.header, ["a", "b", "c"])
        XCTAssertEqual(csv.count, 2)
        XCTAssertEqual(csv.value(csv.rows[1], "b"), "5")
    }

    func testAQuotedFieldMayContainTheDelimiter() {
        // Headsigns do this constantly: "Downtown, via Elm".
        let csv = CSV("trip_id,trip_headsign\nt1,\"Downtown, via Elm\"\n")
        XCTAssertEqual(csv.value(csv.rows[0], "trip_headsign"), "Downtown, via Elm")
    }

    func testAQuotedFieldMayContainQuotesAndNewlines() {
        let csv = CSV("stop_id,stop_name\ns1,\"The \"\"Old\"\" Mill\"\ns2,\"Two\nLines\"\n")
        XCTAssertEqual(csv.count, 2)
        XCTAssertEqual(csv.value(csv.rows[0], "stop_name"), "The \"Old\" Mill")
        XCTAssertEqual(csv.value(csv.rows[1], "stop_name"), "Two\nLines")
    }

    func testCRLFLineEndings() {
        // Exported from a spreadsheet on Windows, which is most of them. A
        // reader that splits on "\n" leaves a carriage return on the end of
        // every last field, so "0\r" is not "0" and every pickup_type check
        // silently fails.
        let csv = CSV("a,b\r\n1,0\r\n2,1\r\n")
        XCTAssertEqual(csv.value(csv.rows[0], "b"), "0")
        XCTAssertEqual(csv.int(csv.rows[1], "b"), 1)
    }

    func testAByteOrderMarkOnTheFirstColumn() {
        // A BOM makes the first header "\u{FEFF}stop_id", which then never
        // matches a lookup, so every stop id in the file comes back empty.
        let csv = CSV("\u{FEFF}stop_id,stop_name\ns1,First\n")
        XCTAssertTrue(csv.has("stop_id"))
        XCTAssertEqual(csv.value(csv.rows[0], "stop_id"), "s1")
    }

    func testMissingColumnsAndShortRows() {
        // GTFS makes most columns optional; a feed with no trip_headsign is
        // normal, not broken.
        let csv = CSV("a,b,c\n1,2\n")
        XCTAssertEqual(csv.value(csv.rows[0], "c"), "")
        XCTAssertEqual(csv.value(csv.rows[0], "nonexistent"), "")
        XCTAssertEqual(csv.int(csv.rows[0], "c", default: 7), 7)
    }

    func testEmptyAndWhitespaceOnlyInput() {
        XCTAssertEqual(CSV("").count, 0)
        XCTAssertEqual(CSV("a,b\n").count, 0)
        // A trailing newline must not produce a phantom row.
        XCTAssertEqual(CSV("a,b\n1,2\n").count, 1)
        XCTAssertEqual(CSV("a,b\n1,2").count, 1)
    }

    func testEmptyFieldsAreKeptRatherThanCollapsed() {
        // Blank times matter: they mean "interpolate", not "skip".
        let csv = CSV("trip_id,arrival_time,departure_time\nt1,,\n")
        XCTAssertEqual(csv.rows[0].count, 3)
        XCTAssertEqual(csv.value(csv.rows[0], "departure_time"), "")
    }

    func testDuplicateHeaderNamesTakeTheFirst() {
        let csv = CSV("a,a\n1,2\n")
        XCTAssertEqual(csv.value(csv.rows[0], "a"), "1")
    }
}
