//
//  RockyView.swift
//  agentrocky
//

import SwiftUI

struct RockyView: View {
    @ObservedObject var state: RockyState
    @State private var showChat = false

    private var currentSpriteName: String {
        if state.isChatOpen { return "stand" }
        return state.walkFrameIndex == 0 ? "walkleft1" : "walkleft2"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear

            Button(action: {
                state.isChatOpen.toggle()
                showChat = state.isChatOpen
                if showChat {
                    // Activate app so the popover can receive keyboard input
                    NSApp.activate(ignoringOtherApps: true)
                }
            }) {
                if let img = NSImage(named: currentSpriteName) {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 80, height: 80)
                        .scaleEffect(x: state.direction > 0 ? -1 : 1, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: 60, height: 60)
                        .overlay(Text("R").foregroundColor(.white).font(.title))
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showChat, arrowEdge: .top) {
                ChatView(session: state.session)
                    .frame(width: 420, height: 520)
            }
            .onChange(of: showChat) { open in
                state.isChatOpen = open
            }
        }
    }
}
