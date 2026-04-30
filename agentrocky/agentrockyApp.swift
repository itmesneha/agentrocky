//
//  agentrockyApp.swift
//  agentrocky
//

import SwiftUI
import AppKit
import Combine
import UserNotifications

@main
struct agentrockyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

private extension Bool {
    static func random(probability: Double) -> Bool {
        Double.random(in: 0...1) < probability
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var rockyWindow: NSPanel?
    var rockyState = RockyState()

    private var walkTimer: Timer?
    private var frameTimer: Timer?
    private var cursorTimer: Timer?
    private let rockyWidth: CGFloat = 180
    private let rockyHeight: CGFloat = 140
    private let baseWalkSpeed: CGFloat = 100
    private let jumpSpeed: CGFloat = 420
    private let fallGravity: CGFloat = -980
    private let parachuteGravity: CGFloat = -260
    private let parachuteTerminalFallSpeed: CGFloat = -150
    private let parachuteDeployFallSpeed: CGFloat = -210
    private let cursorNoticeDistance: CGFloat = 280
    private let cursorFacingMinDistance: CGFloat = 150
    private let cursorFacingAxisThreshold: CGFloat = 56
    private let cursorFacingCooldown: TimeInterval = 0.35
    private var currentWalkSpeed: CGFloat = 100
    private var lastTick: Date = Date()
    private var lastCursorFacingAt = Date.distantPast

    private var jazzWorkItem: DispatchWorkItem?
    private var bubbleWorkItem: DispatchWorkItem?
    private var jumpWorkItem: DispatchWorkItem?
    private var jumpLaunchWorkItem: DispatchWorkItem?
    private var decisionWorkItem: DispatchWorkItem?
    private var lookAroundWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    private let workingMessages = ["working", "building", "thinking"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        requestNotificationAuthorization()
        setupRockyWindow()
        startWalking()
        startCursorTracking()
        setupJazzTriggers()
        setupSpeechBubble()
        scheduleRandomDecision(firstRun: true)
        scheduleRandomJump(firstRun: true)
        scheduleRandomLookAround(firstRun: true)
    }

    // MARK: - Window

    func setupRockyWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: rockyWidth, height: rockyHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        if let screen = NSScreen.main {
            let bounds = screen.visibleFrame
            let startX = bounds.midX - rockyWidth / 2
            let startY = bounds.minY
            panel.setFrameOrigin(NSPoint(x: startX, y: startY))
            rockyState.positionX = startX
            rockyState.positionY = startY
            rockyState.screenBounds = bounds
            rockyState.dockY = startY
            rockyState.wall = .bottom
        }

        let contentView = NSHostingView(rootView: RockyView(
            state: rockyState,
            moveWindow: { [weak self] origin in self?.moveRocky(to: origin) },
            finishDrag: { [weak self] origin in self?.finishRockyDrag(at: origin) },
            toggleSleepMode: { [weak self] in self?.toggleSleepMode() }
        ))
        contentView.frame = panel.contentView!.bounds
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView

        panel.makeKeyAndOrderFront(nil)
        rockyWindow = panel
    }

    // MARK: - Walk

    func startWalking() {
        lastTick = Date()

        walkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
    }

    private func startCursorTracking() {
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.updateCursorAwareness()
        }
    }

    private func updateCursorAwareness() {
        guard let frame = rockyWindow?.frame, !rockyState.isDragging else {
            clearCursorAwareness()
            return
        }

        let mouse = NSEvent.mouseLocation
        guard !frame.contains(mouse) else {
            clearCursorAwareness()
            return
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let dx = mouse.x - center.x
        let dy = mouse.y - center.y
        let distance = max(1, hypot(dx, dy))
        let rawProximity = (cursorNoticeDistance - distance) / (cursorNoticeDistance - cursorFacingMinDistance)
        let proximity = min(1, max(0, rawProximity))

        if proximity <= 0 || distance < cursorFacingMinDistance {
            clearCursorAwareness()
            return
        }

        rockyState.cursorVectorX = dx / distance
        rockyState.cursorVectorY = dy / distance
        rockyState.cursorProximity = proximity

        if !rockyState.isSleeping,
           !rockyState.isAirborne,
           !rockyState.isPreparingJump,
           !rockyState.isLookingAround,
           distance >= cursorFacingMinDistance,
           proximity > 0.22,
           Date().timeIntervalSince(lastCursorFacingAt) > cursorFacingCooldown {
            lastCursorFacingAt = Date()
            turnTowardCursor(dx: dx, dy: dy)
        }
    }

    private func clearCursorAwareness() {
        if rockyState.cursorProximity != 0 {
            rockyState.cursorProximity = 0
            rockyState.cursorVectorX = 0
            rockyState.cursorVectorY = 0
        }
    }

    private func turnTowardCursor(dx: CGFloat, dy: CGFloat) {
        let newDirection: CGFloat
        switch rockyState.wall {
        case .bottom:
            guard abs(dx) >= cursorFacingAxisThreshold else { return }
            newDirection = dx >= 0 ? 1 : -1
        case .top:
            guard abs(dx) >= cursorFacingAxisThreshold else { return }
            newDirection = dx >= 0 ? -1 : 1
        case .left:
            guard abs(dy) >= cursorFacingAxisThreshold else { return }
            newDirection = dy >= 0 ? -1 : 1
        case .right:
            guard abs(dy) >= cursorFacingAxisThreshold else { return }
            newDirection = dy >= 0 ? 1 : -1
        }

        if rockyState.direction != newDirection {
            rockyState.direction = newDirection
        }
    }

    private func updatePosition() {
        let now = Date()
        defer { lastTick = now }
        guard !rockyState.isChatOpen,
              !rockyState.isJazzing,
              !rockyState.isDragging,
              !rockyState.isSleeping,
              !rockyState.isPreparingJump,
              !rockyState.isLookingAround else { return }

        let dt = now.timeIntervalSince(lastTick)
        if rockyState.isAirborne {
            updateAirbornePosition(dt: CGFloat(dt))
        } else {
            advanceAlongWall(by: CGFloat(dt) * currentWalkSpeed)
        }
        rockyWindow?.setFrameOrigin(NSPoint(x: rockyState.positionX, y: rockyState.positionY))
    }

    private func updateAirbornePosition(dt: CGFloat) {
        let bounds = rockyState.screenBounds
        let minX = bounds.minX
        let maxX = bounds.maxX - rockyWidth
        let minY = bounds.minY
        let maxY = bounds.maxY - rockyHeight

        updateParachuteState()

        let gravity = rockyState.isParachuteOpen ? parachuteGravity : fallGravity
        rockyState.velocityY += gravity * dt
        if rockyState.isParachuteOpen {
            rockyState.velocityY = max(rockyState.velocityY, parachuteTerminalFallSpeed)
            rockyState.velocityX *= 0.992
        }

        rockyState.positionX += rockyState.velocityX * dt
        rockyState.positionY += rockyState.velocityY * dt

        if rockyState.positionY <= minY {
            rockyState.positionY = minY
            land(on: .bottom)
        } else if rockyState.positionY >= maxY {
            rockyState.positionY = maxY
            land(on: .top)
        }

        if rockyState.positionX <= minX {
            rockyState.positionX = minX
            land(on: .left)
        } else if rockyState.positionX >= maxX {
            rockyState.positionX = maxX
            land(on: .right)
        }

        if rockyState.isAirborne {
            rockyState.direction = rockyState.velocityX >= 0 ? 1 : -1
        }
    }

    private func updateParachuteState() {
        guard rockyState.isAirborne, rockyState.parachuteEligible else {
            rockyState.isParachuteOpen = false
            return
        }

        let isFallingFast = rockyState.velocityY <= parachuteDeployFallSpeed
        let hasRoomToFloat = rockyState.positionY > rockyState.screenBounds.minY + rockyHeight * 1.35
        rockyState.isParachuteOpen = isFallingFast && hasRoomToFloat
    }

    private func land(on wall: RockyWall) {
        rockyState.wall = wall
        rockyState.isAirborne = false
        rockyState.isParachuteOpen = false
        rockyState.parachuteEligible = false
        rockyState.clockwise = clockwiseAfterLanding(on: wall)
        rockyState.velocityX = 0
        rockyState.velocityY = 0
        randomizeWalkSpeed()
        rockyState.landingPulse += 1
        updateSpriteFacing()
    }

    private func clockwiseAfterLanding(on wall: RockyWall) -> Bool {
        switch wall {
        case .bottom:
            return rockyState.velocityX >= 0
        case .top:
            return rockyState.velocityX < 0
        case .left:
            return rockyState.velocityY <= 0
        case .right:
            return rockyState.velocityY >= 0
        }
    }

    private func advanceAlongWall(by distance: CGFloat) {
        let bounds = rockyState.screenBounds
        let minX = bounds.minX
        let maxX = bounds.maxX - rockyWidth
        let minY = bounds.minY
        let maxY = bounds.maxY - rockyHeight
        let delta = max(0, distance)
        let previousWall = rockyState.wall

        switch (rockyState.wall, rockyState.clockwise) {
        case (.bottom, true):
            rockyState.positionX += delta
            if rockyState.positionX >= maxX {
                rockyState.positionX = maxX
                rockyState.wall = .right
            }
        case (.right, true):
            rockyState.positionY += delta
            if rockyState.positionY >= maxY {
                rockyState.positionY = maxY
                rockyState.wall = .top
            }
        case (.top, true):
            rockyState.positionX -= delta
            if rockyState.positionX <= minX {
                rockyState.positionX = minX
                rockyState.wall = .left
            }
        case (.left, true):
            rockyState.positionY -= delta
            if rockyState.positionY <= minY {
                rockyState.positionY = minY
                rockyState.wall = .bottom
            }
        case (.bottom, false):
            rockyState.positionX -= delta
            if rockyState.positionX <= minX {
                rockyState.positionX = minX
                rockyState.wall = .left
            }
        case (.left, false):
            rockyState.positionY += delta
            if rockyState.positionY >= maxY {
                rockyState.positionY = maxY
                rockyState.wall = .top
            }
        case (.top, false):
            rockyState.positionX += delta
            if rockyState.positionX >= maxX {
                rockyState.positionX = maxX
                rockyState.wall = .right
            }
        case (.right, false):
            rockyState.positionY -= delta
            if rockyState.positionY <= minY {
                rockyState.positionY = minY
                rockyState.wall = .bottom
            }
        }

        if rockyState.wall != previousWall {
            rockyState.cornerGripPulse += 1
        }
        updateSpriteFacing()
    }

    private func moveRocky(to origin: CGPoint) {
        let clamped = clampedOrigin(origin)
        rockyState.positionX = clamped.x
        rockyState.positionY = clamped.y
        rockyWindow?.setFrameOrigin(clamped)
    }

    private func finishRockyDrag(at origin: CGPoint) {
        rockyState.isAirborne = false
        rockyState.isParachuteOpen = false
        rockyState.parachuteEligible = false
        rockyState.isPreparingJump = false
        rockyState.isLookingAround = false
        rockyState.velocityX = 0
        rockyState.velocityY = 0
        jumpLaunchWorkItem?.cancel()
        moveRocky(to: origin)
        snapRockyToNearestWall()
        rockyWindow?.setFrameOrigin(NSPoint(x: rockyState.positionX, y: rockyState.positionY))
    }

    private func snapRockyToNearestWall() {
        let bounds = rockyState.screenBounds
        let minX = bounds.minX
        let maxX = bounds.maxX - rockyWidth
        let minY = bounds.minY
        let maxY = bounds.maxY - rockyHeight
        let x = min(max(rockyState.positionX, minX), maxX)
        let y = min(max(rockyState.positionY, minY), maxY)

        let distances: [(RockyWall, CGFloat)] = [
            (.bottom, abs(y - minY)),
            (.top, abs(y - maxY)),
            (.left, abs(x - minX)),
            (.right, abs(x - maxX)),
        ]
        let nearestWall = distances.min { $0.1 < $1.1 }?.0 ?? .bottom

        rockyState.wall = nearestWall
        switch nearestWall {
        case .bottom:
            rockyState.positionX = x
            rockyState.positionY = minY
        case .top:
            rockyState.positionX = x
            rockyState.positionY = maxY
        case .left:
            rockyState.positionX = minX
            rockyState.positionY = y
        case .right:
            rockyState.positionX = maxX
            rockyState.positionY = y
        }
        updateSpriteFacing()
    }

    private func clampedOrigin(_ origin: CGPoint) -> NSPoint {
        let bounds = rockyState.screenBounds
        let maxX = bounds.maxX - rockyWidth
        let maxY = bounds.maxY - rockyHeight
        return NSPoint(
            x: min(max(origin.x, bounds.minX), maxX),
            y: min(max(origin.y, bounds.minY), maxY)
        )
    }

    private func updateSpriteFacing() {
        if rockyState.isAirborne {
            rockyState.direction = rockyState.velocityX >= 0 ? 1 : -1
            return
        }
        switch rockyState.wall {
        case .bottom:
            rockyState.direction = rockyState.clockwise ? 1 : -1
        case .top:
            rockyState.direction = rockyState.clockwise ? -1 : 1
        case .left:
            rockyState.direction = 1
        case .right:
            rockyState.direction = -1
        }
    }

    private func updateFrame() {
        if rockyState.isJazzing {
            rockyState.jazzFrameIndex = (rockyState.jazzFrameIndex + 1) % 3
        } else if !rockyState.isChatOpen, !rockyState.isSleeping {
            rockyState.walkFrameIndex = (rockyState.walkFrameIndex + 1) % 2
        }
    }

    // MARK: - Jazz

    private func setupJazzTriggers() {
        // Jazz when a Claude task finishes
        rockyState.session.$isRunning
            .removeDuplicates()
            .dropFirst()                    // skip the initial false
            .filter { !$0 }                 // only when it becomes false (task done)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.startJazz(duration: 3.0)
                self?.sendTaskCompleteNotification()
            }
            .store(in: &cancellables)

        // Random jazz while idle
        scheduleRandomJazz()
    }

    private func setupSpeechBubble() {
        rockyState.session.$isRunning
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                guard let self else { return }
                self.bubbleWorkItem?.cancel()
                if running {
                    self.wakeRocky(showBubble: false)
                    withAnimation {
                        self.rockyState.speechBubble = self.workingMessages.randomElement()!
                    }
                } else {
                    withAnimation {
                        self.rockyState.speechBubble = "rocky done!"
                    }
                    let work = DispatchWorkItem { [weak self] in
                        withAnimation { self?.rockyState.speechBubble = nil }
                    }
                    self.bubbleWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
                }
            }
            .store(in: &cancellables)
    }

    func startJazz(duration: TimeInterval) {
        guard !rockyState.isJazzing else { return }
        rockyState.isJazzing = true

        jazzWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rockyState.isJazzing = false
        }
        jazzWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func scheduleRandomJazz() {
        let delay = Double.random(in: 15...45)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if !self.rockyState.isChatOpen,
               !self.rockyState.isAirborne,
               !self.rockyState.isSleeping {
                self.startJazz(duration: 2.0)
            }
            self.scheduleRandomJazz()
        }
    }

    // MARK: - Jump / fall

    private func scheduleRandomJump(firstRun: Bool = false) {
        let delay = firstRun ? Double.random(in: 4...8) : Double.random(in: 14...30)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
	            if !self.rockyState.isChatOpen,
	               !self.rockyState.isJazzing,
	               !self.rockyState.isDragging,
	               !self.rockyState.isAirborne,
                   !self.rockyState.isPreparingJump,
                   !self.rockyState.isLookingAround,
                   !self.rockyState.isSleeping {
                self.startJump()
            }
            self.scheduleRandomJump()
        }
        jumpWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startJump() {
        guard !rockyState.isPreparingJump,
              !rockyState.isAirborne,
              !rockyState.isSleeping,
              !rockyState.isDragging else { return }

        rockyState.isPreparingJump = true
        jumpLaunchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.launchJump()
        }
        jumpLaunchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func launchJump() {
        guard rockyState.isPreparingJump,
              !rockyState.isChatOpen,
              !rockyState.isJazzing,
              !rockyState.isDragging,
              !rockyState.isAirborne,
              !rockyState.isSleeping else {
            rockyState.isPreparingJump = false
            return
        }

        rockyState.isPreparingJump = false
        rockyState.isAirborne = true
        let highJump = Bool.random(probability: 0.32)
        rockyState.parachuteEligible = highJump
        rockyState.isParachuteOpen = false

        let tangent = rockyState.clockwise ? CGFloat(1) : CGFloat(-1)
        let lift = highJump ? CGFloat.random(in: 1.28...1.48) : 1
        let drift = highJump ? CGFloat.random(in: 0.82...1.05) : 1
        switch rockyState.wall {
        case .bottom:
            rockyState.velocityX = tangent * currentWalkSpeed * 1.2 * drift
            rockyState.velocityY = jumpSpeed * lift
        case .top:
            rockyState.velocityX = -tangent * currentWalkSpeed * 1.2 * drift
            rockyState.velocityY = -jumpSpeed * 0.55
            rockyState.parachuteEligible = false
        case .left:
            rockyState.velocityX = jumpSpeed * 0.65 * drift
            rockyState.velocityY = (tangent * currentWalkSpeed * 1.1 + 120) * lift
        case .right:
            rockyState.velocityX = -jumpSpeed * 0.65 * drift
            rockyState.velocityY = (-tangent * currentWalkSpeed * 1.1 + 120) * lift
        }

        updateSpriteFacing()
    }

    private func scheduleRandomDecision(firstRun: Bool = false) {
        let delay = firstRun ? Double.random(in: 2...5) : Double.random(in: 3...8)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.makeMovementDecision()
            self.scheduleRandomDecision()
        }
        decisionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makeMovementDecision() {
        guard !rockyState.isChatOpen,
              !rockyState.isJazzing,
              !rockyState.isDragging,
              !rockyState.isAirborne,
              !rockyState.isPreparingJump,
              !rockyState.isLookingAround,
              !rockyState.isSleeping else { return }

        switch Int.random(in: 0..<100) {
        case 0..<42:
            reverseWalkDirection()
        case 42..<72:
            randomizeWalkSpeed()
        case 72..<88:
            startJump()
        default:
            break
        }
    }

    private func reverseWalkDirection() {
        rockyState.clockwise.toggle()
        randomizeWalkSpeed()
        updateSpriteFacing()

    }

    private func randomizeWalkSpeed() {
        currentWalkSpeed = baseWalkSpeed * CGFloat.random(in: 0.65...1.45)
    }

    private func scheduleRandomLookAround(firstRun: Bool = false) {
        let delay = firstRun ? Double.random(in: 5...9) : Double.random(in: 10...22)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.performLookAround()
            self.scheduleRandomLookAround()
        }
        lookAroundWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performLookAround() {
        guard !rockyState.isChatOpen,
              !rockyState.isJazzing,
              !rockyState.isDragging,
              !rockyState.isAirborne,
              !rockyState.isPreparingJump,
              !rockyState.isSleeping else { return }

        rockyState.isLookingAround = true
        rockyState.lookAroundPulse += 1
        let originalDirection = rockyState.direction

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self, self.rockyState.isLookingAround else { return }
            self.rockyState.direction = -originalDirection
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) { [weak self] in
            guard let self, self.rockyState.isLookingAround else { return }
            self.rockyState.direction = originalDirection
            self.rockyState.lookAroundPulse += 1
            self.rockyState.isLookingAround = false
            self.updateSpriteFacing()
        }
    }

    func toggleSleepMode() {
        if rockyState.isSleeping {
            wakeRocky(showBubble: true)
        } else {
            putRockyToSleep()
        }
    }

    private func putRockyToSleep() {
        rockyState.isSleeping = true
        rockyState.isAirborne = false
        rockyState.isParachuteOpen = false
        rockyState.parachuteEligible = false
        rockyState.isJazzing = false
        rockyState.isPreparingJump = false
        rockyState.isLookingAround = false
        rockyState.velocityX = 0
        rockyState.velocityY = 0
        jazzWorkItem?.cancel()
        jumpLaunchWorkItem?.cancel()
        bubbleWorkItem?.cancel()
        withAnimation {
            rockyState.speechBubble = "zzz"
        }
    }

    private func wakeRocky(showBubble: Bool) {
        guard rockyState.isSleeping else { return }
        rockyState.isSleeping = false
        bubbleWorkItem?.cancel()

        if showBubble {
            withAnimation {
                rockyState.speechBubble = "awake"
            }
            let work = DispatchWorkItem { [weak self] in
                withAnimation { self?.rockyState.speechBubble = nil }
            }
            bubbleWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        } else {
            withAnimation {
                rockyState.speechBubble = nil
            }
        }
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendTaskCompleteNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Rocky finished"
        content.body = "rocky done!"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "rocky-task-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
