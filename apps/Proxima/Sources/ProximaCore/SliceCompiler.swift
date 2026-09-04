import Foundation

/// The GTFS text files a slice is compiled from.
///
/// Passed as already-extracted strings rather than as a zip, so the part with
/// the interesting failure modes can be tested without a zip reader and runs
/// on the Linux machine where `swift test` executes.
public struct FeedTexts: Sendable {
    public var agency: String
    public var stops: String
    public var routes: String
    public var trips: String
    public var stopTimes: String
    public var calendar: String
    public var calendarDates: String
    public var feedInfo: String

    public init(
        agency: String = "",
        stops: String = "",
        routes: String = "",
        trips: String = "",
        stopTimes: String = "",
        calendar: String = "",
        calendarDates: String = "",
        feedInfo: String = ""
    ) {
        self.agency = agency
        self.stops = stops
        self.routes = routes
        self.trips = trips
        self.stopTimes = stopTimes
        self.calendar = calendar
        self.calendarDates = calendarDates
        self.feedInfo = feedInfo
    }
}

/// Turns a published GTFS feed into the slice the watch carries.
///
/// Everything that requires a decision happens here, once, on a device with a
/// keyboard and a battery. The watch then does arithmetic and nothing else.
public enum SliceCompiler {

    /// Compile the trips calling at `stopIDs`.
    ///
    /// - Parameter stopIDs: station or platform ids. Stations are expanded to
    ///   their platforms before anything is matched.
    public static func compile(
        _ texts: FeedTexts,
        stopIDs: [String],
        compiledAt: Date = Date()
    ) throws -> Timetable {

        // MARK: Agency and zone

        let agencyCSV = CSV(texts.agency)
        guard let agencyRow = agencyCSV.rows.first else {
            throw FeedError("agency.txt is empty; a feed without a timezone cannot be resolved")
        }
        let zoneID = agencyCSV.value(agencyRow, "agency_timezone").trimmingCharacters(in: .whitespaces)
        guard TimeZone(identifier: zoneID) != nil else {
            throw FeedError("agency_timezone \(zoneID) is not a zone this device knows")
        }
        let agencyName = agencyCSV.value(agencyRow, "agency_name")

        // MARK: Stops

        var stops: [String: Stop] = [:]
        let stopsCSV = CSV(texts.stops)
        for row in stopsCSV.rows {
            let id = stopsCSV.value(row, "stop_id").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }
            stops[id] = Stop(
                stopID: id,
                name: stopsCSV.value(row, "stop_name"),
                parentStation: stopsCSV.value(row, "parent_station").trimmingCharacters(in: .whitespaces),
                locationType: stopsCSV.int(row, "location_type")
            )
        }

        // Expand stations to platforms before matching anything, or a rider who
        // saved a station gets an empty slice.
        var wanted = Set<String>()
        for stopID in stopIDs {
            wanted.insert(stopID)
            for stop in stops.values where stop.parentStation == stopID {
                wanted.insert(stop.stopID)
            }
        }
        guard !wanted.isEmpty else { throw FeedError("no stops selected") }

        // MARK: Routes, trips, calendars

        var routes: [String: Route] = [:]
        let routesCSV = CSV(texts.routes)
        for row in routesCSV.rows {
            let id = routesCSV.value(row, "route_id").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }
            routes[id] = Route(
                routeID: id,
                shortName: routesCSV.value(row, "route_short_name"),
                longName: routesCSV.value(row, "route_long_name"),
                routeType: routesCSV.int(row, "route_type")
            )
        }

        var trips: [String: Trip] = [:]
        let tripsCSV = CSV(texts.trips)
        for row in tripsCSV.rows {
            let id = tripsCSV.value(row, "trip_id").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }
            trips[id] = Trip(
                tripID: id,
                routeID: tripsCSV.value(row, "route_id").trimmingCharacters(in: .whitespaces),
                serviceID: tripsCSV.value(row, "service_id").trimmingCharacters(in: .whitespaces),
                headsign: tripsCSV.value(row, "trip_headsign")
            )
        }

        var calendars: [String: ServiceWindow] = [:]
        let calendarCSV = CSV(texts.calendar)
        let dayColumns = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        for row in calendarCSV.rows {
            let id = calendarCSV.value(row, "service_id").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty,
                  let start = ServiceDate(gtfs: calendarCSV.value(row, "start_date")),
                  let end = ServiceDate(gtfs: calendarCSV.value(row, "end_date"))
            else { continue }
            calendars[id] = ServiceWindow(
                serviceID: id,
                days: dayColumns.map { calendarCSV.int(row, $0) == 1 },
                start: start,
                end: end
            )
        }

        var exceptions: [String: [ServiceDate: ServiceException]] = [:]
        let datesCSV = CSV(texts.calendarDates)
        for row in datesCSV.rows {
            let id = datesCSV.value(row, "service_id").trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty,
                  let date = ServiceDate(gtfs: datesCSV.value(row, "date")),
                  let kind = ServiceException(rawValue: datesCSV.int(row, "exception_type"))
            else { continue }
            exceptions[id, default: [:]][date] = kind
        }

        // MARK: Stop times

        // Two passes. The first finds which trips call at a wanted stop; the
        // second keeps those trips *whole*. Keeping only the matching rows
        // would be smaller and wrong: the last stop of a trip is arrival-only,
        // and blank times interpolate from their neighbours, so both need rows
        // the rider did not ask about.
        let stopTimesCSV = CSV(texts.stopTimes)
        var tripsOfInterest = Set<String>()
        for row in stopTimesCSV.rows
        where wanted.contains(stopTimesCSV.value(row, "stop_id").trimmingCharacters(in: .whitespaces)) {
            tripsOfInterest.insert(stopTimesCSV.value(row, "trip_id").trimmingCharacters(in: .whitespaces))
        }

        var byTrip: [String: [StopTimeRow]] = [:]
        var maxSeconds = 0
        for row in stopTimesCSV.rows {
            let tripID = stopTimesCSV.value(row, "trip_id").trimmingCharacters(in: .whitespaces)
            guard tripsOfInterest.contains(tripID) else { continue }
            let departure = try GTFSTime.parse(stopTimesCSV.value(row, "departure_time"))
            let arrival = try GTFSTime.parse(stopTimesCSV.value(row, "arrival_time"))
            if let departure { maxSeconds = max(maxSeconds, departure) }
            byTrip[tripID, default: []].append(
                StopTimeRow(
                    tripID: tripID,
                    stopID: stopTimesCSV.value(row, "stop_id").trimmingCharacters(in: .whitespaces),
                    sequence: stopTimesCSV.int(row, "stop_sequence"),
                    departure: departure,
                    arrival: arrival,
                    pickupType: stopTimesCSV.int(row, "pickup_type")
                )
            )
        }

        // A departure past 48:00:00 would need a two-day lookback to resolve,
        // and the resolver only looks back one. No published feed does this;
        // refusing loudly beats resolving it to the wrong day. (Hazard H2.)
        guard maxSeconds < (maxServiceDayLookback + 1) * 86_400 else {
            throw FeedError(
                "feed has a departure at \(maxSeconds / 3600):xx, beyond the "
                    + "\(maxServiceDayLookback)-service-day lookback the resolver uses"
            )
        }

        var departuresByStop: [String: [ScheduledDeparture]] = [:]
        for (tripID, unsorted) in byTrip {
            var times = unsorted.sorted { $0.sequence < $1.sequence }
            interpolate(&times)
            guard let lastSequence = times.last?.sequence else { continue }

            for time in times {
                guard wanted.contains(time.stopID) else { continue }
                // pickup_type 1 means the vehicle passes without taking anyone
                // on. Showing it is telling a rider to stand at a stop the bus
                // will not open its doors at. (Hazard H5.)
                if time.pickupType == 1 { continue }
                // The last stop of a trip is where it arrives, not where it
                // leaves from. (Hazard H6.)
                if time.sequence == lastSequence { continue }
                guard let departure = time.departure else { continue }

                departuresByStop[time.stopID, default: []].append(
                    ScheduledDeparture(
                        tripID: tripID,
                        stopID: time.stopID,
                        stopSequence: time.sequence,
                        departure: departure
                    )
                )
            }
        }

        for stopID in departuresByStop.keys {
            departuresByStop[stopID]?.sort {
                $0.departure != $1.departure ? $0.departure < $1.departure : $0.tripID < $1.tripID
            }
        }

        // Only the trips and routes still referenced are worth carrying.
        let keptTripIDs = Set(departuresByStop.values.flatMap { $0.map(\.tripID) })
        let keptTrips = trips.filter { keptTripIDs.contains($0.key) }
        let keptRouteIDs = Set(keptTrips.values.map(\.routeID))
        let keptServiceIDs = Set(keptTrips.values.map(\.serviceID))

        // MARK: feed_info

        let infoCSV = CSV(texts.feedInfo)
        let infoRow = infoCSV.rows.first

        // The wanted platforms, plus the stations they hang off so that a slice
        // saved as "Oslo S" still expands to its quays after a round trip.
        var keptStopIDs = wanted
        for id in wanted {
            let parent = stops[id]?.parentStation ?? ""
            if !parent.isEmpty { keptStopIDs.insert(parent) }
        }

        return Timetable(
            agencyName: agencyName,
            timeZoneID: zoneID,
            stops: stops.filter { keptStopIDs.contains($0.key) },
            routes: routes.filter { keptRouteIDs.contains($0.key) },
            trips: keptTrips,
            calendars: calendars.filter { keptServiceIDs.contains($0.key) },
            exceptions: exceptions.filter { keptServiceIDs.contains($0.key) },
            departuresByStop: departuresByStop,
            declaredStart: infoRow.flatMap { ServiceDate(gtfs: infoCSV.value($0, "feed_start_date")) },
            declaredEnd: infoRow.flatMap { ServiceDate(gtfs: infoCSV.value($0, "feed_end_date")) },
            compiledAt: compiledAt
        )
    }

    /// Fill blank times linearly between the known ones.
    ///
    /// GTFS lets a feed omit times at stops that are not timepoints; the
    /// specification's reading is that they fall evenly between the surrounding
    /// ones. Leaving them blank takes those stops off the board entirely, and
    /// treating a blank as zero puts every one of them at midnight. Neither
    /// raises. (Hazard H8.)
    static func interpolate(_ times: inout [StopTimeRow]) {
        let known = times.indices.filter { times[$0].departure != nil || times[$0].arrival != nil }
        guard known.count > 1, known.count != times.count else { return }

        for position in 0..<(known.count - 1) {
            let left = known[position]
            let right = known[position + 1]
            let gap = right - left
            guard gap > 1 else { continue }
            guard let leftTime = times[left].departure ?? times[left].arrival,
                  let rightTime = times[right].arrival ?? times[right].departure
            else { continue }

            let step = Double(rightTime - leftTime) / Double(gap)
            for offset in 1..<gap {
                let value = Int((Double(leftTime) + step * Double(offset)).rounded())
                times[left + offset].departure = value
                times[left + offset].arrival = value
            }
        }
    }
}

/// One `stop_times.txt` row, mutable so blanks can be filled in place.
struct StopTimeRow {
    let tripID: String
    let stopID: String
    let sequence: Int
    var departure: Int?
    var arrival: Int?
    let pickupType: Int
}
