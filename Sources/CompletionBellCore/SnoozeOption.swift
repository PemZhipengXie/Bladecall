import Foundation

/// The 「推」 durations offered by the snooze menu. Lives in Core so the
/// fire-date math is testable; display labels stay in the app layer with the
/// bilingual helpers.
public enum SnoozeOption: CaseIterable {
    case oneHour
    case threeHours
    case tonight
    case tomorrowMorning

    /// tonight = the next 20:00; tomorrowMorning = the next 09:00, so picking
    /// it at 03:00 lands on today's 09:00 — matching how people speak.
    public func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .oneHour: return now.addingTimeInterval(3600)
        case .threeHours: return now.addingTimeInterval(3 * 3600)
        case .tonight: return Self.next(hour: 20, from: now, calendar: calendar)
        case .tomorrowMorning: return Self.next(hour: 9, from: now, calendar: calendar)
        }
    }

    /// Hide "tonight" once today's 20:00 has passed.
    public static func visibleOptions(now: Date, calendar: Calendar = .current) -> [SnoozeOption] {
        allCases.filter { option in
            guard option == .tonight else { return true }
            return calendar.isDate(next(hour: 20, from: now, calendar: calendar), inSameDayAs: now)
        }
    }

    private static func next(hour: Int, from now: Date, calendar: Calendar) -> Date {
        calendar.nextDate(
            after: now,
            matching: DateComponents(hour: hour, minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)
    }
}
