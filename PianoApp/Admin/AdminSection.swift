//
//  AdminSection.swift
//  PianoApp
//
//  The teacher admin sidebar's destinations. Kept as one enum so the sidebar list and
//  the detail switch can never drift out of sync.
//

import Foundation

enum AdminSection: String, CaseIterable, Identifiable, Hashable {
    case roster
    case teams
    case catalog
    case lineup
    case averages
    case backdoor
    case backup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roster:   return "Roster"
        case .teams:    return "Teams"
        case .catalog:  return "Monster Catalog"
        case .lineup:   return "Lineup"
        case .averages: return "Daily Averages"
        case .backdoor: return "Backdoor Controls"
        case .backup:   return "Backup & Restore"
        }
    }

    var symbol: String {
        switch self {
        case .roster:   return "person.3.fill"
        case .teams:    return "flag.2.crossed.fill"
        case .catalog:  return "square.stack.3d.up.fill"
        case .lineup:   return "list.number"
        case .averages: return "chart.bar.fill"
        case .backdoor: return "slider.horizontal.3"
        case .backup:   return "externaldrive.fill"
        }
    }
}
