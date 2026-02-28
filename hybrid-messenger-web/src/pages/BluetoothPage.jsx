import { useState, useEffect } from 'react';
import { bluetoothService } from '../../services/bluetoothService';
import { storageService } from '../../services/storageService';
import DeviceList from '../../components/bluetooth/DeviceList';
import ConnectionStatus from '../../components/bluetooth/ConnectionStatus';
import MeshVisualization from '../../components/bluetooth/MeshVisualization';
import OutboxManager from '../../components/bluetooth/OutboxManager';
import './BluetoothPage.css';

function BluetoothPage() {
    const [isSupported, setIsSupported] = useState(true);
    const [isConnected, setIsConnected] = useState(false);
    const [nearbyDevices, setNearbyDevices] = useState([]);
    const [connectedDevices, setConnectedDevices] = useState([]);
    const [outboxMessages, setOutboxMessages] = useState([]);
    const [meshStats, setMeshStats] = useState({
        messagesRelayed: 0,
        hopCount: 0,
        activeConnections: 0
    });
    const [activeTab, setActiveTab] = useState('discover'); // discover, connections, mesh, outbox

    useEffect(() => {
        // Check Bluetooth support
        if (!bluetoothService.isSupported()) {
            setIsSupported(false);
            return;
        }

        // Load initial data
        loadConnectedDevices();
        loadOutbox();

        // Set up interval to refresh connection status
        const interval = setInterval(() => {
            loadConnectedDevices();
            setIsConnected(bluetoothService.isConnected());
        }, 2000);

        return () => clearInterval(interval);
    }, []);

    const loadConnectedDevices = () => {
        const devices = bluetoothService.getConnectedDevices();
        setConnectedDevices(devices);
        setMeshStats(prev => ({
            ...prev,
            activeConnections: devices.length
        }));
    };

    const loadOutbox = async () => {
        const messages = await storageService.getOutbox();
        setOutboxMessages(messages);
    };

    const handleDiscoverDevices = async () => {
        try {
            const device = await bluetoothService.requestDevice();
            await bluetoothService.connect(device);

            setIsConnected(true);
            loadConnectedDevices();

            alert(`✅ Connected to ${device.name || 'device'}!`);
        } catch (error) {
            console.error('Discovery error:', error);
            if (error.message.includes('User cancelled')) {
                // User cancelled - do nothing
            } else {
                alert('Failed to connect: ' + error.message);
            }
        }
    };

    const handleDisconnect = async () => {
        await bluetoothService.disconnect();
        setIsConnected(false);
        setConnectedDevices([]);
    };

    const handleSendTestMessage = async () => {
        if (!isConnected) {
            alert('Not connected to any device');
            return;
        }

        try {
            await bluetoothService.sendMessage({
                senderId: 'web-user',
                recipientId: 'test-recipient',
                content: 'Test message from web!',
                messageType: 'broadcast'
            });

            setMeshStats(prev => ({
                ...prev,
                messagesRelayed: prev.messagesRelayed + 1
            }));

            alert('✅ Test message sent via mesh!');
        } catch (error) {
            console.error('Send error:', error);
            alert('Failed to send: ' + error.message);
        }
    };

    const handleRetryOutbox = async () => {
        for (const msg of outboxMessages) {
            try {
                if (msg.type === 'bluetooth' && isConnected) {
                    await bluetoothService.sendMessage(msg);
                    await storageService.removeFromOutbox(msg.id);
                }
            } catch (error) {
                console.error('Retry failed:', error);
            }
        }
        loadOutbox();
    };

    const handleClearOutbox = async () => {
        if (confirm('Clear all pending messages?')) {
            await storageService.clearOutbox();
            loadOutbox();
        }
    };

    if (!isSupported) {
        return (
            <div className="bluetooth-page">
                <div className="not-supported">
                    <div className="warning-icon">⚠️</div>
                    <h2>Web Bluetooth Not Supported</h2>
                    <p>Your browser doesn't support Web Bluetooth API.</p>
                    <p>Please use <strong>Chrome</strong> or <strong>Edge</strong> on desktop or Android.</p>
                    <div className="browser-tips">
                        <h3>Supported Browsers:</h3>
                        <ul>
                            <li>✅ Chrome (Desktop & Android)</li>
                            <li>✅ Edge (Desktop & Android)</li>
                            <li>⚠️ Firefox (Experimental)</li>
                            <li>❌ Safari (iOS) - Use native app</li>
                        </ul>
                    </div>
                </div>
            </div>
        );
    }

    return (
        <div className="bluetooth-page">
            {/* Header */}
            <div className="bluetooth-header">
                <div>
                    <h1>🔵 Bluetooth Mesh Network</h1>
                    <p>Connect to nearby devices for offline messaging</p>
                </div>
                <ConnectionStatus
                    isConnected={isConnected}
                    deviceCount={connectedDevices.length}
                />
            </div>

            {/* Quick Actions */}
            <div className="quick-actions">
                <button
                    className="btn btn-primary"
                    onClick={handleDiscoverDevices}
                    disabled={isConnected}
                >
                    {isConnected ? '✅ Connected' : '🔍 Discover Devices'}
                </button>

                {isConnected && (
                    <>
                        <button
                            className="btn btn-secondary"
                            onClick={handleSendTestMessage}
                        >
                            📡 Send Test Message
                        </button>
                        <button
                            className="btn btn-secondary"
                            onClick={handleDisconnect}
                        >
                            ❌ Disconnect
                        </button>
                    </>
                )}
            </div>

            {/* Tabs */}
            <div className="bluetooth-tabs">
                <button
                    className={`tab ${activeTab === 'discover' ? 'active' : ''}`}
                    onClick={() => setActiveTab('discover')}
                >
                    🔍 Discover
                </button>
                <button
                    className={`tab ${activeTab === 'connections' ? 'active' : ''}`}
                    onClick={() => setActiveTab('connections')}
                >
                    🔗 Connections ({connectedDevices.length})
                </button>
                <button
                    className={`tab ${activeTab === 'mesh' ? 'active' : ''}`}
                    onClick={() => setActiveTab('mesh')}
                >
                    🌐 Mesh Network
                </button>
                <button
                    className={`tab ${activeTab === 'outbox' ? 'active' : ''}`}
                    onClick={() => setActiveTab('outbox')}
                >
                    📤 Outbox ({outboxMessages.length})
                </button>
            </div>

            {/* Tab Content */}
            <div className="tab-content">
                {activeTab === 'discover' && (
                    <div className="discover-tab">
                        <div className="info-card glass-card">
                            <h3>📡 Device Discovery</h3>
                            <p>Click "Discover Devices" to scan for nearby Bluetooth devices running RAVEN.</p>
                            <p>Make sure Bluetooth is enabled and the other device has the app open.</p>
                            <div className="tips">
                                <h4>Tips:</h4>
                                <ul>
                                    <li>Keep devices within 10 meters</li>
                                    <li>Enable Bluetooth on both devices</li>
                                    <li>Grant permission when prompted</li>
                                    <li>RAVEN mobile app must be running</li>
                                </ul>
                            </div>
                        </div>
                    </div>
                )}

                {activeTab === 'connections' && (
                    <DeviceList
                        devices={connectedDevices}
                        onDisconnect={handleDisconnect}
                    />
                )}

                {activeTab === 'mesh' && (
                    <MeshVisualization
                        stats={meshStats}
                        connectedDevices={connectedDevices}
                    />
                )}

                {activeTab === 'outbox' && (
                    <OutboxManager
                        messages={outboxMessages}
                        onRetry={handleRetryOutbox}
                        onClear={handleClearOutbox}
                    />
                )}
            </div>
        </div>
    );
}

export default BluetoothPage;
