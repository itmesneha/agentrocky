//
//  RockyView.swift
//  agentrocky
//

import SwiftUI
import AppKit

private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct ParachuteCanopy: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY * 0.72))
        p.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.maxY * 0.72),
            control1: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY - rect.height * 0.08),
            control2: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.minY - rect.height * 0.08)
        )
        p.addQuadCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.maxY * 0.72),
            control: CGPoint(x: rect.midX, y: rect.maxY * 0.96)
        )
        p.closeSubpath()
        return p
    }
}

private struct ParachuteRigging: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let canopyY = rect.minY + rect.height * 0.34
        let harnessY = rect.maxY - rect.height * 0.08
        let harnessX = rect.midX
        for anchorX in [rect.minX + rect.width * 0.24, rect.midX, rect.maxX - rect.width * 0.24] {
            p.move(to: CGPoint(x: anchorX, y: canopyY))
            p.addLine(to: CGPoint(x: harnessX, y: harnessY))
        }
        return p
    }
}

struct RockyView: View {
    @ObservedObject var state: RockyState
    let moveWindow: (CGPoint) -> Void
    let finishDrag: (CGPoint) -> Void
    let toggleSleepMode: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showChat = false
    @State private var isBreathing = false
    @State private var isLanding = false
    @State private var isLandingRecovering = false
    @State private var isCornerGripping = false
    @State private var isLookingAroundMotion = false
    @State private var isCursorPerking = false
    @State private var isSleepBubblePulsing = false
    @State private var isParachuteFloating = false

    private var currentSpriteName: String {
        if state.isSleeping { return "stand" }
        if state.isJazzing { return "jazz\(state.jazzFrameIndex + 1)" }
        if state.isChatOpen { return "stand" }
        return state.walkFrameIndex == 0 ? "walkleft1" : "walkleft2"
    }

    private var spriteRotation: Angle {
        if state.isAirborne { return .degrees(airborneTiltDegrees) }
        switch state.wall {
        case .bottom: return .degrees(activityTiltDegrees)
        case .right:  return .degrees(-90 + activityTiltDegrees)
        case .top:    return .degrees(180 + activityTiltDegrees)
        case .left:   return .degrees(90 + activityTiltDegrees)
        }
    }

    private var airborneTiltDegrees: Double {
        let horizontalTilt = Double(max(-1, min(1, state.velocityX / 360))) * 12
        let verticalTilt = Double(max(-1, min(1, state.velocityY / 520))) * -5
        return horizontalTilt + verticalTilt
    }

    private var spriteAlignment: Alignment {
        if state.isAirborne { return .center }
        switch state.wall {
        case .bottom: return .bottom
        case .right:  return .trailing
        case .top:    return .top
        case .left:   return .leading
        }
    }

    var body: some View {
        ZStack {
            Color.clear

            if let bubble = visibleBubbleText {
                speechBubbleView(bubble)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: bubbleAlignment)
                    .padding(bubblePadding)
                    .opacity(state.isSleeping && isSleepBubblePulsing ? 0.58 : 1)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity)
                    ))
            }

            if state.isParachuteOpen {
                parachuteView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.62, anchor: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 0.82, anchor: .bottom).combined(with: .opacity)
                    ))
            }

            spriteView
            .rotationEffect(spriteRotation)
            .scaleEffect(spriteScale, anchor: spriteScaleAnchor)
            .offset(y: state.isSleeping && isBreathing ? -2 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: spriteAlignment)
            .popover(isPresented: $showChat, arrowEdge: .top) {
                ChatView(session: state.session)
                    .frame(width: 420, height: 520)
            }
            .onChange(of: showChat) { open in
                state.isChatOpen = open
            }
            .onChange(of: state.isSleeping) { sleeping in
                updateBreathing(sleeping)
                updateSleepBubblePulse(sleeping)
            }
            .onChange(of: state.landingPulse) { _ in
                playLandingSquash()
            }
            .onChange(of: state.cornerGripPulse) { _ in
                playCornerGrip()
            }
            .onChange(of: state.lookAroundPulse) { _ in
                playLookAround()
            }
            .onChange(of: state.cursorHoverPulse) { _ in
                playCursorPerk()
            }
            .onChange(of: state.isParachuteOpen) { open in
                updateParachuteFloat(open)
            }

            RockyMouseView(
                state: state,
                onClick: toggleChat,
                moveWindow: moveWindow,
                finishDrag: finishDrag,
                toggleSleepMode: toggleSleepMode
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? .none : .spring(response: 0.25, dampingFraction: 0.65), value: state.speechBubble)
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.22), value: state.wall)
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.18), value: state.isAirborne)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.22), value: state.isParachuteOpen)
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.12), value: state.isDragging)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.1), value: state.isPreparingJump)
        .animation(reduceMotion ? .none : .easeInOut(duration: 0.18), value: state.isLookingAround)
        .onAppear {
            updateBreathing(state.isSleeping)
            updateSleepBubblePulse(state.isSleeping)
            updateParachuteFloat(state.isParachuteOpen)
        }
    }

    private var spriteView: some View {
        Group {
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
    }

    private var parachuteView: some View {
        ZStack {
            ParachuteRigging()
                .stroke(Color.white.opacity(0.82), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .frame(width: 74, height: 68)
                .offset(y: 3)

            ParachuteCanopy()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.94, green: 0.17, blue: 0.22),
                            Color(red: 1.0, green: 0.72, blue: 0.24)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 86, height: 42)
                .overlay(
                    ParachuteCanopy()
                        .stroke(Color.black.opacity(0.72), lineWidth: 2)
                )
                .overlay(
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.white.opacity(0.32))
                                .frame(width: 4, height: 26)
                        }
                    }
                    .offset(y: 3)
                )
                .offset(y: -14)
        }
        .frame(width: 100, height: 94)
        .offset(x: state.velocityX > 0 ? -4 : 4, y: isParachuteFloating ? -34 : -30)
        .rotationEffect(.degrees(reduceMotion ? 0 : (state.velocityX > 0 ? -3 : 3)))
        .shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 3)
        .allowsHitTesting(false)
    }

    private var spriteScale: CGSize {
        guard !reduceMotion else { return CGSize(width: 1, height: 1) }
        if isLanding {
            return CGSize(width: 1.14, height: 0.84)
        }
        if isLandingRecovering {
            return CGSize(width: 0.96, height: 1.06)
        }
        if state.isPreparingJump {
            return CGSize(width: 1.16, height: 0.78)
        }
        if isCornerGripping {
            return CGSize(width: 1.08, height: 0.92)
        }
        if state.isDragging {
            return CGSize(width: 1.08, height: 1.08)
        }
        if isCursorPerking {
            return CGSize(width: 1.08, height: 0.94)
        }
        if state.isSleeping {
            return CGSize(width: 1.0 + (isBreathing ? 0.025 : 0), height: 0.96 + (isBreathing ? 0.05 : 0))
        }
        if state.isAirborne {
            return CGSize(width: 0.96, height: 1.08)
        }
        return CGSize(width: 1, height: 1)
    }

    private var activityTiltDegrees: Double {
        guard !reduceMotion else { return 0 }
        if isLookingAroundMotion {
            return state.direction > 0 ? 5 : -5
        }
        if isCornerGripping {
            return state.clockwise ? -4 : 4
        }
        if isCursorPerking {
            return state.direction > 0 ? 3 : -3
        }
        return 0
    }

    private var spriteScaleAnchor: UnitPoint {
        if state.isAirborne || state.isDragging { return .center }
        switch state.wall {
        case .bottom: return .bottom
        case .right: return .trailing
        case .top: return .top
        case .left: return .leading
        }
    }

    private func updateBreathing(_ sleeping: Bool) {
        guard sleeping, !reduceMotion else {
            isBreathing = false
            return
        }
        isBreathing = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            isBreathing = true
        }
    }

    private func updateSleepBubblePulse(_ sleeping: Bool) {
        guard sleeping, !reduceMotion else {
            isSleepBubblePulsing = false
            return
        }
        isSleepBubblePulsing = false
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            isSleepBubblePulsing = true
        }
    }

    private func updateParachuteFloat(_ open: Bool) {
        guard open, !reduceMotion else {
            isParachuteFloating = false
            return
        }
        isParachuteFloating = false
        withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
            isParachuteFloating = true
        }
    }

    private func playLandingSquash() {
        guard !reduceMotion else { return }
        isLandingRecovering = false
        withAnimation(.easeOut(duration: 0.08)) {
            isLanding = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.1)) {
                isLanding = false
                isLandingRecovering = true
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.easeOut(duration: 0.16)) {
                isLandingRecovering = false
            }
        }
    }

    private func playCornerGrip() {
        guard !reduceMotion, !state.isDragging else { return }
        withAnimation(.easeOut(duration: 0.08)) {
            isCornerGripping = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.16)) {
                isCornerGripping = false
            }
        }
    }

    private func playLookAround() {
        guard !reduceMotion, !state.isDragging else { return }
        withAnimation(.easeOut(duration: 0.1)) {
            isLookingAroundMotion = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            withAnimation(.easeOut(duration: 0.14)) {
                isLookingAroundMotion = false
            }
        }
    }

    private func playCursorPerk() {
        guard !reduceMotion, !state.isDragging else { return }
        withAnimation(.easeOut(duration: 0.08)) {
            isCursorPerking = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            withAnimation(.easeOut(duration: 0.16)) {
                isCursorPerking = false
            }
        }
    }

    private var visibleBubbleText: String? {
        if state.isSleeping {
            return state.speechBubble
        }
        guard !state.isAirborne, state.wall == .bottom else { return nil }
        return state.speechBubble
    }

    private var bubbleAlignment: Alignment {
        guard state.isSleeping else { return .top }
        switch state.wall {
        case .bottom: return .top
        case .right: return .leading
        case .top: return .bottom
        case .left: return .trailing
        }
    }

    private var bubblePadding: EdgeInsets {
        guard state.isSleeping else {
            return EdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 8)
        }

        switch state.wall {
        case .bottom:
            return EdgeInsets(top: 8, leading: 8, bottom: 0, trailing: 8)
        case .right:
            return EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 0)
        case .top:
            return EdgeInsets(top: 0, leading: 8, bottom: 12, trailing: 8)
        case .left:
            return EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 12)
        }
    }

    @ViewBuilder
    private func speechBubbleView(_ text: String) -> some View {
        if state.isSleeping {
            Text(text)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.black)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                )
        } else {
            VStack(spacing: 0) {
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.black)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 132)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
                    )
                BubbleTail()
                    .fill(Color.white)
                    .frame(width: 14, height: 8)
            }
        }
    }
    private func toggleChat() {
        state.isChatOpen.toggle()
        showChat = state.isChatOpen
        if showChat {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct RockyMouseView: NSViewRepresentable {
    @ObservedObject var state: RockyState
    let onClick: () -> Void
    let moveWindow: (CGPoint) -> Void
    let finishDrag: (CGPoint) -> Void
    let toggleSleepMode: () -> Void

    func makeNSView(context: Context) -> MouseCatcherView {
        let view = MouseCatcherView()
        view.state = state
        view.onClick = onClick
        view.moveWindow = moveWindow
        view.finishDrag = finishDrag
        view.toggleSleepMode = toggleSleepMode
        return view
    }

    func updateNSView(_ nsView: MouseCatcherView, context: Context) {
        nsView.state = state
        nsView.onClick = onClick
        nsView.moveWindow = moveWindow
        nsView.finishDrag = finishDrag
        nsView.toggleSleepMode = toggleSleepMode
    }
}

private final class MouseCatcherView: NSView {
    weak var state: RockyState?
    var onClick: (() -> Void)?
    var moveWindow: ((CGPoint) -> Void)?
    var finishDrag: ((CGPoint) -> Void)?
    var toggleSleepMode: (() -> Void)?

    private var mouseDownScreenPoint: CGPoint?
    private var mouseDownWindowOrigin: CGPoint?
    private var hasDragged = false
    private let dragThreshold: CGFloat = 4

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        mouseDownScreenPoint = window.convertPoint(toScreen: event.locationInWindow)
        mouseDownWindowOrigin = window.frame.origin
        hasDragged = false
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        let title = state?.isSleeping == true ? "Wake Rocky" : "Sleep Rocky"
        let item = NSMenuItem(title: title, action: #selector(toggleSleepFromMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let startPoint = mouseDownScreenPoint,
              let startOrigin = mouseDownWindowOrigin
        else { return }

        let currentPoint = window.convertPoint(toScreen: event.locationInWindow)
        let deltaX = currentPoint.x - startPoint.x
        let deltaY = currentPoint.y - startPoint.y

        if !hasDragged, hypot(deltaX, deltaY) >= dragThreshold {
            hasDragged = true
            state?.isDragging = true
        }

        guard hasDragged else { return }
        moveWindow?(CGPoint(x: startOrigin.x + deltaX, y: startOrigin.y + deltaY))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            state?.isDragging = false
            mouseDownScreenPoint = nil
            mouseDownWindowOrigin = nil
            hasDragged = false
        }

        guard hasDragged, let window else {
            onClick?()
            return
        }

        finishDrag?(window.frame.origin)
    }

    @objc private func toggleSleepFromMenu() {
        toggleSleepMode?()
    }
}
