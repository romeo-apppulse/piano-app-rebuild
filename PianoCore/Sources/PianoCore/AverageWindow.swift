//
//  AverageWindow.swift — the one place that defines the daily-average look-back window.
//
//  The client reserved the right to refine what counts as "recent practice", so the
//  entire window definition is isolated here behind a single named constant.
//

import Foundation

public enum AverageWindow {

    /// THE averaging look-back window, in days — the single source of truth.
    ///
    /// This is a ROLLING window: always the last `windowDays` days counted back from
    /// the current moment, NOT calendar months (so every day is weighted identically
    /// regardless of month length). Change this one constant if the client ever wants
    /// a different span (e.g. 60 or 120 days).
    public static let windowDays = 90

    /// The rolling averaging interval ending at `now`, looking back `days` days.
    ///
    /// - Lower bound: `now` minus `days` days, **inclusive** — an entry whose
    ///   timestamp is exactly at the cutoff IS counted.
    /// - Upper bound: `now`, inclusive.
    ///
    /// `days` defaults to `windowDays`; it is a parameter only so tests can pin an
    /// explicit span. Day arithmetic goes through `calendar` so any DST shift is exact.
    public static func interval(endingAt now: Date,
                                days: Int = windowDays,
                                calendar: Calendar) -> DateInterval {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        // DateInterval requires end >= start; guard defensively (never trips for days >= 0).
        return DateInterval(start: min(cutoff, now), end: now)
    }
}
