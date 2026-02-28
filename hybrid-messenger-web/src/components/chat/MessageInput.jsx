import { useState, useRef } from 'react';
import './MessageInput.css';

function MessageInput({ onSend, disabled }) {
    const [message, setMessage] = useState('');
    const inputRef = useRef(null);

    const handleSubmit = (e) => {
        e.preventDefault();
        if (message.trim() && !disabled) {
            onSend(message.trim());
            setMessage('');
            inputRef.current?.focus();
        }
    };

    const handleKeyPress = (e) => {
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            handleSubmit(e);
        }
    };

    return (
        <form className="message-input" onSubmit={handleSubmit}>
            <button type="button" className="btn-icon" title="Attach">
                📎
            </button>

            <input
                ref={inputRef}
                type="text"
                className="input-field message-field"
                placeholder="Type a message... (Enter to send)"
                value={message}
                onChange={(e) => setMessage(e.target.value)}
                onKeyPress={handleKeyPress}
                disabled={disabled}
            />

            <button
                type="submit"
                className="btn btn-primary btn-send"
                disabled={!message.trim() || disabled}
            >
                {disabled ? '⌛' : '➤'}
            </button>
        </form>
    );
}

export default MessageInput;
