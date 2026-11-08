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
            guard let self, let p = self.peripheral, let c = self.audioChar, self.linkUp else { return }
            if p.canSendWriteWithoutResponse {
                p.writeValue(packet, for: c, type: .withoutResponse)
                self.sentCount += 1
            } else {
                // Link is saturated; dropping 20 ms of sub-bass is inaudible, stalling the renderer is not.
                self.droppedCount += 1
            }
            self.scheduleCounterFlush()
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
        if s != .connected { sentCount = 0; droppedCount = 0; scheduleCounterFlush() }
        DispatchQueue.main.async { self.state = s }
    }

    /// Publish the packet counters at most every 250 ms instead of once per packet.
    private func scheduleCounterFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let sent = self.sentCount, dropped = self.droppedCount
            DispatchQueue.main.async {
                self.packetsSent = sent
                self.packetsDropped = dropped
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
