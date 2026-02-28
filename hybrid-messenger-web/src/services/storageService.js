import { openDB } from 'idb';

const DB_NAME = 'raven_db';
const DB_VERSION = 1;

class StorageService {
    constructor() {
        this.db = null;
    }

    /**
     * Initialize IndexedDB
     */
    async initialize() {
        this.db = await openDB(DB_NAME, DB_VERSION, {
            upgrade(db) {
                // Messages store
                if (!db.objectStoreNames.contains('messages')) {
                    const messageStore = db.createObjectStore('messages', {
                        keyPath: 'id',
                        autoIncrement: false
                    });
                    messageStore.createIndex('conversation', 'conversation_id');
                    messageStore.createIndex('timestamp', 'timestamp');
                }

                // Conversations store
                if (!db.objectStoreNames.contains('conversations')) {
                    const convStore = db.createObjectStore('conversations', {
                        keyPath: 'user_id'
                    });
                    convStore.createIndex('last_message_time', 'last_message_time');
                }

                // Outbox store (for offline messages)
                if (!db.objectStoreNames.contains('outbox')) {
                    const outboxStore = db.createObjectStore('outbox', {
                        keyPath: 'id',
                        autoIncrement: true
                    });
                    outboxStore.createIndex('timestamp', 'timestamp');
                    outboxStore.createIndex('type', 'type'); // 'cloud' or 'bluetooth'
                }

                // Users cache
                if (!db.objectStoreNames.contains('users')) {
                    db.createObjectStore('users', {
                        keyPath: 'id'
                    });
                }
            }
        });

        console.log('✅ IndexedDB initialized');
    }

    // ===== MESSAGES =====

    async saveMessage(message) {
        const tx = this.db.transaction('messages', 'readwrite');
        await tx.store.put(message);
        await tx.done;
    }

    async getMessages(conversationId, limit = 100) {
        const tx = this.db.transaction('messages', 'readonly');
        const index = tx.store.index('conversation');

        let messages = await index.getAll(conversationId);
        messages.sort((a, b) => b.timestamp - a.timestamp);

        return messages.slice(0, limit);
    }

    async deleteMessage(messageId) {
        const tx = this.db.transaction('messages', 'readwrite');
        await tx.store.delete(messageId);
        await tx.done;
    }

    // ===== CONVERSATIONS =====

    async saveConversation(conversation) {
        const tx = this.db.transaction('conversations', 'readwrite');
        await tx.store.put(conversation);
        await tx.done;
    }

    async getConversations() {
        const tx = this.db.transaction('conversations', 'readonly');
        const index = tx.store.index('last_message_time');

        const conversations = await index.getAll();
        return conversations.reverse(); // Most recent first
    }

    async getConversation(userId) {
        const tx = this.db.transaction('conversations', 'readonly');
        return await tx.store.get(userId);
    }

    async deleteConversation(userId) {
        const tx = this.db.transaction('conversations', 'readwrite');
        await tx.store.delete(userId);
        await tx.done;
    }

    // ===== OUTBOX (Offline Queue) =====

    async addToOutbox(message) {
        const tx = this.db.transaction('outbox', 'readwrite');
        const id = await tx.store.add({
            ...message,
            timestamp: Date.now(),
            type: message.type || 'cloud'
        });
        await tx.done;
        return id;
    }

    async getOutbox() {
        const tx = this.db.transaction('outbox', 'readonly');
        return await tx.store.getAll();
    }

    async removeFromOutbox(id) {
        const tx = this.db.transaction('outbox', 'readwrite');
        await tx.store.delete(id);
        await tx.done;
    }

    async clearOutbox() {
        const tx = this.db.transaction('outbox', 'readwrite');
        await tx.store.clear();
        await tx.done;
    }

    // ===== USERS CACHE =====

    async saveUser(user) {
        const tx = this.db.transaction('users', 'readwrite');
        await tx.store.put(user);
        await tx.done;
    }

    async getUser(userId) {
        const tx = this.db.transaction('users', 'readonly');
        return await tx.store.get(userId);
    }

    async getAllUsers() {
        const tx = this.db.transaction('users', 'readonly');
        return await tx.store.getAll();
    }

    // ===== UTILITY =====

    async clearAll() {
        const stores = ['messages', 'conversations', 'outbox', 'users'];
        const tx = this.db.transaction(stores, 'readwrite');

        await Promise.all(stores.map(store => tx.objectStore(store).clear()));
        await tx.done;
    }
}

export const storageService = new StorageService();
export default storageService;
