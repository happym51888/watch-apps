import Foundation
import UserNotifications
import WatchKit
import AwqatCore

/// Prayer alerts, split deliberately into two mechanisms.
///
/// **Why Fajr is different.** Every prayer app delivers the pre-dawn Fajr and
/// suhoor alert as a notification, and iOS caps a notification sound at 30
/// seconds. Thirty seconds of chime does not wake someone who is genuinely
/// asleep, which is why the recurring complaint about these apps is not that
/// the times are wrong — it is that people miss Fajr. A notification is a
/// reminder. Waking up needs an alarm.
///
/// watchOS has an actual alarm mechanism: an extended runtime session of type
/// `.alarm`. It is scheduled ahead of time, wakes the app at the appointed
/// moment even if nothing is running, and gives it a real UI plus haptics on
/// the wrist. Apple's constraints on it are strict and they shape this whole
/// file:
///
/// - at most **36 hours** ahead
/// - **one scheduled session at a time**
/// - the app **must play a haptic** when it starts, or the system offers the
///   user a way to stop the app scheduling them at all
///
/// So: Fajr (the one you might sleep through) gets the single alarm slot, and
/// is re-armed every time the app runs. The other four get ordinary
/// notifications, which is the right tool for "you are awake, it is time".
@MainActor
final class AlarmScheduler {

    static let shared = AlarmScheduler()

    /// watchOS allows 64 pending local notifications. Five prayers over seven
    /// days is 35, which leaves room and covers a week away from the phone.
    private let daysAhead = 7

    private var pendingAlarm: WKExtendedRuntimeSession?
    private var alarmDelegate: AlarmSessionDelegate?

    // MARK: - Permission

    func requestAuthorization() async -> Bool {
        let centre = UNUserNotificationCenter.current()
        return (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    // MARK: - Notifications for the other four prayers

    func rescheduleNotifications(
        coordinates: Coordinates,
        settings: Settings,
        from now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        let centre = UNUserNotificationCenter.current()
        centre.removeAllPendingNotificationRequests()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        for dayOffset in 0..<daysAhead {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            guard let times = PrayerTimes(
                coordinates: coordinates,
                date: CalendarDate(day, timeZone: timeZone),
                method: settings.method,
                parameterOverride: settings.parameters
            ) else {
                // Polar day. Nothing to schedule, and inventing a time here
                // would be worse than staying silent.
                continue
            }

            for (prayer, time) in times.ordered {
                guard prayer.isObligatoryPrayer else { continue }
                guard settings.notify.contains(prayer.rawValue) else { continue }
                guard time > now else { continue }
                // Fajr is handled by the alarm path when that is switched on.
                if prayer == .fajr && settings.fajrAlarmEnabled { continue }

                schedule(prayer: prayer, at: time, calendar: calendar)
            }
        }
    }

    private func schedule(prayer: Prayer, at time: Date, calendar: Calendar) {
        let content = UNMutableNotificationContent()
        content.title = prayer.displayName
        content.body = "It is time for \(prayer.displayName)."
        content.sound = .default

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: time
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        // Deterministic identifier: rescheduling the same prayer on the same
        // day replaces its request instead of stacking a duplicate.
        let identifier = "awqat.\(prayer.rawValue).\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    // MARK: - The Fajr alarm

    /// Arm the single alarm slot for the next Fajr.
    ///
    /// Returns the instant it was armed for, or nil with a reason. Callers show
    /// that reason: an alarm the user believes is set but is not is worse than
    /// no alarm at all.
    @discardableResult
    func armFajrAlarm(
        coordinates: Coordinates,
        settings: Settings,
        from now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Result<Date, AlarmFailure> {
        cancelFajrAlarm()

        guard settings.fajrAlarmEnabled else { return .failure(.disabled) }

        guard let target = nextFajr(
            coordinates: coordinates, settings: settings, from: now, timeZone: timeZone
        ) else {
            return .failure(.noFajrToday)
        }

        let fireAt = target.addingTimeInterval(-Double(settings.fajrAlarmLeadMinutes) * 60)
        guard fireAt > now else { return .failure(.inThePast) }

        // The 36-hour ceiling is Apple's, not ours. It only bites at extreme
        // latitudes in summer, where Fajr can be more than a day away.
        guard fireAt.timeIntervalSince(now) <= 36 * 3600 else {
            return .failure(.tooFarAhead(fireAt))
        }

        let session = WKExtendedRuntimeSession()
        let delegate = AlarmSessionDelegate()
        session.delegate = delegate
        self.alarmDelegate = delegate
        self.pendingAlarm = session

        session.start(at: fireAt)
        return .success(fireAt)
    }

    func cancelFajrAlarm() {
        pendingAlarm?.invalidate()
        pendingAlarm = nil
        alarmDelegate = nil
    }

    /// The next Fajr at or after `now`, looking at today and then tomorrow.
    /// Searches up to three days so that polar days do not produce a nil the
    /// caller has to interpret as "never".
    func nextFajr(
        coordinates: Coordinates,
        settings: Settings,
        from now: Date,
        timeZone: TimeZone = .current
    ) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        for dayOffset in 0...3 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            guard let times = PrayerTimes(
                coordinates: coordinates,
                date: CalendarDate(day, timeZone: timeZone),
                method: settings.method,
                parameterOverride: settings.parameters
            ) else { continue }
            if times.fajr > now { return times.fajr }
        }
        return nil
    }

    enum AlarmFailure: Equatable {
        case disabled
        case noFajrToday
        case inThePast
        /// Fajr is more than 36 hours out, which watchOS will not schedule.
        case tooFarAhead(Date)

        var explanation: String {
            switch self {
            case .disabled:
                "The Fajr alarm is off."
            case .noFajrToday:
                "There is no Fajr time at this latitude right now, so no alarm can be set."
            case .inThePast:
                "That time has already passed today."
            case .tooFarAhead:
                "Fajr is more than 36 hours away, which is further than watchOS will schedule an alarm. Open Awqat again tomorrow and it will arm itself."
            }
        }
    }
}

/// Runs when the alarm fires.
///
/// The haptic is not optional. Apple's documentation is explicit that an alarm
/// session which does not play one prompts the system to offer the user a way
/// to stop the app scheduling sessions — so a silent alarm does not merely fail
/// once, it can disable the feature permanently.
private final class AlarmSessionDelegate: NSObject, WKExtendedRuntimeSessionDelegate {

    func extendedRuntimeSessionDidStart(_ session: WKExtendedRuntimeSession) {
        // A repeating pattern rather than one buzz. One tap does not wake
        // anyone, and this session type exists precisely for the case where the
        // user is asleep.
        let device = WKInterfaceDevice.current()
        device.play(.notification)

        Task { @MainActor in
            for _ in 0..<12 {
                try? await Task.sleep(for: .seconds(1.5))
                device.play(.notification)
            }
        }
    }

    func extendedRuntimeSessionWillExpire(_ session: WKExtendedRuntimeSession) {}

    func extendedRuntimeSession(
        _ session: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {}
}
