//
//  GameSettingsView.swift
//  PianoApp
//
//  The configurable game numbers (spec: kill-target "default 3, configurable",
//  miniboss "default 6, configurable"). These are DEFAULTS for future spawns and
//  triggers — an alive monster froze its own kill-target at spawn and is changed
//  per-monster in Backdoor Controls instead.
//

import SwiftUI
import PianoCore

struct GameSettingsView: View {
    @EnvironmentObject private var store: GameStore

    private var settings: GameSettings { store.state.settings }

    var body: some View {
        List {
            Section("Kill targets (defaults for future monsters)") {
                Stepper("Regular: \(settings.defaultKillTargetWeeks) week\(settings.defaultKillTargetWeeks == 1 ? "" : "s")",
                        onIncrement: { store.updateSettings { $0.defaultKillTargetWeeks += 1 } },
                        onDecrement: { store.updateSettings { if $0.defaultKillTargetWeeks > 1 { $0.defaultKillTargetWeeks -= 1 } } })
                    .font(.title3)
                Stepper("Miniboss: \(settings.minibossKillTargetWeeks) week\(settings.minibossKillTargetWeeks == 1 ? "" : "s")",
                        onIncrement: { store.updateSettings { $0.minibossKillTargetWeeks += 1 } },
                        onDecrement: { store.updateSettings { if $0.minibossKillTargetWeeks > 1 { $0.minibossKillTargetWeeks -= 1 } } })
                    .font(.title3)
                Text("Applies to monsters spawned from now on. The current monster's kill target is changed in Backdoor Controls.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Minimum monster HP") {
                Stepper("Floor: \(settings.minimumMonsterHP) HP",
                        onIncrement: { store.updateSettings { $0.minimumMonsterHP += 1 } },
                        onDecrement: { store.updateSettings { if $0.minimumMonsterHP > 1 { $0.minimumMonsterHP -= 1 } } })
                    .font(.title3)
                Text("A monster never spawns with less than this — protects brand-new teams whose practice averages are still 0.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Migration") {
                Toggle("Seed leaderboards from old scores", isOn: Binding(
                    get: { settings.seedLeaderboardsFromLegacyScore },
                    set: { on in store.updateSettings { $0.seedLeaderboardsFromLegacyScore = on } }
                ))
                .font(.title3)
                Text("Used only when old-app data is migrated on first launch. Seeds show on the leaderboards but never count toward daily averages. Awaiting the client's final word — has no effect after migration has already run.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Game Settings")
    }
}
