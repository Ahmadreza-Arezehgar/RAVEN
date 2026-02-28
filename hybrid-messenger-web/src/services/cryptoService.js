/**
 * Crypto Service for End-to-End Encryption
 * Uses Web Crypto API for AES-256-GCM and RSA-2048
 */

class CryptoService {
    constructor() {
        this.keyPair = null;
        this.privateKey = null;
        this.publicKey = null;
    }

    /**
     * Initialize crypto service - generate or load key pair
     */
    async initialize() {
        // Try to load existing keys from IndexedDB
        const storedKeys = await this.loadKeys();

        if (storedKeys) {
            this.privateKey = storedKeys.privateKey;
            this.publicKey = storedKeys.publicKey;
            this.keyPair = storedKeys;
            console.log('✅ Loaded existing encryption keys');
        } else {
            // Generate new key pair
            await this.generateKeyPair();
            await this.saveKeys();
            console.log('✅ Generated new encryption keys');
        }
    }

    /**
     * Generate RSA key pair for key exchange
     */
    async generateKeyPair() {
        this.keyPair = await crypto.subtle.generateKey(
            {
                name: 'RSA-OAEP',
                modulusLength: 2048,
                publicExponent: new Uint8Array([1, 0, 1]),
                hash: 'SHA-256'
            },
            true, // extractable
            ['encrypt', 'decrypt']
        );

        this.privateKey = this.keyPair.privateKey;
        this.publicKey = this.keyPair.publicKey;
    }

    /**
     * Encrypt message with AES-256-GCM
     */
    async encryptMessage(plaintext, recipientPublicKey) {
        try {
            // Generate random AES key
            const aesKey = await crypto.subtle.generateKey(
                {
                    name: 'AES-GCM',
                    length: 256
                },
                true,
                ['encrypt', 'decrypt']
            );

            // Generate random IV
            const iv = crypto.getRandomValues(new Uint8Array(12));

            // Encode plaintext
            const encoder = new TextEncoder();
            const data = encoder.encode(plaintext);

            // Encrypt with AES
            const encryptedData = await crypto.subtle.encrypt(
                {
                    name: 'AES-GCM',
                    iv: iv
                },
                aesKey,
                data
            );

            // Export AES key
            const exportedKey = await crypto.subtle.exportKey('raw', aesKey);

            // Encrypt AES key with recipient's public key (if provided)
            let encryptedKey;
            if (recipientPublicKey) {
                encryptedKey = await crypto.subtle.encrypt(
                    {
                        name: 'RSA-OAEP'
                    },
                    recipientPublicKey,
                    exportedKey
                );
            } else {
                encryptedKey = exportedKey; // For testing/local storage
            }

            // Return encrypted package
            return {
                encryptedData: this.arrayBufferToBase64(encryptedData),
                encryptedKey: this.arrayBufferToBase64(encryptedKey),
                iv: this.arrayBufferToBase64(iv)
            };
        } catch (error) {
            console.error('Encryption error:', error);
            throw error;
        }
    }

    /**
     * Decrypt message with AES-256-GCM
     */
    async decryptMessage(encryptedPackage) {
        try {
            const { encryptedData, encryptedKey, iv } = encryptedPackage;

            // Convert from base64
            const encDataBuffer = this.base64ToArrayBuffer(encryptedData);
            const encKeyBuffer = this.base64ToArrayBuffer(encryptedKey);
            const ivBuffer = this.base64ToArrayBuffer(iv);

            // Decrypt AES key with private key
            const aesKeyBuffer = await crypto.subtle.decrypt(
                {
                    name: 'RSA-OAEP'
                },
                this.privateKey,
                encKeyBuffer
            );

            // Import AES key
            const aesKey = await crypto.subtle.importKey(
                'raw',
                aesKeyBuffer,
                {
                    name: 'AES-GCM',
                    length: 256
                },
                false,
                ['decrypt']
            );

            // Decrypt data
            const decryptedData = await crypto.subtle.decrypt(
                {
                    name: 'AES-GCM',
                    iv: ivBuffer
                },
                aesKey,
                encDataBuffer
            );

            // Decode to string
            const decoder = new TextDecoder();
            return decoder.decode(decryptedData);
        } catch (error) {
            console.error('Decryption error:', error);
            throw error;
        }
    }

    /**
     * Export public key to share with others
     */
    async exportPublicKey() {
        const exported = await crypto.subtle.exportKey('spki', this.publicKey);
        return this.arrayBufferToBase64(exported);
    }

    /**
     * Import someone else's public key
     */
    async importPublicKey(base64Key) {
        const keyData = this.base64ToArrayBuffer(base64Key);
        return await crypto.subtle.importKey(
            'spki',
            keyData,
            {
                name: 'RSA-OAEP',
                hash: 'SHA-256'
            },
            true,
            ['encrypt']
        );
    }

    /**
     * Generate HMAC for message authentication
     */
    async generateHMAC(message, key) {
        const encoder = new TextEncoder();
        const data = encoder.encode(message);

        const hmacKey = await crypto.subtle.importKey(
            'raw',
            encoder.encode(key),
            {
                name: 'HMAC',
                hash: 'SHA-256'
            },
            false,
            ['sign']
        );

        const signature = await crypto.subtle.sign('HMAC', hmacKey, data);
        return this.arrayBufferToBase64(signature);
    }

    /**
     * Verify HMAC
     */
    async verifyHMAC(message, signature, key) {
        const encoder = new TextEncoder();
        const data = encoder.encode(message);

        const hmacKey = await crypto.subtle.importKey(
            'raw',
            encoder.encode(key),
            {
                name: 'HMAC',
                hash: 'SHA-256'
            },
            false,
            ['verify']
        );

        const signatureBuffer = this.base64ToArrayBuffer(signature);
        return await crypto.subtle.verify('HMAC', hmacKey, signatureBuffer, data);
    }

    /**
     * Save keys to IndexedDB
     */
    async saveKeys() {
        const exportedPrivate = await crypto.subtle.exportKey('pkcs8', this.privateKey);
        const exportedPublic = await crypto.subtle.exportKey('spki', this.publicKey);

        localStorage.setItem('crypto_keys', JSON.stringify({
            privateKey: this.arrayBufferToBase64(exportedPrivate),
            publicKey: this.arrayBufferToBase64(exportedPublic)
        }));
    }

    /**
     * Load keys from IndexedDB
     */
    async loadKeys() {
        const stored = localStorage.getItem('crypto_keys');
        if (!stored) return null;

        const { privateKey, publicKey } = JSON.parse(stored);

        const privateKeyBuffer = this.base64ToArrayBuffer(privateKey);
        const publicKeyBuffer = this.base64ToArrayBuffer(publicKey);

        const importedPrivate = await crypto.subtle.importKey(
            'pkcs8',
            privateKeyBuffer,
            {
                name: 'RSA-OAEP',
                hash: 'SHA-256'
            },
            true,
            ['decrypt']
        );

        const importedPublic = await crypto.subtle.importKey(
            'spki',
            publicKeyBuffer,
            {
                name: 'RSA-OAEP',
                hash: 'SHA-256'
            },
            true,
            ['encrypt']
        );

        return {
            privateKey: importedPrivate,
            publicKey: importedPublic
        };
    }

    /**
     * Utility: ArrayBuffer to Base64
     */
    arrayBufferToBase64(buffer) {
        const bytes = new Uint8Array(buffer);
        let binary = '';
        for (let i = 0; i < bytes.byteLength; i++) {
            binary += String.fromCharCode(bytes[i]);
        }
        return btoa(binary);
    }

    /**
     * Utility: Base64 to ArrayBuffer
     */
    base64ToArrayBuffer(base64) {
        const binary = atob(base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) {
            bytes[i] = binary.charCodeAt(i);
        }
        return bytes.buffer;
    }
}

export const cryptoService = new CryptoService();
export default cryptoService;
