// RAVEN - Mesh/BLE Service
import Foundation
import CoreBluetooth
import Combine

/// Handles Bluetooth mesh networking for offline message delivery
@MainActor class MeshService: NSObject, ObservableObject {
    static let shared = MeshService()
    
    // MARK: - Published State
    @Published var isEnabled = false
    @Published var isScanning = false
    @Published var nearbyPeers: [MeshPeer] = []
    @Published var connectedPeers: [MeshPeer] = []
    
    // MARK: - BLE
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var messageCharacteristic: CBMutableCharacteristic?
    
    // FIX 1: Jologiri az Connection Spam
    private var pendingConnections: Set<UUID> = []
    
    // MARK: - Service UUIDs
    private let serviceUUID = CBUUID(string: "BA5E0000-0000-1000-8000-00805F9B34FB")
    private let messageCharUUID = CBUUID(string: "BA5E0001-0000-1000-8000-00805F9B34FB")
    private let identityCharUUID = CBUUID(string: "BA5E0002-0000-1000-8000-00805F9B34FB")
    
    // MARK: - Mesh Config
    private let maxHops = 10
    private let sprayCount = 5
    
    // MARK: - Message Queue
    private var pendingMessages: [MeshEnvelope] = []
    private var seenMessageIds: Set<String> = []
    private var seenMessageOrder: [String] = [] 
    
    override private init() {
        super.init()
    }
    
    // MARK: - Start/Stop
    func start() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(delegate: self, queue: nil)
        peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        isEnabled = true
        print("✅ [Mesh] Started")
    }
    
    func stop() {
        centralManager?.stopScan()
        peripheralManager?.stopAdvertising()
        centralManager = nil
        peripheralManager = nil
        
        clearState() // FIX 2: Pak kardane cache ha baraye Airplane Mode
        
        isEnabled = false
        isScanning = false
        print("✅ [Mesh] Stopped")
    }
    
    private func clearState() {
        nearbyPeers.removeAll()
        connectedPeers.removeAll()
        discoveredPeripherals.removeAll()
        pendingConnections.removeAll()
    }
    
    // MARK: - Scanning & Advertising
    func startScanning() {
        guard let central = centralManager, central.state == .poweredOn else { return }
        // FIX 3: AllowDuplicatesKey false baraye jologiri az CPU overload va Battery Drain
        central.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        isScanning = true
        print("🔍 [Mesh] Scanning for peers...")
    }
    
    func stopScanning() {
        centralManager?.stopScan()
        isScanning = false
    }
    
    func startAdvertising() {
        guard let peripheral = peripheralManager, peripheral.state == .poweredOn else { return }
        
        peripheral.removeAllServices() // Jologiri az duplicate service
        
        let service = CBMutableService(type: serviceUUID, primary: true)
        
        let messageChar = CBMutableCharacteristic(
            type: messageCharUUID,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        self.messageCharacteristic = messageChar
        
        let identityChar = CBMutableCharacteristic(
            type: identityCharUUID,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
        
        service.characteristics = [messageChar, identityChar]
        peripheral.add(service)
        
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "RAVEN"
        ])
    }
    
    // MARK: - Send Envelope
    // FIX 4: Hal kardane moshkel Broadcast Storm
    private func broadcastEnvelope(_ envelope: MeshEnvelope) {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        
        // 1. Notify be hameye Central haye vasl shode (Faghat YEK bar, Biron az loop)
        if let char = self.messageCharacteristic {
            peripheralManager?.updateValue(data, for: char, onSubscribedCentrals: nil)
        }
        
        // 2. Write be hameye Peripheral haye vasl shode
        for peer in connectedPeers {
            if let peripheral = discoveredPeripherals[peer.id],
               let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }),
               let char = service.characteristics?.first(where: { $0.uuid == messageCharUUID }) {
                peripheral.writeValue(data, for: char, type: .withResponse)
            }
        }
    }
    
    // MARK: - Send Message / Post
    func sendMessage(_ message: ChatMessage) {
        let envelope = MeshEnvelope(
            id: message.id, senderId: message.senderId, recipientId: message.recipientId,
            payload: message.text, timestamp: message.timestamp, hopCount: 0, 
            hopLimit: maxHops, sprayCount: sprayCount, signature: nil, type: "chat"
        )
        pendingMessages.append(envelope)
        seenMessageIds.insert(envelope.id)
        broadcastEnvelope(envelope)
    }
    
    // FIX 5: Ezafe kardane Post Mesh
    func sendPost(_ post: Post) {
        guard let payloadData = try? JSONEncoder().encode(post),
              let payload = String(data: payloadData, encoding: .utf8) else { return }
        
        let envelope = MeshEnvelope(
            id: post.id, senderId: post.authorId, recipientId: "broadcast_post",
            payload: payload, timestamp: post.createdAt, hopCount: 0, 
            hopLimit: maxHops, sprayCount: sprayCount, signature: nil, type: "post"
        )
        pendingMessages.append(envelope)
        seenMessageIds.insert(envelope.id)
        broadcastEnvelope(envelope)
    }
    
    // MARK: - Receive Message
    func handleReceivedEnvelope(_ data: Data) {
        guard let envelope = try? JSONDecoder().decode(MeshEnvelope.self, from: data) else { return }
        
        // Dedup check
        guard !seenMessageIds.contains(envelope.id) else { return }
        seenMessageIds.insert(envelope.id)
        seenMessageOrder.append(envelope.id)
        
        if seenMessageIds.count > 5000 {
            let toRemove = seenMessageOrder.prefix(1000)
            for id in toRemove { seenMessageIds.remove(id) }
            seenMessageOrder.removeFirst(1000)
        }
        
        // --- POST MESH ---
        if envelope.type == "post" {
            if let postData = envelope.payload.data(using: .utf8),
               let post = try? JSONDecoder().decode(Post.self, from: postData) {
                Task { @MainActor in
                    NotificationCenter.default.post(name: NSNotification.Name("NewMeshPost"), object: post)
                }
            }
            if envelope.hopCount < envelope.hopLimit && envelope.sprayCount > 0 {
                relayEnvelope(envelope)
            }
            return
        }
        
        // --- CHAT & BRIDGE ---
        guard let currentUserId = KeychainHelper.get(key: "user_id") else { return }
        let isDirectMessage = (envelope.recipientId == currentUserId)
        let isGroupMessage = envelope.recipientId.hasPrefix("group_")
        
        if isDirectMessage || isGroupMessage {
            deliverMessage(envelope)
        } else {
            // FIX 6: BRIDGE LOGIC
            // Payam male ma nist. Zakhire mikonim tu DB ta SyncService upload kone!
            Task {
                let bridgeMessage = ChatMessage(
                    id: envelope.id,
                    roomId: envelope.recipientId, 
                    senderId: envelope.senderId,
                    senderName: "Mesh User",
                    recipientId: envelope.recipientId,
                    text: envelope.payload,
                    timestamp: envelope.timestamp,
                    via: "mesh_bridge",
                    status: .pending,
                    syncState: .queued // SyncService in ro peyda mikone va upload mikone!
                )
                await DatabaseService.shared.insertMessage(bridgeMessage)
            }
        }
        
        // Relay Logic
        if (!isDirectMessage || isGroupMessage) && envelope.hopCount < envelope.hopLimit && envelope.sprayCount > 0 {
            relayEnvelope(envelope)
        }
    }
    
    private func deliverMessage(_ envelope: MeshEnvelope) {
        Task {
            let contacts = await DatabaseService.shared.getAllContacts()
            if let contact = contacts.first(where: { $0.userId == envelope.senderId }), contact.isBlocked { return }
            
            var senderName = "Mesh User"
            if let contact = contacts.first(where: { $0.userId == envelope.senderId }) { senderName = contact.effectiveName }
            
            let isGroup = envelope.recipientId.hasPrefix("group_")
            let message = ChatMessage(
                id: envelope.id, roomId: isGroup ? envelope.recipientId : envelope.senderId,
                senderId: envelope.senderId, senderName: senderName, recipientId: envelope.recipientId,
                text: envelope.payload, timestamp: envelope.timestamp, via: "mesh",
                status: .delivered, deliveryAuthority: .mesh
            )
            
            await DatabaseService.shared.insertMessage(message)
            await MainActor.run {
                NotificationCenter.default.post(name: NSNotification.Name("NewIncomingMessage"), object: message)
            }
        }
    }
    
    private func relayEnvelope(_ envelope: MeshEnvelope) {
        var relayed = envelope
        relayed.hopCount += 1
        relayed.sprayCount -= 1
        broadcastEnvelope(relayed)
    }
}

// MARK: - CBCentralManagerDelegate
extension MeshService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if isEnabled {
                    startScanning()
                    startAdvertising()
                }
            case .poweredOff, .resetting:
                // FIX 7: Airplane Mode Crash Fix - Pak kardane reference haye morde az RAM
                clearState()
            default: break
            }
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown"
            
            if discoveredPeripherals[peripheral.identifier] == nil {
                discoveredPeripherals[peripheral.identifier] = peripheral
                nearbyPeers.append(MeshPeer(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
            } else if let index = nearbyPeers.firstIndex(where: { $0.id == peripheral.identifier }) {
                nearbyPeers[index].rssi = RSSI.intValue
                nearbyPeers[index].lastSeen = Date()
            }
            
            // FIX 8: Connection Throttling (Jologiri az kand shodan va freeze shodan)
            if peripheral.state == .disconnected && !pendingConnections.contains(peripheral.identifier) {
                pendingConnections.insert(peripheral.identifier)
                central.connect(peripheral, options: nil)
            }
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            pendingConnections.remove(peripheral.identifier)
            if let peer = nearbyPeers.first(where: { $0.id == peripheral.identifier }) {
                if !connectedPeers.contains(where: { $0.id == peer.id }) {
                    connectedPeers.append(peer)
                }
            }
            peripheral.delegate = self
            peripheral.discoverServices([serviceUUID])
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            pendingConnections.remove(peripheral.identifier)
            connectedPeers.removeAll { $0.id == peripheral.identifier }
            
            if isEnabled && central.state == .poweredOn {
                if !pendingConnections.contains(peripheral.identifier) {
                    pendingConnections.insert(peripheral.identifier)
                    central.connect(peripheral, options: nil)
                }
            }
        }
    }
    
    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            pendingConnections.remove(peripheral.identifier)
        }
    }
}

// MARK: - CBPeripheralDelegate
extension MeshService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([messageCharUUID, identityCharUUID], for: service)
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            if char.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in handleReceivedEnvelope(data) }
    }
}

// MARK: - CBPeripheralManagerDelegate
extension MeshService: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            if peripheral.state == .poweredOn && isEnabled {
                startAdvertising()
            }
        }
    }
    
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            if let data = request.value {
                Task { @MainActor in handleReceivedEnvelope(data) }
            }
        }
        if let firstRequest = requests.first {
            peripheral.respond(to: firstRequest, withResult: .success)
        }
    }
}

// MARK: - Models
struct MeshPeer: Identifiable {
    let id: UUID
    let name: String
    var rssi: Int
    var lastSeen: Date = Date()
}

struct MeshEnvelope: Codable {
    let id: String
    let senderId: String
    let recipientId: String
    let payload: String
    let timestamp: Date
    var hopCount: Int
    let hopLimit: Int
    var sprayCount: Int
    let signature: String?
    var type: String? // FIX 9: Ezafe kardane Type baraye poshtibani az Chat va Post mesh
}
