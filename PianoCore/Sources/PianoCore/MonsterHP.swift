//
//  MonsterHP.swift — THE monster-HP formula. Change it HERE only.
//
//  HP is always RECALCULABLE from stored inputs (frozen spawn averages + the current
//  kill target), never persisted as a final number — so changing the kill target
//  mid-battle recomputes correctly, while new practice and the sliding window never
//  move an already-spawned monster (its averages are frozen).
//

import Foundation

public enum MonsterMath {

    /// Base HP = ceil( Σ(daily averages) × killTargetWeeks ).
    ///
    /// The caller supplies the contributor set's averages:
    ///   • regular  → the team's members,
    ///   • miniboss → all (active) students.
    /// Averages stay fractional; we round UP exactly once, at the very end.
    public static func baseHP(dailyAverages: [Double], killTargetWeeks: Int) -> Int {
        let total = (dailyAverages.reduce(0, +) * Double(killTargetWeeks)).rounded(.up)
        // Clamp so an absurdly large total can never trap on the Int(...) conversion.
        // (Double(Int.max) rounds up to 2^63, so compare against it before converting.)
        if total >= Double(Int.max) { return Int.max }
        return Int(total)
    }

    /// The live effective HP of a spawned monster: base from its FROZEN spawn averages,
    /// plus the teacher's backdoor delta, floored at the configured minimum.
    /// `legacyFixedHP` (migration) short-circuits the formula but still honors the
    /// delta and the floor — so a migrated monster's bar matches the old app on day one.
    public static func effectiveHP(for record: MonsterRecord, minimumHP: Int) -> Int {
        let raw: Int
        if let fixed = record.legacyFixedHP {
            raw = fixed + record.backdoorHPDelta
        } else {
            let base = baseHP(dailyAverages: record.spawnAverages.map { $0.average },
                              killTargetWeeks: record.killTargetWeeks)
            raw = base + record.backdoorHPDelta
        }
        return max(minimumHP, raw)
    }
}
