"""
Ed25519 signature verification for mesh bridge uplink.

Verifies that bridge devices signing relay actions are cryptographically
accountable. The bridge signs: "relay:{messageId}:{senderId}:{recipientId}"
with its Ed25519 private key, and the server verifies using the public key.
"""

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature
import base64
import logging

logger = logging.getLogger(__name__)


def verify_bridge_signature(
    message_id: str,
    sender_id: str,
    recipient_id: str,
    bridge_signature_b64: str,
    bridge_public_key_b64: str
) -> bool:
    """
    Verify Ed25519 signature from a bridge device.
    
    The bridge signs the string "relay:{messageId}:{senderId}:{recipientId}"
    with its device Ed25519 key. This function verifies that signature.
    
    Returns True if signature is valid, False otherwise.
    """
    try:
        if not bridge_signature_b64 or not bridge_public_key_b64:
            logger.warning("🚨 [MeshCrypto] Missing bridge signature or public key")
            return False
        
        # Decode base64
        signature = base64.b64decode(bridge_signature_b64)
        public_key_bytes = base64.b64decode(bridge_public_key_b64)
        
        # Reconstruct signed data (must match iOS format exactly)
        relay_data = f"relay:{message_id}:{sender_id}:{recipient_id}".encode("utf-8")
        
        # Load Ed25519 public key
        public_key = Ed25519PublicKey.from_public_bytes(public_key_bytes)
        
        # Verify
        public_key.verify(signature, relay_data)
        
        logger.info(f"✅ [MeshCrypto] Bridge signature verified for message {message_id[:8]}")
        return True
        
    except InvalidSignature:
        logger.warning(f"🚨 [MeshCrypto] INVALID bridge signature for message {message_id[:8]}")
        return False
    except Exception as e:
        logger.error(f"🚨 [MeshCrypto] Verification error: {e}")
        return False
