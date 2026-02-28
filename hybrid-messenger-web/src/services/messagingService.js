import axios from 'axios';
import { authService } from './authService';

const API_BASE_URL = import.meta.env.VITE_API_URL || 'https://hybrid-messenger-api-516053629173.us-central1.run.app';

class MessagingService {
    constructor() {
        this.messages = [];
        this.conversations = new Map();
        this.messageHandlers = [];
    }

    /**
     * Send a message (cloud API)
     */
    async sendMessage(recipientId, content, encryptedContent) {
        try {
            const response = await axios.post(
                `${API_BASE_URL}/api/messages`,
                {
                    recipient_id: recipientId,
                    content: encryptedContent || content, // Use encrypted if provided
                    timestamp: Date.now()
                },
                {
                    headers: authService.getHeaders()
                }
            );

            const message = response.data;

            // Add to local storage
            await this.addMessage(message);

            // Notify handlers
            this.notifyHandlers(message);

            return message;
        } catch (error) {
            console.error('Error sending message:', error);
            throw error;
        }
    }

    /**
     * Get messages with a specific user
     */
    async getMessages(userId, limit = 50) {
        try {
            const response = await axios.get(
                `${API_BASE_URL}/api/messages/${userId}`,
                {
                    params: { limit },
                    headers: authService.getHeaders()
                }
            );

            const messages = response.data.messages || [];

            // Store in local cache
            for (const msg of messages) {
                await this.addMessage(msg);
            }

            return messages;
        } catch (error) {
            console.error('Error fetching messages:', error);
            return [];
        }
    }

    /**
     * Get all conversations
     */
    async getConversations() {
        try {
            const response = await axios.get(
                `${API_BASE_URL}/api/messages/conversations`,
                {
                    headers: authService.getHeaders()
                }
            );

            const conversations = response.data.conversations || [];

            // Update local cache
            conversations.forEach(conv => {
                this.conversations.set(conv.user_id, conv);
            });

            return conversations;
        } catch (error) {
            console.error('Error fetching conversations:', error);
            return [];
        }
    }

    /**
     * Add message to local storage
     */
    async addMessage(message) {
        // Check if already exists
        const exists = this.messages.find(m => m.id === message.id);
        if (!exists) {
            this.messages.push(message);

            // Sort by timestamp
            this.messages.sort((a, b) => a.timestamp - b.timestamp);
        }
    }

    /**
     * Get local messages for a conversation
     */
    getLocalMessages(userId) {
        const currentUser = authService.getCurrentUser();
        if (!currentUser) return [];

        return this.messages.filter(msg =>
            (msg.sender_id === currentUser.id && msg.recipient_id === userId) ||
            (msg.recipient_id === currentUser.id && msg.sender_id === userId)
        );
    }

    /**
     * Register a message handler
     */
    onMessage(handler) {
        this.messageHandlers.push(handler);

        return () => {
            const index = this.messageHandlers.indexOf(handler);
            if (index > -1) {
                this.messageHandlers.splice(index, 1);
            }
        };
    }

    /**
     * Notify all handlers of new message
     */
    notifyHandlers(message) {
        this.messageHandlers.forEach(handler => handler(message));
    }

    /**
     * Mark messages as read
     */
    async markAsRead(messageIds) {
        try {
            await axios.post(
                `${API_BASE_URL}/api/messages/read`,
                { message_ids: messageIds },
                {
                    headers: authService.getHeaders()
                }
            );
        } catch (error) {
            console.error('Error marking as read:', error);
        }
    }

    /**
     * Delete a message
     */
    async deleteMessage(messageId) {
        try {
            await axios.delete(
                `${API_BASE_URL}/api/messages/${messageId}`,
                {
                    headers: authService.getHeaders()
                }
            );

            // Remove from local storage
            this.messages = this.messages.filter(m => m.id !== messageId);
        } catch (error) {
            console.error('Error deleting message:', error);
            throw error;
        }
    }

    /**
     * Search messages
     */
    searchMessages(query) {
        return this.messages.filter(msg =>
            msg.content.toLowerCase().includes(query.toLowerCase())
        );
    }

    /**
     * Clear all local data
     */
    clear() {
        this.messages = [];
        this.conversations.clear();
    }
}

export const messagingService = new MessagingService();
export default messagingService;
