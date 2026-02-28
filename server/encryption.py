import os
from cryptography.fernet import Fernet

def get_encryption_key():
    """Get encryption key from Secret Manager (production) or local file (development)"""
    environment = os.getenv("ENVIRONMENT", "development")
    
    if environment == "production":
        try:
            from google.cloud import secretmanager
            
            client = secretmanager.SecretManagerServiceClient()
            project_id = os.getenv("PROJECT_ID")
            if not project_id:
                raise ValueError("PROJECT_ID must be set in production")
            
            secret_name = f"projects/{project_id}/secrets/encryption-key/versions/latest"
            response = client.access_secret_version(request={"name": secret_name})
            print("✅ Loaded encryption key from Secret Manager")
            return response.payload.data
        except Exception as e:
            print(f"❌ Error loading encryption key from Secret Manager: {e}")
            raise
    else:
        # Development: read from local file
        KEY_FILE = "encryption.key"
        
        if os.path.exists(KEY_FILE):
            with open(KEY_FILE, "rb") as f:
                key = f.read()
            print("✅ Loaded existing encryption key from file")
            return key
        else:
            # Generate new key if doesn't exist
            key = Fernet.generate_key()
            with open(KEY_FILE, "wb") as f:
                f.write(key)
            print("🔑 Generated new encryption key")
            return key

# Load encryption key
ENCRYPTION_KEY = get_encryption_key()
cipher = Fernet(ENCRYPTION_KEY)

def encrypt_text(text: str) -> str:
    """Encrypt a text string"""
    if not text:
        return ""
    return cipher.encrypt(text.encode()).decode()

def decrypt_text(encrypted_text: str, allow_failure: bool = True) -> str:
    """
    Decrypt an encrypted text string.
    
    Args:
        encrypted_text: The encrypted text to decrypt
        allow_failure: If True, return "[DECRYPT_FAILED]" on error. If False, raise exception.
    """
    if not encrypted_text:
        return ""
    try:
        return cipher.decrypt(encrypted_text.encode()).decode()
    except Exception as e:
        import logging
        logging.error(f"Decryption failed for data (truncated): ...{encrypted_text[-20:] if len(encrypted_text) > 20 else encrypted_text}")
        
        if allow_failure:
            return "[DECRYPT_FAILED]"  # Visible marker instead of silent empty
        else:
            raise ValueError("Decryption failed") from e

