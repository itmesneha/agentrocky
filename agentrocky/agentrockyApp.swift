//
//  agentrockyApp.swift
//  agentrocky
//

import SwiftUI
import AppKit

@main
struct agentrockyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var rockyWindow: NSPanel?
    var rockyState = RockyState()

    // Walk state
    private var walkTimer: Timer?
    private var frameTimer: Timer?
    private let rockyWidth: CGFloat = 80
    private let rockyHeight: CGFloat = 80
    private let walkSpeed: CGFloat = 100  // points per second
    private var lastTick: Date = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupRockyWindow()
        startWalking()
    }

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

        // Sit Rocky on top of the dock
        if let screen = NSScreen.main {
            let dockTop = screen.visibleFrame.minY
            let startX = screen.frame.midX - rockyWidth / 2
            panel.setFrameOrigin(NSPoint(x: startX, y: dockTop))
            rockyState.positionX = startX
            rockyState.screenBounds = screen.frame
            rockyState.dockY = dockTop
        }

        let contentView = NSHostingView(rootView: RockyView(state: rockyState))
        contentView.frame = panel.contentView!.bounds
        contentView.autoresizingMask = [.width, .height]
        panel.contentView = contentView

        panel.makeKeyAndOrderFront(nil)
        rockyWindow = panel
    }

    func startWalking() {
        lastTick = Date()

        // Position update at ~60fps
        walkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updatePosition()
        }

        // Sprite frame swap at ~6fps
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 6.0, repeats: true) { [weak self] _ in
            self?.updateWalkFrame()
        }
    }

    private func updatePosition() {
        let now = Date()
        defer { lastTick = now }
        guard !rockyState.isChatOpen else { return }

        let dt = now.timeIntervalSince(lastTick)

        let screen = rockyState.screenBounds
        let maxX = screen.maxX - rockyWidth
        let minX = screen.minX

        rockyState.positionX += CGFloat(dt) * walkSpeed * rockyState.direction

        if rockyState.positionX >= maxX {
            rockyState.positionX = maxX
            rockyState.direction = -1
        } else if rockyState.positionX <= minX {
            rockyState.positionX = minX
            rockyState.direction = 1
        }

        rockyWindow?.setFrameOrigin(NSPoint(x: rockyState.positionX, y: rockyState.dockY))
    }

    private func updateWalkFrame() {
        guard !rockyState.isChatOpen else { return }
        rockyState.walkFrameIndex = (rockyState.walkFrameIndex + 1) % 2
    }
}
