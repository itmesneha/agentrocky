//
//  RockyState.swift
//  agentrocky
//

import SwiftUI
import Combine
import Darwin

enum RockyWall {
    case bottom
    case right
    case top
    case left
}

/// Shared observable state between AppDelegate (walk logic) and RockyView (display).
class RockyState: ObservableObject {
    @Published var walkFrameIndex: Int = 0
    @Published var jazzFrameIndex: Int = 0
    @Published var isJazzing: Bool = false
    @Published var direction: CGFloat = 1
    @Published var isChatOpen: Bool = false
    @Published var isDragging: Bool = false
    @Published var isAirborne: Bool = false
    @Published var isParachuteOpen: Bool = false
    @Published var isSleeping: Bool = false
    @Published var isPreparingJump: Bool = false
    @Published var isLookingAround: Bool = false
    @Published var landingPulse: Int = 0
    @Published var cornerGripPulse: Int = 0
    @Published var lookAroundPulse: Int = 0
    @Published var cursorProximity: CGFloat = 0
    @Published var cursorVectorX: CGFloat = 0
    @Published var cursorVectorY: CGFloat = 0
    @Published var cursorHoverPulse: Int = 0
    @Published var wall: RockyWall = .bottom
    @Published var positionX: CGFloat = 0
    @Published var positionY: CGFloat = 0
    var velocityX: CGFloat = 0
    var velocityY: CGFloat = 0
    var parachuteEligible: Bool = false
    @Published var speechBubble: String? = nil
    var clockwise: Bool = Bool.random()
    var screenBounds: CGRect = .zero
    var dockY: CGFloat = 0

    /// Single persistent Claude session — survives popover open/close.
    lazy var session: ClaudeSession = ClaudeSession(workingDirectory: realHome)

    private var realHome: String {
        getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir, encoding: .utf8) }
            ?? NSHomeDirectory()
    }
}
