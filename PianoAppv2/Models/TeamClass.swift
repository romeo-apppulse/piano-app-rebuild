//
//  BattleClass.swift
//  PianoAppv2
//
//  Created by Rebecca Jackson on 5/19/25.
//

import Foundation

class Team: ObservableObject, Codable {
    var id = UUID()
    @Published var name: String
    @Published var minHP: Int
    @Published var maxHP: Int
    
    init(name: String, minHP: Int, maxHP: Int) {
        self.name = name
        self.minHP = minHP
        self.maxHP = maxHP
    }
    
    init() {
        self.name = "testTeam"
        self.minHP = 150
        self.maxHP = 250
    }
    
    enum CodingKeys: String, CodingKey {
        case id, name, minHP, maxHP
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        // No silent fallback: missing/corrupt HP must surface as a decode error,
        // not masquerade as a real 150/250 range.
        minHP = try container.decode(Int.self, forKey: .minHP)
        maxHP = try container.decode(Int.self, forKey: .maxHP)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(minHP, forKey: .minHP)
        try container.encode(maxHP, forKey: .maxHP)
    }
    
    func hp() -> Int {
        return Int.random(in: minHP...maxHP)
    }
}

extension Team: Hashable {
    static func == (lhs: Team, rhs: Team) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
