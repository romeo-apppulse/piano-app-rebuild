//
//  AttackSheet.swift
//  PianoApp
//
//  The big-target attack flow: pick who practiced, punch in the amount, attack. Wired
//  straight to GameStore.attack (the typed engine call). The result is handed back so
//  the battle screen can fire the congrats moment on a kill.
//

import SwiftUI
import PianoCore

struct AttackSheet: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss

    let target: MonsterRecord
    let attackers: [Student]
    let onResolved: (Result<AttackResult, EngineError>) -> Void

    @State private var studentID: UUID?
    @State private var input = ""

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 16)]
    private let padColumns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 3)

    var body: some View {
        VStack(spacing: 24) {
            Text("Who practiced?").font(.title.bold())

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(attackers) { student in
                    Button { studentID = student.id; input = "" } label: {
                        Text(student.name)
                            .font(.title2.bold())
                            .frame(maxWidth: .infinity, minHeight: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(studentID == student.id ? .accentColor : .gray)
                }
            }

            if studentID != nil {
                Divider()
                Text(input.isEmpty ? "0" : input)
                    .font(.system(size: 72, weight: .heavy, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .contentTransition(.numericText())

                LazyVGrid(columns: padColumns, spacing: 16) {
                    ForEach(1...9, id: \.self) { key(String($0)) }
                    Button { input = String(input.dropLast()) } label: {
                        Image(systemName: "delete.left").font(.title).frame(maxWidth: .infinity, minHeight: 72)
                    }.buttonStyle(.bordered)
                    key("0")
                    Button("Attack!") { attack() }
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        // > 0, not just non-nil: a 0-damage entry is meaningless log
                        // noise one fat-finger away.
                        .disabled((Int(input) ?? 0) <= 0)
                        .accessibilityIdentifier("attack.confirm")
                }
            }
            Spacer()
            Button("Cancel") { dismiss() }.padding(.bottom)
        }
        .padding(24)
    }

    private func key(_ digit: String) -> some View {
        Button {
            // Cap length so a fat-fingered giant number can't be entered.
            if input.count < 5 { input += digit }
        } label: {
            Text(digit).font(.largeTitle.bold()).frame(maxWidth: .infinity, minHeight: 72)
        }
        .buttonStyle(.bordered)
    }

    private func attack() {
        guard let studentID, let amount = Int(input) else { return }
        let result = store.attack(targetRecordID: target.id, studentID: studentID, amount: amount)
        onResolved(result)
        dismiss()
    }
}
