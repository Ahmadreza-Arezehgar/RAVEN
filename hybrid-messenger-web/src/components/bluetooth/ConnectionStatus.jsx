import './ConnectionStatus.css';

function ConnectionStatus({ isConnected, deviceCount }) {
    return (
        <div className={`connection-status ${isConnected ? 'connected' : 'disconnected'}`}>
            <div className="status-indicator">
                <div className={`status-dot ${isConnected ? 'active' : ''}`}></div>
                <span className="status-text">
                    {isConnected ? 'Connected' : 'Disconnected'}
                </span>
            </div>

            {isConnected && (
                <div className="device-count">
                    <span className="count">{deviceCount}</span>
                    <span className="label">{deviceCount === 1 ? 'Device' : 'Devices'}</span>
                </div>
            )}

            <div className="connection-type">
                <span className="type-icon">🔵</span>
                <span className="type-label">Bluetooth LE</span>
            </div>
        </div>
    );
}

export default ConnectionStatus;
