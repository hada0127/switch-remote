import Foundation
import GameController

struct ControllerInput: Codable, Equatable {
    var type = "input"
    var buttons: [String] = []
    var lx: Float = 0
    var ly: Float = 0
    var rx: Float = 0
    var ry: Float = 0
    static let neutral = ControllerInput()

    static func axis(_ value: Float, deadzone: Float = 0.08) -> Float {
        guard value.isFinite else { return 0 }
        let v = min(1, max(-1, value))
        guard abs(v) > deadzone else { return 0 }
        return (v < 0 ? -1 : 1) * (abs(v) - deadzone) / (1 - deadzone)
    }
    // Preserve GameController identifiers by default; optional swap supports alternate layouts.
    static func faceButtons(south: Bool, east: Bool, west: Bool, north: Bool, positional: Bool) -> [String] {
        [(south, positional ? "B" : "A"), (east, positional ? "A" : "B"),
         (west, positional ? "Y" : "X"), (north, positional ? "X" : "Y")].filter(\.0).map(\.1)
    }
    static func read(_ pad: GCExtendedGamepad, positional: Bool) -> ControllerInput {
        let p = pad.capture()
        var buttons = faceButtons(south: p.buttonA.isPressed, east: p.buttonB.isPressed,
                                  west: p.buttonX.isPressed, north: p.buttonY.isPressed, positional: positional)
        let extra: [(String, Bool)] = [
            ("L", p.leftShoulder.isPressed), ("R", p.rightShoulder.isPressed),
            ("ZL", p.leftTrigger.isPressed), ("ZR", p.rightTrigger.isPressed),
            ("PLUS", p.buttonMenu.isPressed), ("MINUS", p.buttonOptions?.isPressed ?? false),
            ("HOME", p.buttonHome?.isPressed ?? false),
            ("CAPTURE", (pad as? GCXboxGamepad)?.buttonShare?.isPressed ?? false),
            ("L_STICK_PRESS", p.leftThumbstickButton?.isPressed ?? false),
            ("R_STICK_PRESS", p.rightThumbstickButton?.isPressed ?? false),
            ("DPAD_UP", p.dpad.up.isPressed), ("DPAD_DOWN", p.dpad.down.isPressed),
            ("DPAD_LEFT", p.dpad.left.isPressed), ("DPAD_RIGHT", p.dpad.right.isPressed)
        ]
        buttons += extra.filter(\.1).map(\.0)
        return ControllerInput(buttons: buttons, lx: axis(p.leftThumbstick.xAxis.value), ly: axis(p.leftThumbstick.yAxis.value),
                               rx: axis(p.rightThumbstick.xAxis.value), ry: axis(p.rightThumbstick.yAxis.value))
    }
}

struct PiConnection: Equatable {
    var host: String
    var user: String
    var key: String
    var valid: Bool {
        host.range(of: #"^[A-Za-z0-9][A-Za-z0-9.\-]{0,252}$"#, options: .regularExpression) != nil &&
        user.range(of: #"^[a-z_][a-z0-9_\-]{0,31}$"#, options: .regularExpression) != nil &&
        key.hasPrefix("/") && !key.contains("\n")
    }
    func arguments(pair: Bool) -> [String] {
        ["-F", "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes",
         "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
         "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2",
         "-i", key, "\(user)@\(host)",
         "sudo -n /usr/bin/python3 -u /opt/videogamefilter-controller/bridge.py" + (pair ? " --pair" : "")]
    }
}
