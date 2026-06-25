//
//  DailyAverage.swift — THE daily-average definition. Change it HERE only.
//
//  Pure function over an in-memory entry array; imports no storage, so it is trivial
//  to unit-test and trivial for the client to refine.
//

import Foundation

public enum PracticeMath {

    /// A student's DAILY AVERAGE:
    ///   (sum of their LIVE damage within the rolling window)
    ///   ÷ (count of DISTINCT calendar days on which they logged ≥1 live entry).
    ///
    /// Rules:
    ///   • Window = the last `windowDays` days, rolling from `now` (see AverageWindow).
    ///   • Multiple entries on the same calendar day collapse to ONE day.
    ///   • `.migration` seed entries are EXCLUDED from both numerator and denominator
    ///     (they are a day-one leaderboard baseline, not real dated practice).
    ///   • Zero qualifying days → 0.0. Never divides by zero; never returns NaN/Inf.
    ///
    /// Averages are kept fractional on purpose — rounding happens once, later, when
    /// the final monster HP is computed (see MonsterMath).
    public static func dailyAverage(forStudent studentID: UUID,
                                    entries: [CombatLogEntry],
                                    now: Date,
                                    windowDays: Int = AverageWindow.windowDays,
                                    calendar: Calendar) -> Double {
        let window = AverageWindow.interval(endingAt: now, days: windowDays, calendar: calendar)

        var sum = 0
        var distinctDays = Set<Date>()

        for entry in entries
        where entry.studentID == studentID && entry.origin == .live {
            guard window.contains(entry.timestamp) else { continue }
            sum += entry.amount
            distinctDays.insert(calendar.startOfDay(for: entry.timestamp))
        }

        guard !distinctDays.isEmpty else { return 0 }
        return Double(sum) / Double(distinctDays.count)
    }
}
