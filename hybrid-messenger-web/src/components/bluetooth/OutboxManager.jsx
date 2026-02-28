import './OutboxManager.css';

function OutboxManager({ messages, onRetry, onClear }) {
    if (messages.length === 0) {
        return (
            <div className="outbox-manager empty">
                <div className="empty-state">
                    <div className="empty-icon">✅</div>
                    <h3>Outbox is Empty</h3>
                    <p>All messages have been sent successfully!</p>
                </div>
            </div>
        );
    }

    return (
        <div className="outbox-manager">
            <div className="outbox-header">
                <div>
                    <h3>Pending Messages</h3>
                    <p>{messages.length} message{messages.length !== 1 ? 's' : ''} waiting to be sent</p>
                </div>
                <div className="outbox-actions">
                    <button className="btn btn-secondary btn-sm" onClick={onRetry}>
                        🔄 Retry All
                    </button>
                    <button className="btn btn-secondary btn-sm" onClick={onClear}>
                        🗑️ Clear All
                    </button>
                </div>
            </div>

            <div className="outbox-list">
                {messages.map((msg, index) => (
                    <div key={msg.id || index} className="outbox-item glass-card">
                        <div className="outbox-icon">
                            {msg.type === 'bluetooth' ? '🔵' : '☁️'}
                        </div>
                        <div className="outbox-content">
                            <div className="outbox-recipient">
                                To: {msg.recipientId || 'Unknown'}
                            </div>
                            <div className="outbox-message">
                                {msg.content || msg.message || 'No content'}
                            </div>
                            <div className="outbox-meta">
                                <span className="outbox-type">
                                    {msg.type === 'bluetooth' ? 'Bluetooth Mesh' : 'Cloud'}
                                </span>
                                <span className="outbox-time">
                                    {formatTimestamp(msg.timestamp)}
                                </span>
                            </div>
                        </div>
                        <div className="outbox-status">
                            <div className="status-badge pending">⏳ Pending</div>
                        </div>
                    </div>
                ))}
            </div>
        </div>
    );
}

function formatTimestamp(timestamp) {
    if (!timestamp) return 'Unknown time';

    const date = new Date(timestamp);
    const now = new Date();
    const diff = now - date;

    if (diff < 60000) return 'Just now';
    if (diff < 3600000) return `${Math.floor(diff / 60000)}m ago`;
    if (diff < 86400000) return date.toLocaleTimeString('en-US', {
        hour: 'numeric',
        minute: '2-digit'
    });

    return date.toLocaleDateString('en-US', {
        month: 'short',
        day: 'numeric'
    });
}

export default OutboxManager;
