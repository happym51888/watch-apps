import Foundation

/// When a service runs, as `calendar.txt` states it.
public struct ServiceWindow: Sendable, Equatable, Codable {
    public let serviceID: String
    /// Monday through Sunday, in GTFS column order.
    public let days: [Bool]
    public let start: ServiceDate
    public let end: ServiceDate

    public init(serviceID: String, days: [Bool], start: ServiceDate, end: ServiceDate) {
        self.serviceID = serviceID
        self.days = days
        self.start = start
        self.end = end
    }

    public func covers(_ day: ServiceDate) -> Bool {
        // Both ends are inclusive. Writing this as a half-open range takes the
        // last day of every timetable off the board, which nobody notices
        // until the day the timetable changes. (Hazard H4.)
        guard day >= start, day <= end else { return false }
        return days[day.weekdayIndex]
    }
}

public enum ServiceException: Int, Sendable, Codable {
    case added = 1
    case removed = 2
}

public struct Route: Sendable, Equatable, Codable {
    public let routeID: String
    public let shortName: String
    public let longName: String
    public let routeType: Int

    public init(routeID: String, shortName: String, longName: String, routeType: Int) {
        self.routeID = routeID
        self.shortName = shortName
        self.longName = longName
        self.routeType = routeType
    }

    /// What fits on a 41 mm screen: the short name if the agency gave one.
    public var label: String {
        let short = shortName.trimmingCharacters(in: .whitespaces)
        if !short.isEmpty { return short }
        let long = longName.trimmingCharacters(in: .whitespaces)
        return long.isEmpty ? routeID : long
    }
}

public struct Trip: Sendable, Equatable, Codable {
    public let tripID: String
    public let routeID: String
    public let serviceID: String
    public let headsign: String

    public init(tripID: String, routeID: String, serviceID: String, headsign: String) {
        self.tripID = tripID
        self.routeID = routeID
        self.serviceID = serviceID
        self.headsign = headsign
    }
}

public struct Stop: Sendable, Equatable, Codable, Identifiable {
    public var id: String { stopID }
    public let stopID: String
    public let name: String
    public let parentStation: String
    public let locationType: Int

    public init(stopID: String, name: String, parentStation: String = "", locationType: Int = 0) {
        self.stopID = stopID
        self.name = name
        self.parentStation = parentStation
        self.locationType = locationType
    }

    public var isStation: Bool { locationType == 1 }
}

/// One boardable departure from one stop on one trip.
///
/// Only boardable ones are kept: rows where `pickup_type` is 1 (no pickup) and
/// the final stop of a trip, which is an arrival and not a departure. Both
/// exclusions happen when the slice is compiled, so the watch never has to
/// decide. (Hazards H5 and H6.)
public struct ScheduledDeparture: Sendable, Equatable, Codable {
    public let tripID: String
    public let stopID: String
    public let stopSequence: Int
    /// Seconds after the start of the service day. May exceed 86,400.
    public let departure: Int

    public init(tripID: String, stopID: String, stopSequence: Int, departure: Int) {
        self.tripID = tripID
        self.stopID = stopID
        self.stopSequence = stopSequence
        self.departure = departure
    }
}

public enum Validity: String, Sendable, Codable {
    case current, expired, future
}

/// Everything the watch needs to answer "what leaves here next", offline.
///
/// This is a *slice*: the trips calling at the stops the rider saved, not a
/// whole agency. A national feed is tens of megabytes and hundreds of
/// thousands of rows; the five stops somebody actually uses are a few
/// thousand, which fits on a watch and resolves in milliseconds.
///
/// Ported from `validation/gtfs_engine.py`, which
/// `validation/verify_gtfs.py` holds against 1,191 departure instants
/// resolved independently by Entur's journey planner.
public struct Timetable: Sendable, Codable {
    public let agencyName: String
    /// IANA identifier, e.g. `Europe/Oslo`. Not an offset: an offset cannot
    /// express the days this app exists to get right.
    public let timeZoneID: String
    public let stops: [String: Stop]
    public let routes: [String: Route]
    public let trips: [String: Trip]
    public let calendars: [String: ServiceWindow]
    /// Keyed by service id, then by date.
    public let exceptions: [String: [ServiceDate: ServiceException]]
    /// Boardable departures, keyed by stop id, sorted by time within a stop.
    public let departuresByStop: [String: [ScheduledDeparture]]
    /// What `feed_info.txt` claimed, when it claimed anything. Kept only so
    /// the claim can be checked against the calendars.
    public let declaredStart: ServiceDate?
    public let declaredEnd: ServiceDate?
    public let compiledAt: Date

    public init(
        agencyName: String,
        timeZoneID: String,
        stops: [String: Stop],
        routes: [String: Route],
        trips: [String: Trip],
        calendars: [String: ServiceWindow],
        exceptions: [String: [ServiceDate: ServiceException]],
        departuresByStop: [String: [ScheduledDeparture]],
        declaredStart: ServiceDate? = nil,
        declaredEnd: ServiceDate? = nil,
        compiledAt: Date = Date()
    ) {
        self.agencyName = agencyName
        self.timeZoneID = timeZoneID
        self.stops = stops
        self.routes = routes
        self.trips = trips
        self.calendars = calendars
        self.exceptions = exceptions
        self.departuresByStop = departuresByStop
        self.declaredStart = declaredStart
        self.declaredEnd = declaredEnd
        self.compiledAt = compiledAt
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .gmt }

    // MARK: - Service days

    /// The instant a service day begins: noon on that date, minus twelve
    /// *elapsed* hours.
    ///
    /// This is the definition in the GTFS specification, and on 361 days a
    /// year it is exactly midnight, which is why writing `midnight` instead
    /// passes every test anyone thinks to run. On the four days a year the
    /// clocks change it differs by an hour, and every departure on the board
    /// is an hour wrong — on the two days of the year when a rider is most
    /// likely to be checking. (Hazard H1.)
    ///
    /// The subtraction is deliberately done on a `Date`, which is an absolute
    /// instant, so it removes twelve real hours. Doing the same arithmetic on
    /// wall-clock components would land back on midnight and hide the bug it
    /// exists to prevent.
    public func serviceDayOrigin(_ day: ServiceDate) -> Date {
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let noon = calendar.date(from: components) else {
            // Only reachable if the zone database is missing entirely.
            return Date(timeIntervalSince1970: Double(day.daysSinceEpoch) * 86_400)
        }
        return noon.addingTimeInterval(-12 * 3_600)
    }

    /// Which services run on a date.
    ///
    /// `calendar_dates.txt` overrides `calendar.txt` rather than adding to it.
    /// An engine that only unions the additions runs cancelled services on
    /// public holidays, which is the day a rider is least able to absorb being
    /// wrong. (Hazard H3.)
    public func activeServices(on day: ServiceDate) -> Set<String> {
        var ids = Set(calendars.values.filter { $0.covers(day) }.map(\.serviceID))
        for (serviceID, byDate) in exceptions {
            switch byDate[day] {
            case .added: ids.insert(serviceID)
            case .removed: ids.remove(serviceID)
            case nil: break
            }
        }
        return ids
    }

    // MARK: - Stops

    /// Asking about a station means asking about its platforms.
    ///
    /// A rider saves "Oslo S", not "NSR:Quay:11216". A board that queries the
    /// station id alone finds nothing at all, because in most feeds no trip
    /// calls at the station record itself. (Hazard H10.)
    public func expand(_ stopIDs: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for stopID in stopIDs {
            var candidates = [stopID]
            candidates.append(contentsOf: stops.values.filter { $0.parentStation == stopID }.map(\.stopID).sorted())
            for candidate in candidates where !seen.contains(candidate) && stops[candidate] != nil {
                seen.insert(candidate)
                out.append(candidate)
            }
        }
        return out
    }

    public func displayName(forStops stopIDs: [String]) -> String {
        let names = expand(stopIDs).compactMap { stops[$0]?.name }
        var seen = Set<String>()
        let unique = names.filter { seen.insert($0).inserted }
        return unique.first ?? stopIDs.first ?? "Stop"
    }

    // MARK: - Validity

    /// The span the calendars actually describe.
    ///
    /// Derived from the calendars rather than from `feed_info.txt`, because
    /// publishers get `feed_info` wrong: the BART feed used while building
    /// this states an end date of 2026-08-30 while its `calendar.txt` runs to
    /// 2027-01-10. Believing `feed_info` there would blank the board for four
    /// months of perfectly good timetable. (Hazard H9.)
    public var coverage: (start: ServiceDate, end: ServiceDate)? {
        var dates: [ServiceDate] = []
        for window in calendars.values where window.days.contains(true) {
            dates.append(window.start)
            dates.append(window.end)
        }
        for (_, byDate) in exceptions {
            for (date, kind) in byDate where kind == .added { dates.append(date) }
        }
        guard let low = dates.min(), let high = dates.max() else { return nil }
        return (low, high)
    }

    /// Never silently empty. An expired slice says so; it does not show a
    /// blank board that looks like "no more trains tonight".
    public func validity(on day: ServiceDate) -> Validity {
        guard let span = coverage else { return .expired }
        if day > span.end { return .expired }
        if day < span.start { return .future }
        return .current
    }

    /// True when `feed_info.txt` contradicts the calendars shipped with it.
    /// Worth surfacing to whoever compiled the slice, not to the rider.
    public var declarationDisagrees: Bool {
        guard let span = coverage else { return declaredStart != nil || declaredEnd != nil }
        if let start = declaredStart, start > span.start { return true }
        if let end = declaredEnd, end < span.end { return true }
        return false
    }

    /// Today's date in the feed's own zone, which is not necessarily the
    /// rider's. Checking Oslo departures from a hotel in Tokyo has to use
    /// Oslo's idea of what day it is.
    public func localDate(at instant: Date) -> ServiceDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return ServiceDate(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }
}
