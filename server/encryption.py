"""
encryption.py — server-side content storage.

ROUND 22 (2026-05-16) — closes hacker-audit finding F1 (CRITICAL).

Before this round every message body that came through the API was
wrapped with a server-held Fernet symmetric key (Secret Manager /
encryption.key file) before persistence. That gave the server admin
— and anyone with read access to Secret Manager — a master key that
decrypts every chat row in the database. The Fernet wrap was always
defense in depth, not real privacy; the audit correctly called it
"server-side at-rest re-encryption" that "treats E2EE as a polite
fiction once a message lands on the server."

The fix:
  • When the incoming body is already an opaque E2EE envelope —
    base64(RVNS1‖ciphertext), base64(RVNP1‖plaintext), or the
    legacy group AES-GCM blob with a `group_key_version` — we
    PASS IT THROUGH UNCHANGED. The server stores what the sender
    put on the wire; only the recipient with the right key can
    read it.
  • For everything else (system messages, legacy clients that
    pre-date the RVNS1/RVNP1 magic), we keep the Fernet wrap so
    the at-rest column isn't plaintext.

The result: post-round-21 clients (which always seal DMs and
groups) deposit opaque bodies; the server admin can no longer
unwrap them with the master Fernet key.
"""

import base64
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

# Round 22 — sentinel prefix that marks a body as "this is the
# client's opaque envelope, do NOT touch". Stored as a column-level
# tag so a future migration / read path can detect untouched bodies
# without expensive Base64 sniffing. We keep the bytes-after-the-
# prefix exactly as the client sent them.
OPAQUE_PREFIX = "RVNX1:"        # short ASCII tag, won't collide with Fernet's "gAAAA"

# RVNS1 / RVNP1 magic bytes, Base64-encoded — what the iOS sealer
# (MessageContentSealer.swift) actually puts on the wire. Anything
# whose Base64 decodes to start with these bytes is opaque end-to-end.
_SEALED_MAGIC = b"RVNS1\0\0\0"     # 8 bytes
_PLAIN_MAGIC = b"RVNP1\0\0\0"      # 8 bytes


def _looks_opaque_envelope(text: str) -> bool:
    """True iff `text` is a Base64 envelope the client sealer wrote.

    We try to decode the first ~16 bytes only and compare against the
    two known magic prefixes. Anything else is treated as legacy
    plaintext and gets the Fernet wrap.
    """
    if not text or len(text) < 12:
        return False
    # Pre-existing Fernet ciphertext always starts with "gAAAA" —
    # never treat it as opaque (would double-flag on retry).
    if text.startswith("gAAAA"):
        return False
    try:
        head = base64.b64decode(text[:24], validate=False)
    except Exception:
        return False
    return head.startswith(_SEALED_MAGIC) or head.startswith(_PLAIN_MAGIC)


def encrypt_text(text: str, is_opaque: bool = False) -> str:
    """Encrypt a text string for at-rest storage.

    Round 22: if `text` already carries an opaque E2EE envelope
    (RVNS1 / RVNP1), we tag it with OPAQUE_PREFIX and store as-is.

    🔴 ROUND 26 — hacker-audit Server F2 HIGH fix.
    The auto-heuristic `_looks_opaque_envelope` misses round-21
    group ciphertext (it's a raw AES-GCM blob, no RVNS1/RVNP1
    magic — those would belong to the per-pair Noise sealer, and
    group bodies use the shared symmetric key path instead). So
    EVERY group message was getting the Fernet wrap, defeating
    the F1 fix for groups: server admin saw the raw AES-GCM blob
    (couldn't decrypt) but had ALL the metadata in plaintext
    (`row.content`, `row.sender_id`, `row.created_at`).

    Callers that KNOW the body is opaque (group bridge endpoint,
    DM send with sealed content) can now pass `is_opaque=True`
    to force the passthrough without relying on the magic-byte
    sniff. The heuristic still catches RVNS1/RVNP1 implicit
    cases so existing callers don't need to change.
    """
    if not text:
        return ""
    if is_opaque or _looks_opaque_envelope(text):
        return OPAQUE_PREFIX + text
    return cipher.encrypt(text.encode()).decode()


def decrypt_text(encrypted_text: str, allow_failure: bool = True) -> str:
    """Decrypt an at-rest column back to wire-format text.

    Round 22: tagged opaque rows are returned untouched — the
    receiver's client is what unwraps them. Fernet-tagged rows are
    decrypted as before. Legacy pre-tag rows assume Fernet for
    back-compat.
    """
    if not encrypted_text:
        return ""

    # Round 22 — opaque envelope passthrough.
    if encrypted_text.startswith(OPAQUE_PREFIX):
        return encrypted_text[len(OPAQUE_PREFIX):]

    try:
        return cipher.decrypt(encrypted_text.encode()).decode()
    except Exception as e:
        import logging
        logging.error(
            "Decryption failed for data (truncated): ...%s",
            encrypted_text[-20:] if len(encrypted_text) > 20 else encrypted_text,
        )

        if allow_failure:
            return "[DECRYPT_FAILED]"  # Visible marker instead of silent empty
        else:
            raise ValueError("Decryption failed") from e
