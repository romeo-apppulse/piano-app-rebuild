//
//  CongratsOverlay.swift
//  PianoApp
//
//  The kid-friendly "monster defeated" moment: a burst of confetti + a big YOU WON!
//  Shown for a couple of seconds (input is locked by the battle screen) so students
//  register the win before the next monster is revealed.
//

import SwiftUI

struct CongratsOverlay: View {
    @State private var appear = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            ConfettiView()
            VStack(spacing: 12) {
                Text("YOU WON!")
                    .font(.system(size: 96, weight: .heavy, design: .rounded))
                Text("🎉")
                    .font(.system(size: 96))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .scaleEffect(appear ? 1 : 0.3)
            .opacity(appear ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { appear = true }
        }
    }
}

private struct ConfettiView: View {
    private let emojis = ["🎉", "⭐️", "🎊", "✨", "🏆", "🎈", "🌟"]
    private let count = 44

    @State private var falling = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    Text(emojis[index % emojis.count])
                        .font(.system(size: CGFloat.random(in: 22...40)))
                        .position(x: CGFloat.random(in: 0...geo.size.width),
                                  y: falling ? geo.size.height + 60 : -60)
                        .animation(.easeIn(duration: Double.random(in: 1.6...2.8))
                                    .delay(Double(index) * 0.02), value: falling)
                }
            }
            .onAppear { falling = true }
        }
        .allowsHitTesting(false)
    }
}
