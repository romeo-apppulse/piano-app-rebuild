//
//  RootView.swift
//  PianoApp
//
//  The app's primary surface is the immersive battle screen (kid-facing, big targets).
//  The teacher admin is a gated cover reached via the gear, so it never gets in the
//  students' way during a lesson.
//

import SwiftUI

struct RootView: View {
    @State private var showAdmin = false

    var body: some View {
        BattleScreen(showAdmin: $showAdmin)
            .fullScreenCover(isPresented: $showAdmin) {
                AdminRootView()
            }
    }
}
