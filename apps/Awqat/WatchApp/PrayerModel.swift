import Foundation
import Observation
import CoreLocation
import WidgetKit

/// Holds the timetable and everything derived from it.
///
/// The important property is that this never blocks on the network or on Core
/// Location. Times are computed from coordinates and a date with pure
/// arithmetic, so as long as we have ever known where the user is, there is
/// always a timetable to show — on a plane, in a basement, in a country with no
/// data roaming. That is the single biggest complaint about the apps this one
/// competes with.
@MainActor
@Observable
final class PrayerModel {

    private(set) var settings = SettingsStore.load()
    private(set) var times: PrayerTimes?
    private(set) var qibla: Qibla?
    private(set) var distanceToKaaba: Double?
    /// Set when the sun does not rise or set at all, which is a real answer
    /// rather than an error and has to be said out loud.
    private(set) var polarDay = false
    private(set) var alarmArmedFor: Date?
    private(set) var alarmProblem: String?

    let location = LocationProvider()

    // MARK: - Lifecycle

    func start() {
        recompute()
        location.requestFix { [weak self] fix, name in
            guard let self else { return }
            self.settings.lastLatitude = fix.coordinate.latitude
            self.settings.lastLongitude = fix.coordinate.longitude
            self.settings.lastPlaceName = name ?? self.settings.lastPlaceName
            self.settings.lastLocationFix = .now
            self.persist()
            self.recompute()
            self.rescheduleAlerts()
        }
    }

    // MARK: - Computation

    func recompute(now: Date = Date(), timeZone: TimeZone = .current) {
        guard let coordinates = settings.coordinates else {
            times = nil
            qibla = nil
            return
        }

        let today = CalendarDate(now, timeZone: timeZone)
        let computed = PrayerTimes(
            coordinates: coordinates,
            date: today,
            method: settings.method,
            parameterOverride: settings.parameters
        )

        polarDay = (computed == nil)
        times = computed
        qibla = Qibla(from: coordinates)
        distanceToKaaba = Qibla.distanceKilometres(from: coordinates)
    }

    /// Next prayer, rolling into tomorrow once Isha has passed.
    ///
    /// Rolling over matters: after Isha the most useful thing on the screen is
    /// tomorrow's Fajr, and an app that shows "no more prayers today" there is
    /// answering a question nobody asked.
    func upcoming(now: Date = Date(), timeZone: TimeZone = .current) -> (prayer: Prayer, time: Date)? {
        if let times, let next = times.next(after: now) { return next }

        guard let coordinates = settings.coordinates else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
        guard let times = PrayerTimes(
            coordinates: coordinates,
            date: CalendarDate(tomorrow, timeZone: timeZone),
            method: settings.method,
            parameterOverride: settings.parameters
        ) else { return nil }
        return (.fajr, times.fajr)
    }

    func current(now: Date = Date()) -> Prayer? {
        times?.current(at: now)
    }

    // MARK: - Alerts

    func rescheduleAlerts(now: Date = Date()) {
        guard let coordinates = settings.coordinates else { return }

        AlarmScheduler.shared.rescheduleNotifications(
            coordinates: coordinates, settings: settings, from: now
        )

        guard settings.fajrAlarmEnabled else {
            AlarmScheduler.shared.cancelFajrAlarm()
            alarmArmedFor = nil
            alarmProblem = nil
            return
        }

        switch AlarmScheduler.shared.armFajrAlarm(
            coordinates: coordinates, settings: settings, from: now
        ) {
        case .success(let armed):
            alarmArmedFor = armed
            alarmProblem = nil
        case .failure(let failure):
            alarmArmedFor = nil
            alarmProblem = failure.explanation
        }
    }

    func requestNotificationPermission() async {
        _ = await AlarmScheduler.shared.requestAuthorization()
    }

    // MARK: - Mutation

    func update(_ mutate: (inout Settings) -> Void) {
        mutate(&settings)
        persist()
        recompute()
        rescheduleAlerts()
    }

    /// Tasbih is written straight through on every tap. A counter that loses
    /// its place because the app was killed mid-dhikr is worse than no counter.
    func incrementTasbih() {
        settings.tasbihCount += 1
        persist()
    }

    func resetTasbih() {
        settings.tasbihCount = 0
        persist()
    }

    private func persist() {
        SettingsStore.save(settings)
        publishSnapshot()
    }

    /// Push the next prayer out to the complication. `SharedSnapshot` lives in
    /// `Shared/` because the widget extension compiles it too.
    private func publishSnapshot() {
        guard let next = upcoming() else { return }
        SharedSnapshot.write(
            SharedSnapshot.Payload(
                prayerName: next.prayer.displayName,
                time: next.time,
                placeName: settings.lastPlaceName
            )
        )
        // Without this the face can sit on a stale entry until its own reload
        // policy fires, which is the difference between "instant" and "why
        // hasn't it updated".
        WidgetCenter.shared.reloadAllTimelines()
    }
}
