import Foundation
import Combine
import CoreBluetooth
import StudyCore

struct DiscoveredStudyDevice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// BLE transport only. A completed write is never treated as completed handoff.
@MainActor
final class BluetoothLink: NSObject, ObservableObject {
    static let serviceID = CBUUID(string: "91F60001-7D6A-4B93-AC0D-E78C09205142")
    static let receiveID = CBUUID(string: "91F60002-7D6A-4B93-AC0D-E78C09205142")
    static let transmitID = CBUUID(string: "91F60003-7D6A-4B93-AC0D-E78C09205142")

    @Published private(set) var devices: [DiscoveredStudyDevice] = []
    @Published private(set) var status = "蓝牙尚未启动"
    @Published private(set) var scanning = false
    @Published private(set) var ready = false
    @Published private(set) var selectedID: UUID?
    var onMessage: ((DeviceWireMessage) -> Void)?
    var onReady: (() -> Void)?
    var onDisconnected: (() -> Void)?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var decoder = BLEFrameCodec()
    private var chunks: [Data] = []
    private var nextChunk = 0
    private var awaitingWrite = false
    private var sequence: UInt32 = 0
    private var timeout: Timer?
    private var writeTimeout: Timer?
    private var receiveTimeout: Timer?
    private var scanTimeout: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scan() {
        guard central.state == .poweredOn else {
            status = central.state == .unauthorized ? "请在设置中允许蓝牙访问" : "请打开蓝牙"
            return
        }
        guard peripheral == nil else { status = "请先断开当前设备再搜索"; return }
        devices = []
        peripherals = [:]
        scanning = true
        status = "正在搜索安装了背词同步固件的设备"
        central.scanForPeripherals(withServices: [Self.serviceID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimeout?.invalidate()
        scanTimeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopScan() }
        }
    }

    func stopScan() {
        central.stopScan()
        scanTimeout?.invalidate()
        scanning = false
        if peripheral == nil { status = devices.isEmpty ? "没有找到设备，请确认已安装兼容固件并开启同步" : "选择你的小设备" }
    }

    func connect(_ id: UUID) {
        guard let chosen = peripherals[id], peripheral == nil else { return }
        stopScan()
        selectedID = id
        peripheral = chosen
        chosen.delegate = self
        status = "正在连接"
        central.connect(chosen, options: nil)
        armTimeout("连接超时，学习记录未交接")
    }

    func disconnect() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        resetConnection()
        status = "已断开；待确认的接力仍保持锁定"
    }

    func send(_ message: DeviceWireMessage) throws {
        guard ready, let peripheral, rx != nil else { throw StudyError.sync("蓝牙未连接，接力状态已保留。") }
        let encoded = try JSONEncoder().encode(message)
        guard encoded.count <= 4 * 1024 * 1024 else { throw StudyError.sync("同步消息超过容量限制。") }
        sequence &+= 1
        if sequence == 0 { sequence = 1 }
        let mtu = peripheral.maximumWriteValueLength(for: .withResponse)
        let frames = try BLEFrameCodec.encode(message: encoded, transferID: sequence, mtu: mtu)
        let queueBytes = chunks.dropFirst(nextChunk).reduce(0) { $0 + $1.count }
        guard queueBytes + encoded.count < 12 * 1024 * 1024 else { throw StudyError.sync("仍有同步消息待发送，请稍候再试。") }
        chunks.append(contentsOf: frames)
        writeNext()
    }

    private func writeNext() {
        guard !awaitingWrite, nextChunk < chunks.count, let peripheral, let rx else { return }
        awaitingWrite = true
        peripheral.writeValue(chunks[nextChunk], for: rx, type: .withResponse)
        writeTimeout?.invalidate()
        writeTimeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fail("蓝牙发送超时，接力尚未确认") }
        }
    }

    private func armTimeout(_ message: String) {
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.disconnect()
                self.status = message
            }
        }
    }

    private func resetConnection() {
        timeout?.invalidate()
        writeTimeout?.invalidate()
        receiveTimeout?.invalidate()
        peripheral?.delegate = nil
        rx = nil
        tx = nil
        ready = false
        peripheral = nil
        selectedID = nil
        chunks.removeAll()
        nextChunk = 0
        awaitingWrite = false
        decoder = BLEFrameCodec()
        onDisconnected?()
    }

    private func fail(_ message: String) {
        disconnect()
        status = message
    }
}

extension BluetoothLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: status = "可搜索小设备"
        case .unauthorized: status = "请在设置中允许蓝牙访问"
        case .poweredOff: status = "蓝牙已关闭"; resetConnection()
        case .unsupported: status = "当前设备不支持低功耗蓝牙"
        default: status = "蓝牙正在准备"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "背词设备"
        let item = DiscoveredStudyDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == item.id }) { devices[index] = item }
        else { devices.append(item) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { central.cancelPeripheralConnection(peripheral); return }
        status = "正在核对同步服务"
        peripheral.discoverServices([Self.serviceID])
        armTimeout("同步服务响应超时")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        resetConnection()
        status = "连接失败：\(error?.localizedDescription ?? "设备未响应")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        resetConnection()
        status = "连接已断开；未确认的接力不会被当作成功"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else {
            fail("未找到兼容的背词同步服务"); return
        }
        peripheral.discoverCharacteristics([Self.receiveID, Self.transmitID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard error == nil else { fail("无法读取蓝牙服务"); return }
        rx = service.characteristics?.first(where: { $0.uuid == Self.receiveID })
        tx = service.characteristics?.first(where: { $0.uuid == Self.transmitID })
        guard let rx, rx.properties.contains(.write), let tx, tx.properties.contains(.notify) else {
            fail("设备缺少可靠写入或通知通道"); return
        }
        peripheral.setNotifyValue(true, for: tx)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard characteristic.uuid == Self.transmitID else { return }
        guard error == nil, characteristic.isNotifying else { fail("无法打开同步通知"); return }
        timeout?.invalidate()
        ready = true
        status = "已连接，正在核对数据版本"
        onReady?()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard characteristic.uuid == Self.receiveID, awaitingWrite else { return }
        guard error == nil else { fail("蓝牙写入失败，接力未确认"); return }
        writeTimeout?.invalidate()
        if nextChunk < chunks.count { nextChunk += 1 }
        if nextChunk == chunks.count { chunks.removeAll(keepingCapacity: false); nextChunk = 0 }
        awaitingWrite = false
        writeNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        guard characteristic.uuid == Self.transmitID else { return }
        guard error == nil, let data = characteristic.value else { fail("蓝牙通知读取失败"); return }
        do {
            if let messageData = try decoder.consume(data) {
                receiveTimeout?.invalidate()
                let message = try JSONDecoder().decode(DeviceWireMessage.self, from: messageData)
                guard message.wireVersion == 1 else { throw StudyError.sync("设备同步协议版本不同。") }
                onMessage?(message)
            } else if decoder.hasPartialMessage {
                receiveTimeout?.invalidate()
                receiveTimeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.fail("蓝牙接收超时，接力未确认") }
                }
            }
        } catch { fail("同步数据校验失败：\(error.localizedDescription)") }
    }
}
