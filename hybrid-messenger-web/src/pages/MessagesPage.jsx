import { useState, useEffect, useRef } from 'react';
import { useParams, useNavigate } from 'react-router-dom';
import { messagingService } from '../../services/messagingService';
import { cryptoService } from '../../services/cryptoService';
import { authService } from '../../services/authService';
import MessageList from '../../components/chat/MessageList';
import MessageInput from '../../components/chat/MessageInput';
import './MessagesPage.css';

function MessagesPage() {
    const { userId } = useParams();
    const navigate = useNavigate();
    const [conversations, setConversations] = useState([]);
    const [selectedConversation, setSelectedConversation] = useState(null);
    const [messages, setMessages] = useState([]);
    const [isLoading, setIsLoading] = useState(true);
    const [isSending, setIsSending] = useState(false);

    // Initialize crypto on mount
    useEffect(() => {
        const init = async () => {
            await cryptoService.initialize();
            await loadConversations();
            setIsLoading(false);
        };

        init();
    }, []);

    // Load conversations
    const loadConversations = async () => {
        try {
            const convs = await messagingService.getConversations();
            setConversations(convs);
        } catch (error) {
            console.error('Error loading conversations:', error);
        }
    };

    // Load messages for selected conversation
    const loadMessages = async (userId) => {
        try {
            const msgs = await messagingService.getMessages(userId);
            setMessages(msgs);
        } catch (error) {
            console.error('Error loading messages:', error);
        }
    };

    // Select a conversation
    const selectConversation = (conv) => {
        setSelectedConversation(conv);
        loadMessages(conv.user_id);
        navigate(`/messages/${conv.user_id}`);
    };

    // Send a message
    const handleSendMessage = async (content) => {
        if (!selectedConversation || !content.trim()) return;

        setIsSending(true);
        try {
            // Encrypt message
            const encrypted = await cryptoService.encryptMessage(content);

            // Send via API
            const message = await messagingService.sendMessage(
                selectedConversation.user_id,
                content,
                encrypted.encryptedData
            );

            // Add to local messages
            setMessages(prev => [...prev, message]);
        } catch (error) {
            console.error('Error sending message:', error);
            alert('Failed to send message');
        }
        setIsSending(false);
    };

    if (isLoading) {
        return (
            <div className="messages-page">
                <div className="loading-container">
                    <div className="loading-spinner"></div>
                    <p>Loading messages...</p>
                </div>
            </div>
        );
    }

    return (
        <div className="messages-page">
            {/* Sidebar - Conversations List */}
            <div className="conversations-sidebar">
                <div className="sidebar-header">
                    <h2>Messages</h2>
                    <button className="btn-icon" title="New Message">➕</button>
                </div>

                <div className="conversations-list">
                    {conversations.length === 0 ? (
                        <div className="empty-state">
                            <p>No conversations yet</p>
                            <button className="btn btn-primary btn-sm" onClick={() => navigate('/search')}>
                                Find Friends
                            </button>
                        </div>
                    ) : (
                        conversations.map(conv => (
                            <div
                                key={conv.user_id}
                                className={`conversation-item ${selectedConversation?.user_id === conv.user_id ? 'active' : ''}`}
                                onClick={() => selectConversation(conv)}
                            >
                                <div className="conversation-avatar">
                                    {conv.username?.charAt(0).toUpperCase() || '?'}
                                </div>
                                <div className="conversation-info">
                                    <div className="conversation-name">{conv.username || 'Unknown'}</div>
                                    <div className="conversation-preview">{conv.last_message || 'No messages'}</div>
                                </div>
                                {conv.unread_count > 0 && (
                                    <div className="unread-badge">{conv.unread_count}</div>
                                )}
                            </div>
                        ))
                    )}
                </div>
            </div>

            {/* Main Chat Area */}
            <div className="chat-area">
                {selectedConversation ? (
                    <>
                        {/* Chat Header */}
                        <div className="chat-header">
                            <div className="chat-user-info">
                                <div className="chat-avatar">
                                    {selectedConversation.username?.charAt(0).toUpperCase() || '?'}
                                </div>
                                <div>
                                    <div className="chat-username">{selectedConversation.username || 'Unknown'}</div>
                                    <div className="chat-status">🔒 End-to-end encrypted</div>
                                </div>
                            </div>
                            <div className="chat-actions">
                                <button className="btn-icon" title="Video Call">📹</button>
                                <button className="btn-icon" title="Voice Call">📞</button>
                                <button className="btn-icon" title="Info">ℹ️</button>
                            </div>
                        </div>

                        {/* Messages */}
                        <MessageList messages={messages} currentUser={authService.getCurrentUser()} />

                        {/* Input */}
                        <MessageInput onSend={handleSendMessage} disabled={isSending} />
                    </>
                ) : (
                    <div className="empty-chat">
                        <div className="empty-chat-icon">💬</div>
                        <h3>Select a conversation</h3>
                        <p>Choose a conversation from the sidebar to start messaging</p>
                    </div>
                )}
            </div>
        </div>
    );
}

export default MessagesPage;
