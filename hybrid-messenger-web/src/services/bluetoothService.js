/**
 * Web Bluetooth Service for Mesh Networking
 * Enables the web app to participate in the Bluetooth mesh network
 */

// UUIDs matching mobile app
const MESSENGER_SERVICE_UUID = '0000ff00-0000-1000-8000-00805f9b34fb';
const MESSAGE_TX_CHAR_UUID = '0000ff01-0000-1000-8000-00805f9b34fb';
const MESSAGE_RX_CHAR_UUID = '0000ff02-0000-1000-8000-00805f9b34fb';
const DEVICE_INFO_CHAR_UUID = '0000ff03-0000-1000-8000-00805f9b34fb';
const MESH_STATUS_CHAR_UUID = '0000ff04-0000-1000-8000-00805f9b34fb';

class BluetoothService {
    constructor() {
        this.device = null;
        this.server = null;
        this.service = null;
        this.txCharacteristic = null;
        this.rxCharacteristic = null;
        this.connectedDevices = new Map();
        this.messageHandlers = [];
        this.seenMessageIds = new Set();
        this.isScanning = false;
    }

    // Check if Web Bluetooth is supported
    isSupported() {
        if (!navigator.bluetooth) {
            console.warn('Web Bluetooth API not supported in this browser');
            return false;
        }
        return true;
    }

    // Request Bluetooth permission and scan for devices
    async requestDevice() {
        if (!this.isSupported()) {
            throw new Error('Web Bluetooth not supported');
        }

        try {
            this.device = await navigator.bluetooth.requestDevice({
                filters: [
                    { services: [MESSENGER_SERVICE_UUID] }
                ],
                optionalServices: [MESSENGER_SERVICE_UUID]
            });

            this.device.addEventListener('gattserverdisconnected', () => {
                console.log('Device disconnected');
                this.handleDisconnect();
            });

            return this.device;
        } catch (error) {
            console.error('Error requesting device:', error);
            throw error;
        }
    }

    // Connect to a Bluetooth device
    async connect(device = this.device) {
        if (!device) {
            throw new Error('No device to connect to');
        }

        try {
            console.log('Connecting to GATT Server...');
            this.server = await device.gatt.connect();

            console.log('Getting Messenger Service...');
            this.service = await this.server.getPrimaryService(MESSENGER_SERVICE_UUID);

            console.log('Getting characteristics...');
            this.txCharacteristic = await this.service.getCharacteristic(MESSAGE_TX_CHAR_UUID);
            this.rxCharacteristic = await this.service.getCharacteristic(MESSAGE_RX_CHAR_UUID);

            // Subscribe to incoming messages
            await this.rxCharacteristic.startNotifications();
            this.rxCharacteristic.addEventListener('characteristicvaluechanged',
                this.handleIncomingMessage.bind(this));

            console.log('✅ Connected to Bluetooth mesh!');
            this.connectedDevices.set(device.id, {
                device,
                server: this.server,
                service: this.service
            });

            return true;
        } catch (error) {
            console.error('Connection error:', error);
            throw error;
        }
    }

    // Disconnect from device
    async disconnect() {
        if (this.server && this.server.connected) {
            await this.server.disconnect();
        }
        this.device = null;
        this.server = null;
        this.service = null;
        this.txCharacteristic = null;
        this.rxCharacteristic = null;
    }

    // Send a message via Bluetooth
    async sendMessage(message) {
        if (!this.txCharacteristic) {
            throw new Error('Not connected to any device');
        }

        try {
            const messageData = {
                messageId: message.id || this.generateMessageId(),
                senderId: message.senderId,
                recipientId: message.recipientId,
                content: message.content, // Should be encrypted
                timestamp: message.timestamp || Date.now(),
                hopCount: message.hopCount || 0,
                maxHops: message.maxHops || 5,
                sprayQuota: message.sprayQuota || 3,
                signature: message.signature || '',
                messageType: message.messageType || 'direct'
            };

            const encoder = new TextEncoder();
            const data = encoder.encode(JSON.stringify(messageData));

            await this.txCharacteristic.writeValue(data);
            console.log('📤 Message sent via Bluetooth:', messageData);

            return true;
        } catch (error) {
            console.error('Error sending message:', error);
            throw error;
        }
    }

    // Handle incoming Bluetooth messages
    handleIncomingMessage(event) {
        try {
            const decoder = new TextDecoder();
            const data = decoder.decode(event.target.value);
            const message = JSON.parse(data);

            console.log('📥 Received Bluetooth message:', message);

            // Check if already seen (prevent loops)
            if (this.seenMessageIds.has(message.messageId)) {
                return;
            }
            this.seenMessageIds.add(message.messageId);

            // Clean up old seen IDs (keep last 1000)
            if (this.seenMessageIds.size > 1000) {
                const iterator = this.seenMessageIds.values();
                this.seenMessageIds.delete(iterator.next().value);
            }

            // Notify all registered handlers
            this.messageHandlers.forEach(handler => handler(message));

            // Relay logic (if not for us)
            const currentUserId = this.getCurrentUserId();
            if (message.recipientId !== currentUserId) {
                this.relayMessage(message);
            }
        } catch (error) {
            console.error('Error handling incoming message:', error);
        }
    }

    // Relay message to other devices (mesh routing)
    async relayMessage(message) {
        // Check hop limit
        if (message.hopCount >= message.maxHops) {
            console.log('Message hop limit reached, dropping');
            return;
        }

        // Check spray quota
        if (message.sprayQuota <= 0) {
            console.log('Message spray quota exhausted, storing in outbox');
            // Store in outbox for wait phase
            return;
        }

        // Increment hop count and decrement spray quota
        message.hopCount++;
        message.sprayQuota--;

        // Broadcast to all connected devices except the one it came from
        console.log('🔄 Relaying message (hop', message.hopCount, ')');
        await this.sendMessage(message);
    }

    // Register a message handler
    onMessage(handler) {
        this.messageHandlers.push(handler);

        // Return unsubscribe function
        return () => {
            const index = this.messageHandlers.indexOf(handler);
            if (index > -1) {
                this.messageHandlers.splice(index, 1);
            }
        };
    }

    // Handle disconnect
    handleDisconnect() {
        console.log('Bluetooth device disconnected');
        this.device = null;
        this.server = null;
        this.service = null;
        this.txCharacteristic = null;
        this.rxCharacteristic = null;
    }

    // Generate unique message ID
    generateMessageId() {
        return `${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    }

    // Get current user ID (from auth service)
    getCurrentUserId() {
        const user = JSON.parse(localStorage.getItem('user') || '{}');
        return user.id || null;
    }

    // Get connection status
    isConnected() {
        return this.server && this.server.connected;
    }

    // Get list of connected devices
    getConnectedDevices() {
        return Array.from(this.connectedDevices.values());
    }
}

export const bluetoothService = new BluetoothService();
export default bluetoothService;
