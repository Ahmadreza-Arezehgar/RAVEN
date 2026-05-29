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


def verify_message_signature(
    *,
    content: str,
    signature_b64: str,
    public_key_b64: str,
    # 🔴 ROUND 70 (2026-05-23) — new canonical-signature parameters.
    # Optional for back-compat with round-26 senders, but a client
    # that supplies any of them gets the stronger verification path.
    sender_id: str | None = None,
    recipient_id: str | None = None,
    message_id: str | None = None,
) -> bool:
    """Verify the original sender's Ed25519 signature over the
    bridge-forwarded message body.

    🔴 ROUND 26 — closes hacker-audit Server F3 HIGH.
    🔴 ROUND 70 — extends to the canonical (sender,recip,msgId,content)
    transcript so a replayed signature for content X cannot be
    re-attributed to a forged (sender, recipient, msgId) triple.

    Round-26 weakness: a signature covered ONLY `content` — so an
    attacker who captured any signed message from victim (e.g. a
    public post body, or a prior legit bridge) could re-attach the
    same signature to a forged (sender_id=victim, recipient_id=X,
    message_id=Y) triple and the receiver's UI would attribute it.

    Round-70 verification:
      1. If the caller supplies sender_id+recipient_id+message_id,
         the canonical payload is reconstructed as
            "msg-v1:{sender_id}:{recipient_id}:{message_id}:{content}"
         and verified. This is the only payload a round-70+ client
         signs.
      2. Falls back to the legacy `content`-only payload for
         backward compatibility with round-26..69 clients. A
         future flag-day flip drops this branch.

    Returns True iff EITHER verification succeeds; False otherwise.
    """
    try:
        if not content or not signature_b64 or not public_key_b64:
            return False
        signature = base64.b64decode(signature_b64)
        pub_raw = base64.b64decode(public_key_b64)
        if len(pub_raw) != 32:
            return False
        public_key = Ed25519PublicKey.from_public_bytes(pub_raw)

        # Round 70: try the canonical (sender, recipient, msgId,
        # content) transcript FIRST. If any of the three fields is
        # missing, fall through to the legacy content-only path.
        #
        # 🔴 ROUND 71 S17: when the caller HAS supplied a full
        # (sender, recipient, msgId) tuple, the canonical verify
        # is the ONLY acceptable path. Legacy fallback was being
        # exploited: any captured signature over `content` bytes
        # (a prior public bridge of "ok") could be re-attached to
        # forged (sender, recipient, msgId) and pass via the
        # fall-through. Now: canonical-eligible callers either
        # verify canonically or fail; only callers without enough
        # context (no sender/recip/msgId) keep the legacy path.
        if sender_id and recipient_id and message_id:
            canonical = (
                f"msg-v1:{sender_id}:{recipient_id}:{message_id}:{content}"
            ).encode("utf-8")
            try:
                public_key.verify(signature, canonical)
                return True
            except InvalidSignature:
                logger.warning(
                    "🚨 [MeshCrypto] canonical-format signature INVALID and "
                    "fallback to content-only DISALLOWED (round 71): "
                    "sender/recipient/msgId fields were supplied so legacy "
                    "fallback would defeat the round-70 transcript binding."
                )
                return False

        # Legacy round-26 path — only reached when caller can't supply
        # the canonical fields (e.g. pre-round-70 ingress paths).
        # Once every ingress has been migrated, delete this branch.
        public_key.verify(signature, content.encode("utf-8"))
        return True
    except InvalidSignature:
        logger.warning("🚨 [MeshCrypto] INVALID original-sender signature on bridge upload")
        return False
    except Exception as e:
        logger.error(f"🚨 [MeshCrypto] verify_message_signature error: {e}")
        return False
