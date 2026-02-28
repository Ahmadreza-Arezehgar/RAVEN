import './DeviceList.css';

function DeviceList({ devices, onDisconnect }) {
    if (devices.length === 0) {
        return (
            <div className="device-list empty">
                <div className="empty-state">
                    <p>No devices connected</p>
                    <p className="hint">Click "Discover Devices" to find nearby RAIVEN devices</p>
                </div>
            </div>
        );
    }

    return (
        <div className="device-list">
            <h3>Connected Devices</h3>
            <div className="devices-grid">
                {devices.map((device, index) => (
                    <div key={device.device?.id || index} className="device-card glass-card">
                        <div className="device-header">
                            <div className="device-icon">📱</div>
                            <div className="device-info">
                                <div className="device-name">{device.device?.name || 'Unknown Device'}</div>
                                <div className="device-id">{device.device?.id || 'No ID'}</div>
                            </div>
                        </div>

                        <div className="device-stats">
                            <div className="stat">
                                <span className="stat-label">Status</span>
                                <span className="stat-value connected">🟢 Connected</span>
                            </div>
                            <div className="stat">
                                <span className="stat-label">Protocol</span>
                                <span className="stat-value">Bluetooth LE</span>
                            </div>
                        </div>

                        <div className="device-actions">
                            <button className="btn btn-secondary btn-sm" onClick={() => sendTestPing(device)}>
                                📡 Ping
                            </button>
                            <button className="btn btn-secondary btn-sm" onClick={onDisconnect}>
                                ❌ Disconnect
                            </button>
                        </div>
                    </div>
                ))}
            </div>
        </div>
    );
}

function sendTestPing(device) {
    alert(`Ping sent to ${device.device?.name || 'device'}`);
}

export default DeviceList;
