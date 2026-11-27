import Foundation
import GameController
import CoreHaptics
import ChiakiCore

/// Game controller → Remote Play controller state, plus the console's rumble and adaptive
/// trigger effects back to the controller. A DualSense paired with the headset maps one to one
/// (touchpad and its click, Create, Options, PS); other extended gamepads get the face buttons,
/// sticks, triggers and menu buttons.
///
/// Input is read in the controller's value-changed handler on a private queue and sent to
/// chiaki immediately (chiaki batches it onto the network itself).
final class RemotePlayInput {
    private let queue = DispatchQueue(label: "rp.input", qos: .userInteractive)
    private weak var session: ChiakiSession?
    private var controller: GCController?
    private var observers: [NSObjectProtocol] = []
    var motionEnabled = false
    var triggerEffectsEnabled = true

    // Touchpad bookkeeping (chiaki wants a 7-bit id per finger, new id per touch).
    private var nextTouchID: Int8 = 0
    private var touchIDs: [Int8] = [-1, -1]

    private var rumble: Rumble?

    /// Name of the controller in use, for the UI.
    private(set) var controllerName: String?
    var onControllerChange: ((String?) -> Void)?

    init() {}

    func start(session: ChiakiSession) {
        self.session = session
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.pickController() })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.pickController() })
        observers.append(nc.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in self?.pickController() })
        pickController()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        detach()
        session = nil
    }

    private func pickController() {
        let candidate = GCController.current?.extendedGamepad != nil ? GCController.current
            : GCController.controllers().first { $0.extendedGamepad != nil }
        guard candidate !== controller else { return }
        detach()
        guard let c = candidate, let pad = c.extendedGamepad else {
            controllerName = nil
            onControllerChange?(nil)
            DiagLog.log("no game controller connected", "rp")
            return
        }
        controller = c
        c.handlerQueue = queue
        // Keep the PS / Create / Options buttons for the game instead of the system.
        for button in [pad.buttonHome, pad.buttonOptions, pad.buttonMenu] {
            button?.preferredSystemGestureState = .disabled
        }
        pad.valueChangedHandler = { [weak self] pad, _ in self?.send(pad) }
        if motionEnabled, let motion = c.motion {
            if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
            motion.valueChangedHandler = { [weak self] _ in
                guard let self, let pad = self.controller?.extendedGamepad else { return }
                self.send(pad)
            }
        }
        rumble = Rumble(controller: c)
        controllerName = c.vendorName ?? "Controller"
        onControllerChange?(controllerName)
        DiagLog.log("controller: \(controllerName ?? "?")\(pad is GCDualSenseGamepad ? " (DualSense)" : "")\(c.motion != nil ? ", motion" : "")\(c.haptics != nil ? ", haptics" : "")", "rp")
        queue.async { [weak self] in self?.send(pad) }
    }

    private func detach() {
        if let c = controller {
            c.extendedGamepad?.valueChangedHandler = nil
            c.motion?.valueChangedHandler = nil
            if let ds = c.extendedGamepad as? GCDualSenseGamepad {
                ds.leftTrigger.setModeOff()
                ds.rightTrigger.setModeOff()
            }
        }
        rumble?.stop()
        rumble = nil
        controller = nil
    }

    // MARK: - Controller → console

    private func send(_ pad: GCExtendedGamepad) {
        guard let session else { return }
        var s = rp_controller_state()
        var b: UInt32 = 0
        func on(_ pressed: Bool, _ bit: Int) { if pressed { b |= UInt32(bit) } }
        on(pad.buttonA.isPressed, Int(RP_BUTTON_CROSS))
        on(pad.buttonB.isPressed, Int(RP_BUTTON_MOON))
        on(pad.buttonX.isPressed, Int(RP_BUTTON_BOX))
        on(pad.buttonY.isPressed, Int(RP_BUTTON_PYRAMID))
        on(pad.dpad.left.isPressed, Int(RP_BUTTON_DPAD_LEFT))
        on(pad.dpad.right.isPressed, Int(RP_BUTTON_DPAD_RIGHT))
        on(pad.dpad.up.isPressed, Int(RP_BUTTON_DPAD_UP))
        on(pad.dpad.down.isPressed, Int(RP_BUTTON_DPAD_DOWN))
        on(pad.leftShoulder.isPressed, Int(RP_BUTTON_L1))
        on(pad.rightShoulder.isPressed, Int(RP_BUTTON_R1))
        on(pad.leftThumbstickButton?.isPressed ?? false, Int(RP_BUTTON_L3))
        on(pad.rightThumbstickButton?.isPressed ?? false, Int(RP_BUTTON_R3))
        on(pad.buttonMenu.isPressed, Int(RP_BUTTON_OPTIONS))
        on(pad.buttonOptions?.isPressed ?? false, Int(RP_BUTTON_SHARE))
        on(pad.buttonHome?.isPressed ?? false, Int(RP_BUTTON_PS))
        s.l2 = UInt8(max(0, min(255, (pad.leftTrigger.value * 255).rounded())))
        s.r2 = UInt8(max(0, min(255, (pad.rightTrigger.value * 255).rounded())))
        s.left_x = axis(pad.leftThumbstick.xAxis.value)
        s.left_y = axis(-pad.leftThumbstick.yAxis.value)
        s.right_x = axis(pad.rightThumbstick.xAxis.value)
        s.right_y = axis(-pad.rightThumbstick.yAxis.value)

        s.touches.0 = rp_touch(x: 0, y: 0, id: -1)
        s.touches.1 = rp_touch(x: 0, y: 0, id: -1)
        if let ds = pad as? GCDualSenseGamepad {
            on(ds.touchpadButton.isPressed, Int(RP_BUTTON_TOUCHPAD))
            s.touches.0 = touch(0, ds.touchpadPrimary)
            s.touches.1 = touch(1, ds.touchpadSecondary)
        }
        s.buttons = b

        s.orient_w = 1
        if motionEnabled, let m = controller?.motion {
            // GameController: rad/s and g, device frame. chiaki expects the DualSense's own frame,
            // which for a controller held normally matches these axes.
            s.gyro_x = Float(m.rotationRate.x)
            s.gyro_y = Float(m.rotationRate.y)
            s.gyro_z = Float(m.rotationRate.z)
            s.accel_x = Float(m.gravity.x + m.userAcceleration.x)
            s.accel_y = Float(m.gravity.y + m.userAcceleration.y)
            s.accel_z = Float(m.gravity.z + m.userAcceleration.z)
            if m.hasAttitude {
                s.orient_x = Float(m.attitude.x)
                s.orient_y = Float(m.attitude.y)
                s.orient_z = Float(m.attitude.z)
                s.orient_w = Float(m.attitude.w)
            }
        } else {
            s.accel_y = 1   // at rest, gravity along +y as the DualSense reports it lying flat
        }
        session.setController(&s)
    }

    private func axis(_ v: Float) -> Int16 {
        Int16(max(-32767, min(32767, (v * 32767).rounded())))
    }

    /// DualSense touchpad: GameController gives -1…1 per axis (y up) and 0,0 when untouched.
    private func touch(_ index: Int, _ pad: GCControllerDirectionPad) -> rp_touch {
        let x = pad.xAxis.value, y = pad.yAxis.value
        let down = x != 0 || y != 0
        if !down {
            touchIDs[index] = -1
            return rp_touch(x: 0, y: 0, id: -1)
        }
        if touchIDs[index] < 0 {
            touchIDs[index] = nextTouchID
            nextTouchID = (nextTouchID + 1) & 0x7F
        }
        let px = UInt16(max(0, min(1919, ((x + 1) / 2 * 1919).rounded())))
        let py = UInt16(max(0, min(1079, ((1 - (y + 1) / 2) * 1079).rounded())))
        return rp_touch(x: px, y: py, id: touchIDs[index])
    }

    // MARK: - Console → controller

    func rumble(left: UInt8, right: UInt8) {
        queue.async { [weak self] in self?.rumble?.set(low: Float(left) / 255, high: Float(right) / 255) }
    }

    /// DualSense adaptive trigger effect (type byte + 10 parameter bytes, as the console sends
    /// them to a real DualSense) translated to the closest GameController mode.
    func triggerEffects(leftType: UInt8, left: [UInt8], rightType: UInt8, right: [UInt8]) {
        guard triggerEffectsEnabled else { return }
        queue.async { [weak self] in
            guard let ds = self?.controller?.extendedGamepad as? GCDualSenseGamepad else { return }
            Self.apply(type: leftType, params: left, to: ds.leftTrigger)
            Self.apply(type: rightType, params: right, to: ds.rightTrigger)
        }
    }

    private static func apply(type: UInt8, params p: [UInt8], to trigger: GCDualSenseAdaptiveTrigger) {
        guard p.count >= 10 else { trigger.setModeOff(); return }
        func zones(_ lo: UInt8, _ hi: UInt8) -> [Int] {
            let mask = Int(lo) | (Int(hi) << 8)
            return (0..<10).filter { mask & (1 << $0) != 0 }
        }
        switch type {
        case 0x21:   // feedback: zone mask + 3-bit strength per zone
            let active = zones(p[0], p[1])
            guard let first = active.first else { trigger.setModeOff(); return }
            let packed = UInt32(p[2]) | (UInt32(p[3]) << 8) | (UInt32(p[4]) << 16) | (UInt32(p[5]) << 24)
            let strength = active.map { Int((packed >> (3 * UInt32($0))) & 0x7) }.max() ?? 0
            trigger.setModeFeedbackWithStartPosition(Float(first) / 9, resistiveStrength: Float(strength + 1) / 8)
        case 0x25:   // weapon: start and end zone bits + strength
            let active = zones(p[0], p[1])
            guard let start = active.first, let end = active.last, end > start else { trigger.setModeOff(); return }
            trigger.setModeWeaponWithStartPosition(Float(start) / 9, endPosition: Float(end) / 9,
                                                   resistiveStrength: Float(min(7, Int(p[2])) + 1) / 8)
        case 0x26:   // vibration: zone mask + amplitude per zone + frequency (Hz)
            let active = zones(p[0], p[1])
            guard let first = active.first else { trigger.setModeOff(); return }
            let packed = UInt32(p[2]) | (UInt32(p[3]) << 8) | (UInt32(p[4]) << 16) | (UInt32(p[5]) << 24)
            let amp = active.map { Int((packed >> (3 * UInt32($0))) & 0x7) }.max() ?? 0
            trigger.setModeVibrationWithStartPosition(Float(first) / 9, amplitude: Float(amp + 1) / 8,
                                                      frequency: Float(p[8]) / 255)
        default:     // 0x05 off, and the legacy simple modes
            trigger.setModeOff()
        }
    }

    /// Two continuous haptic players (left handle = low-frequency motor, right = high) whose
    /// intensity follows the console's rumble values.
    private final class Rumble {
        private var engines: [CHHapticEngine] = []
        private var players: [CHHapticAdvancedPatternPlayer] = []

        init?(controller: GCController) {
            guard let haptics = controller.haptics else { return nil }
            for (locality, sharpness) in [(GCHapticsLocality.leftHandle, Float(0.2)), (GCHapticsLocality.rightHandle, Float(0.8))] {
                guard let engine = haptics.createEngine(withLocality: locality) else { continue }
                do {
                    try engine.start()
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                    ], relativeTime: 0, duration: 3600)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    let player = try engine.makeAdvancedPlayer(with: pattern)
                    player.loopEnabled = true
                    try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)], atTime: CHHapticTimeImmediate)
                    try player.start(atTime: CHHapticTimeImmediate)
                    engines.append(engine)
                    players.append(player)
                } catch {
                    DiagLog.log("rumble unavailable on \(locality.rawValue): \(error.localizedDescription)", "rp")
                }
            }
            if players.isEmpty { return nil }
        }

        func set(low: Float, high: Float) {
            let values = [low, high]
            for (i, p) in players.enumerated() where i < values.count {
                try? p.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: values[i], relativeTime: 0)],
                                      atTime: CHHapticTimeImmediate)
            }
        }

        func stop() {
            players.forEach { try? $0.stop(atTime: CHHapticTimeImmediate) }
            engines.forEach { $0.stop() }
            players = []
            engines = []
        }
    }
}
