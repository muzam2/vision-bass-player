import Foundation
import CoreBluetooth
import Combine

/// BLE central that streams bass packets to the ESP32 receiver.
///
/// GATT layout (must match firmware/esp32-bass-receiver):
///   Service  7A3B0001-2C4D-4E5F-8A9B-0C1D2E3F4A5B
///   Audio    7A3B0002-…  write-without-response, 47-byte packets from BassExtractor
///   Config   7A3B0003-…  write: [u16 LE extraDelayMs][u8 mute]
///   Status   7A3B0004-…  notify: [u16 LE bufferFillSamples][u16 LE dropped][u16 LE underruns]
final class BassLink: NSObject, ObservableObject {
    enum State: String { case off, scanning, connecting, connected }

    static let serviceUUID = CBUUID(string: "7A3B0001-2C4D-4E5F-8A9B-0C1D2E3F4A5B")
    static let audioUUID   = CBUUID(string: "7A3B0002-2C4D-4E5F-8A9B-0C1D2E3F4A5B")
    static let configUUID  = CBUUID(string: "7A3B0003-2C4D-4E5F-8A9B-0C1D2E3F4A5B")
    static let statusUUID  = CBUUID(string: "7A3B0004-2C4D-4E5F-8A9B-0C1D2E3F4A5B")

    @Published private(set) var state: State = .off
    @Published private(set) var peripheralName: String?
    @Published private(set) var packetsSent = 0
    @Published private(set) var packetsDropped = 0
    /// Most packets ever waiting to be sent since the link came up (5 to 6 is normal).
    @Published private(set) var sendQueuePeak = 0
    @Published private(set) var receiverBufferFill = 0
    @Published private(set) var receiverUnderruns = 0
    @Published private(set) var receiverDropped = 0

    /// Extra delay the receiver adds before playing, to line the bass up with the picture.
    @Published var extraDelayMs: Int = 0 { didSet { pushConfig() } }
    @Published var muted = false { didSet { pushConfig() } }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var audioChar: CBCharacteristic?
    private var configChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private let queue = DispatchQueue(label: "bass.ble", qos: .userInteractive)
    private var shouldRun = false
    // Queue-confined mirrors of the published state, so the 50 Hz send path never touches
    // main-actor properties and SwiftUI is updated at most ~4 times a second.
    private var linkUp = false
    private var lastLoggedState: State = .off
    private var sentCount = 0
    private var droppedCount = 0
    private var flushScheduled = false

    // Packets arrive in bursts: the engine tap hands over 100 ms of audio at a time, which is
    // five 20 ms packets at once. CoreBluetooth takes one write-without-response and then
    // reports "not ready" until its delegate has run on this same queue, so pushing a burst
    // straight through sent one packet and lost four (seen on the headset, 2026-11-20). The
    // packets wait here instead and leave one per 20 ms, which is also the steady stream the
    // receiver's jitter buffer and drift control are built for.
    private var outbox: [Data] = []
    private var outboxPeak = 0
    private var pacer: DispatchSourceTimer?
    private var idleTicks = 0
    private static let packetIntervalMs = 20
    private static let outboxLimit = 15      // 300 ms; anything older is too late to be worth playing
    private static let catchUpDepth = 7      // one burst leaves at most about 6 waiting
    private static let idleTicksToStop = 50  // 1 s with nothing to send: paused or finished

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: - Control

    func start() {
        queue.async {
            self.shouldRun = true
            self.scanIfPossible()
        }
    }

    func stop() {
        queue.async {
            self.shouldRun = false
            self.central.stopScan()
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            self.cleanup()
            self.setState(.off)
        }
    }

    /// Called on the audio thread by BassExtractor. Hop to the BLE queue; never block the renderer.
    func send(_ packet: Data) {
        queue.async { [weak self] in
            guard let self, self.linkUp, self.peripheral != nil, self.audioChar != nil else { return }
            self.outbox.append(packet)
            if self.outbox.count > Self.outboxLimit {
                // The link can't keep up. Drop the oldest audio so the bass stays near real time;
                // stalling the renderer is not an option.
                let excess = self.outbox.count - Self.outboxLimit
                self.outbox.removeFirst(excess)
                self.droppedCount += excess
            }
            self.outboxPeak = max(self.outboxPeak, self.outbox.count)
            if self.pacer == nil { self.startPacer() }
            self.scheduleCounterFlush()
        }
    }

    // MARK: - Paced sending (all on `queue`)

    private func startPacer() {
        idleTicks = 0
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(Self.packetIntervalMs), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pacerTick() }
        pacer = t
        t.resume()
    }

    private func stopPacer() {
        pacer?.cancel()
        pacer = nil
    }

    private func pacerTick() {
        guard linkUp else { outbox.removeAll(); stopPacer(); return }
        if outbox.isEmpty {
            idleTicks += 1
            if idleTicks >= Self.idleTicksToStop { stopPacer() }
            return
        }
        idleTicks = 0
        sendQueued(upTo: outbox.count > Self.catchUpDepth ? 2 : 1)
    }

    private func sendQueued(upTo budget: Int) {
        guard let p = peripheral, let c = audioChar else { return }
        var n = 0
        while n < budget, !outbox.isEmpty, p.canSendWriteWithoutResponse {
            p.writeValue(outbox.removeFirst(), for: c, type: .withoutResponse)
            n += 1
        }
        if n > 0 {
            sentCount += n
            scheduleCounterFlush()
        }
    }

    // MARK: - Internals

    private func scanIfPossible() {
        guard shouldRun, central.state == .poweredOn, peripheral == nil else { return }
        setState(.scanning)
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func pushConfig() {
        queue.async {
            guard let p = self.peripheral, let c = self.configChar else { return }
            var d = Data(count: 3)
            let delay = UInt16(clamping: max(0, self.extraDelayMs))
            d.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: delay.littleEndian, toByteOffset: 0, as: UInt16.self)
                raw[2] = self.muted ? 1 : 0
            }
            p.writeValue(d, for: c, type: .withResponse)
        }
    }

    private func cleanup() {
        peripheral = nil
        audioChar = nil
        configChar = nil
        statusChar = nil
        DispatchQueue.main.async { self.peripheralName = nil }
    }

    private func setState(_ s: State) {
        if s != lastLoggedState {
            lastLoggedState = s
            DiagLog.log("BLE \(s.rawValue)\(s == .connected ? " to \(peripheral?.name ?? "?")" : "")", "bass")
        }
        linkUp = s == .connected
        if s != .connected {
            sentCount = 0; droppedCount = 0; outboxPeak = 0
            outbox.removeAll()
            stopPacer()
            scheduleCounterFlush()
        }
        DispatchQueue.main.async { self.state = s }
    }

    /// Publish the packet counters at most every 250 ms instead of once per packet.
    private func scheduleCounterFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let sent = self.sentCount, dropped = self.droppedCount, peak = self.outboxPeak
            DispatchQueue.main.async {
                self.packetsSent = sent
                self.packetsDropped = dropped
                self.sendQueuePeak = peak
            }
        }
    }
}

extension BassLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DiagLog.log("Bluetooth state \(central.state.rawValue) (5 = powered on)", "bass")
        if central.state == .poweredOn {
            scanIfPossible()
        } else {
            cleanup()
            setState(.off)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        DiagLog.log("found receiver \(peripheral.name ?? "?") RSSI \(RSSI)", "bass")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        setState(.connecting)
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async { self.peripheralName = peripheral.name }
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DiagLog.log("connect failed: \(error?.localizedDescription ?? "?")", "bass")
        cleanup()
        scanIfPossible()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DiagLog.log("disconnected: \(error?.localizedDescription ?? "by us")", "bass")
        cleanup()
        if shouldRun { scanIfPossible() } else { setState(.off) }
    }
}

extension BassLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.audioUUID, Self.configUUID, Self.statusUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid {
            case Self.audioUUID: audioChar = c
            case Self.configUUID: configChar = c
            case Self.statusUUID:
                statusChar = c
                peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        if audioChar != nil {
            setState(.connected)
            pushConfig()
        }
    }

    /// CoreBluetooth can take another write. Normally the 20 ms pacer does the sending; this
    /// only steps in when packets have piled up (a "not ready" tick, or the audio clock running
    /// ahead of the timer), so the backlog drains instead of ending in dropped audio.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        if outbox.count > Self.catchUpDepth { sendQueued(upTo: 1) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.statusUUID, let d = characteristic.value, d.count >= 6 else { return }
        let fill = Int(UInt16(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self) }))
        let dropped = Int(UInt16(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2, as: UInt16.self) }))
        let underruns = Int(UInt16(littleEndian: d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt16.self) }))
        DispatchQueue.main.async {
            self.receiverBufferFill = fill
            self.receiverDropped = dropped
            self.receiverUnderruns = underruns
        }
    }
}
