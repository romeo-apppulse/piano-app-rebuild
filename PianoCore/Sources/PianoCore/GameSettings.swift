//
//  GameSettings.swift — all tunable game constants in ONE place.
//
//  The client may refine these (especially the kill targets), so they live here
//  rather than scattered as magic numbers. The averaging look-back window is the one
//  exception: it lives as a single constant in AverageWindow.windowDays. The calendar
//  used for day-bucketing is pinned (gregorian) with a configurable timezone so
//  "distinct days" are stable on the single offline iPad.
//

import Foundation

public struct GameSettings: Codable, Hashable {
    /// Regular monster kill target, in weeks. Default 3.
    public var defaultKillTargetWeeks: Int
    /// Miniboss kill target, in weeks. Default 6.
    public var minibossKillTargetWeeks: Int
    /// Floor so a monster never spawns born-dead (e.g. an all-new team summing to 0).
    public var minimumMonsterHP: Int
    /// IANA timezone id for day-bucketing (e.g. "America/Los_Angeles").
    /// Falls back to the device's current timezone if unrecognized.
    public var timeZoneIdentifier: String
    /// Day-one migration: if true, seed leaderboards from each student's legacy score.
    /// If false, all-time/current boards start blank. Flippable without code changes.
    public var seedLeaderboardsFromLegacyScore: Bool

    public init(defaultKillTargetWeeks: Int = 3,
                minibossKillTargetWeeks: Int = 6,
                minimumMonsterHP: Int = 1,
                timeZoneIdentifier: String = TimeZone.current.identifier,
                seedLeaderboardsFromLegacyScore: Bool = true) {
        self.defaultKillTargetWeeks = defaultKillTargetWeeks
        self.minibossKillTargetWeeks = minibossKillTargetWeeks
        self.minimumMonsterHP = minimumMonsterHP
        self.timeZoneIdentifier = timeZoneIdentifier
        self.seedLeaderboardsFromLegacyScore = seedLeaderboardsFromLegacyScore
    }

    /// The pinned calendar used for all day-bucketing. Gregorian, configurable tz.
    public var resolvedCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return calendar
    }

    // Explicit CodingKeys so the forward-compatible decoder below never depends on the
    // compiler still synthesizing them (synthesis is suppressed the moment a custom
    // encode(to:) is added). Keep in sync with the stored properties above.
    private enum CodingKeys: String, CodingKey {
        case defaultKillTargetWeeks
        case minibossKillTargetWeeks
        case minimumMonsterHP
        case timeZoneIdentifier
        case seedLeaderboardsFromLegacyScore
    }

    // Forward-compatible decode: any key added in a newer build is tolerated by a
    // current build, and any key missing from older on-disk data falls back to the
    // default above (so a partial/older appState.json still loads).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameSettings()
        defaultKillTargetWeeks = try c.decodeIfPresent(Int.self, forKey: .defaultKillTargetWeeks) ?? d.defaultKillTargetWeeks
        minibossKillTargetWeeks = try c.decodeIfPresent(Int.self, forKey: .minibossKillTargetWeeks) ?? d.minibossKillTargetWeeks
        minimumMonsterHP = try c.decodeIfPresent(Int.self, forKey: .minimumMonsterHP) ?? d.minimumMonsterHP
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier) ?? d.timeZoneIdentifier
        seedLeaderboardsFromLegacyScore = try c.decodeIfPresent(Bool.self, forKey: .seedLeaderboardsFromLegacyScore) ?? d.seedLeaderboardsFromLegacyScore
    }
}
