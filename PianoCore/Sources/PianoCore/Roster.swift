//
//  Roster.swift — Students and Teams.
//
//  Value types with stable UUID identity. Every cross-reference is a typed UUID,
//  never a name string (the old app keyed identity by name, which caused silent
//  re-linking bugs). Names are display-only and may be edited freely.
//

import Foundation

public struct Student: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    /// Stable foreign key to a Team; nil means unassigned.
    public var teamID: UUID?
    /// Anchors the "all-time, since added" leaderboard. Set once at creation.
    public let createdAt: Date
    /// Soft-delete: hide from active rosters but never destroy history.
    public var isActive: Bool

    public init(id: UUID = UUID(),
                name: String,
                teamID: UUID? = nil,
                createdAt: Date,
                isActive: Bool = true) {
        self.id = id
        self.name = name
        self.teamID = teamID
        self.createdAt = createdAt
        self.isActive = isActive
    }
}

public struct Team: Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String

    // Legacy minHP/maxHP are intentionally dropped: monster HP is no longer a random
    // roll, it is derived from team members' practice averages (see MonsterMath).
    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
