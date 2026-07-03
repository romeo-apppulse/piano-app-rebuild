//
//  Lineup.swift — the shared, ordered monster lineup.
//
//  One lineup for the whole class: an ordered list of slots, each pointing at a
//  catalog template. Regular and miniboss slots interleave. Each TEAM carries its own
//  progression pointer into this shared list (Team.nextLineupIndex), so teams move
//  through the same sequence at different speeds.
//
//  Slots have their own identity (`id`) separate from the template, because the same
//  template may appear in the lineup more than once and MINIBOSS slots are consumed
//  GLOBALLY exactly once: a miniboss slot is "spent" when any MonsterRecord exists
//  with that slot's id (alive = the fight is on; defeated = already fought). Regular
//  slots are NOT subject to the spent rule — every team consumes them independently.
//
//  The teacher may edit the lineup at any time — including while a miniboss is active
//  (an intended feature: she uses the pause for inventory management and catch-up).
//  Edits are undoable actions and only affect FUTURE spawns.
//

import Foundation

public struct LineupSlot: Identifiable, Codable, Hashable {
    public let id: UUID
    public var templateID: UUID

    public init(id: UUID = UUID(), templateID: UUID) {
        self.id = id
        self.templateID = templateID
    }
}
