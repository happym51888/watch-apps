import Foundation

/// A resolved departure: a real instant, not an offset into a service day.
public struct Departure: Sendable, Equatable, Identifiable {
    public let when: Date
    public let tripID: String
    public let stopID: String
    public let stopSequence: Int
    public let routeLabel: String
    public let headsign: String
    public let serviceDay: ServiceDate

    public var id: String { "\(tripID)|\(stopID)|\(stopSequence)" }

    public func minutesAway(from now: Date) -> Int {
        // Rounded down. A bus 89 seconds away is "1 min", not "2 min": telling
        // a rider they have more time than they do is the failure that makes
        // them miss it.
        Int(max(0, when.timeIntervalSince(now)) / 60)
    }
}

/// How many service days back to look for trips still running.
///
/// GTFS permits times past `24:00:00` to mean "after midnight, on the same
/// service day". Feeds in the wild reach into the 20s; `48:00:00` would be two
/// days out. Two is what the reference implementation was validated with, and
/// `SliceCompiler` refuses any feed that exceeds it rather than resolving those
/// trips against the wrong day.
public let maxServiceDayLookback = 2

/// What leaves these stops at or after `now`, soonest first.
///
/// - Parameter horizon: bounds the search, so a board opened at two in the
///   morning does not scan a week of timetable to find Monday's first bus.
public func nextDepartures(
    _ timetable: Timetable,
    stopIDs: [String],
    now: Date,
    limit: Int = 8,
    horizon: TimeInterval = 12 * 3_600
) -> [Departure] {
    let stops = timetable.expand(stopIDs)
    guard !stops.isEmpty else { return [] }

    let deadline = now.addingTimeInterval(horizon)
    let today = timetable.localDate(at: now)
    var found: [Departure] = []

    // The days before, today, and tomorrow.
    //
    // Yesterday matters because a trip listed at `25:30:00` on Saturday leaves
    // at 01:30 on Sunday and belongs to Saturday's service. Scan only today
    // and the board is empty after midnight, exactly when the last train is
    // the one worth knowing about. (Hazard H7.)
    //
    // Tomorrow matters because the horizon can reach into it, and because
    // tomorrow's service day begins before tomorrow's midnight on a
    // fall-back night.
    for offset in (-maxServiceDayLookback)...1 {
        let day = today.adding(days: offset)
        let origin = timetable.serviceDayOrigin(day)
        if origin > deadline { continue }

        let active = timetable.activeServices(on: day)
        if active.isEmpty { continue }

        for stopID in stops {
            for scheduled in timetable.departuresByStop[stopID] ?? [] {
                let when = origin.addingTimeInterval(TimeInterval(scheduled.departure))
                if when < now || when > deadline { continue }
                guard let trip = timetable.trips[scheduled.tripID],
                      active.contains(trip.serviceID)
                else { continue }

                found.append(
                    Departure(
                        when: when,
                        tripID: scheduled.tripID,
                        stopID: scheduled.stopID,
                        stopSequence: scheduled.stopSequence,
                        routeLabel: timetable.routes[trip.routeID]?.label ?? trip.routeID,
                        headsign: trip.headsign,
                        serviceDay: day
                    )
                )
            }
        }
    }

    // A trip can only be reachable through two service days if the feed is
    // malformed, but dedupe anyway: showing the same train twice is a bug the
    // rider can see, and keeping the earlier instant is the safe direction to
    // be wrong in.
    var unique: [String: Departure] = [:]
    for departure in found {
        if let existing = unique[departure.id], existing.when <= departure.when { continue }
        unique[departure.id] = departure
    }

    let ordered = unique.values.sorted {
        if $0.when != $1.when { return $0.when < $1.when }
        if $0.tripID != $1.tripID { return $0.tripID < $1.tripID }
        return $0.stopSequence < $1.stopSequence
    }
    return Array(ordered.prefix(limit))
}
