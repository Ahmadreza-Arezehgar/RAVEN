import { useEffect, useRef } from 'react';
import './MessageList.css';

function MessageList({ messages, currentUser }) {
    const messagesEndRef = useRef(null);

    // Auto-scroll to bottom on new messages
    useEffect(() => {
        messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
    }, [messages]);

    if (!messages || messages.length === 0) {
        return (
            <div className="message-list">
                <div className="no-messages">
                    <p>No messages yet. Start the conversation!</p>
                </div>
            </div>
        );
    }

    return (
        <div className="message-list">
            {messages.map((msg, index) => {
                const isOwnMessage = msg.sender_id === currentUser?.id;
                const showAvatar = index === 0 || messages[index - 1].sender_id !== msg.sender_id;
                const showTimestamp = index === messages.length - 1 ||
                    messages[index + 1].sender_id !== msg.sender_id;

                return (
                    <div
                        key={msg.id || index}
                        className={`message-wrapper ${isOwnMessage ? 'own' : 'other'}`}
                    >
                        {!isOwnMessage && showAvatar && (
                            <div className="message-avatar">
                                {msg.sender_username?.charAt(0).toUpperCase() || '?'}
                            </div>
                        )}

                        <div className="message-bubble">
                            {!isOwnMessage && showAvatar && (
                                <div className="message-sender">{msg.sender_username || 'Unknown'}</div>
                            )}
                            <div className="message-content">{msg.content}</div>
                            {showTimestamp && (
                                <div className="message-time">
                                    {formatTime(msg.timestamp)}
                                </div>
                            )}
                        </div>

                        {isOwnMessage && showAvatar && (
                            <div className="message-avatar own">
                                {currentUser?.username?.charAt(0).toUpperCase() || '?'}
                            </div>
                        )}
                    </div>
                );
            })}
            <div ref={messagesEndRef} />
        </div>
    );
}

// Helper function to format timestamp
function formatTime(timestamp) {
    const date = new Date(timestamp);
    const now = new Date();
    const diff = now - date;

    // Less than 1 minute
    if (diff < 60000) return 'Just now';

    // Less than 1 hour
    if (diff < 3600000) {
        const minutes = Math.floor(diff / 60000);
        return `${minutes}m ago`;
    }

    // Same day
    if (date.toDateString() === now.toDateString()) {
        return date.toLocaleTimeString('en-US', {
            hour: 'numeric',
            minute: '2-digit',
            hour12: true
        });
    }

    // This week
    if (diff < 604800000) {
        return date.toLocaleDateString('en-US', { weekday: 'short' });
    }

    // Older
    return date.toLocaleDateString('en-US', {
        month: 'short',
        day: 'numeric'
    });
}

export default MessageList;
