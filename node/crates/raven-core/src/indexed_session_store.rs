//! Durable, production-disabled state for the ATSAM Indexed Session Profile V1.
//!
//! This module is intentionally not connected to live networking. Secret
//! roots, chain keys, skipped message keys, and the write-ahead acceptance
//! journal live in a platform-protected backend. SQLite contains public
//! binding/dedup metadata plus locally sealed inbox and ACK-intent records.
//!
//! Mutation ordering is deliberately asymmetric: the protected head is
//! replaced first and SQLite commits second. A crash between those operations
//! can burn an outbound index, but reopening only fast-forwards metadata and
//! therefore never rolls a ratchet back or reuses a send key. Inbound endpoint
//! acceptance uses a protected pending journal to bridge the protected-store /
//! SQLite commit boundary without ever journaling plaintext.
//!
//! ACK intent creation, origin-side ACK acceptance, outbound message
//! preparation, and ACK materialization are implemented here. Outbound paths
//! use the same protected-journal ordering and only hand immutable ciphertext
//! to an idempotent durable queue callback. The entire actor remains
//! production-disabled and has no live transport callsite.

#[cfg(test)]
use std::cell::Cell;
use std::collections::BTreeMap;
use std::fmt;
use std::path::Path;
#[cfg(any(windows, test))]
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::rngs::OsRng;
use rand::{CryptoRng, RngCore};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::ack::Ack;
use crate::atsam_indexed_session::{
    ack_base_key, decode_signed_ack, derive_route_tag, encode_signed_ack,
    open_indexed_message_with_key, parse_indexed_message_header, seal_indexed_message_with_key,
    session_context, Direction, SignedAck, PROFILE_ID,
};
use crate::atsam_kdf::{advance_chain_key, initial_chain_key, message_key};
use crate::bridge::authenticated_object_digest;
use crate::device_cert::{DeviceCertificate, DeviceRegistry};
use crate::envelope::{EnvType, Envelope};
use crate::identity::Identity;
use crate::pair_init::{
    device_certificate_hash, encode_response as encode_pair_response, init_hash as pair_init_hash,
    session_id as pair_session_id, session_id_from_init_hash,
    transcript_hash as pair_transcript_hash, verify_init, verify_response, PairInit, PairInitError,
    PairInitTrust, PairResponse,
};

/// Live networking must not instantiate or consume this store yet.
pub const INDEXED_SESSION_STORE_PRODUCTION_ENABLED: bool = false;

pub fn live_enabled() -> bool {
    INDEXED_SESSION_STORE_PRODUCTION_ENABLED || crate::pair_init::lab_test_a_enabled()
}
pub const INDEXED_SESSION_METADATA_FILE: &str = "indexed_sessions.sqlite";
pub const MAX_SKIPPED_KEYS: usize = 256;
pub const MAX_FORWARD_JUMP: u64 = 256;
pub const MAX_ENDPOINT_TEXT_BYTES: usize = 256 * 1024;
pub const MAX_ENDPOINT_FUTURE_SKEW_MS: u64 = 5 * 60 * 1_000;
pub const MAX_ENDPOINT_ENVELOPE_LIFETIME_MS: u64 = 7 * 24 * 60 * 60 * 1_000;

const STORE_MAGIC: &[u8; 8] = b"RVNISS01";
const LEGACY_STORE_VERSION: u8 = 1;
const ACCEPTANCE_STORE_VERSION: u8 = 2;
const STORE_VERSION: u8 = 3;
const STORE_INTEGRITY_LABEL: &[u8] = b"ATSAM/indexed-session/v1/store-integrity";
const LOCAL_STORAGE_LABEL: &[u8] = b"ATSAM/v1/endpoint-local-storage";
const LOCAL_STORAGE_AAD_LABEL: &[u8] = b"ATSAM/v1/endpoint-local-storage/aad";
const LOCAL_ROW_VERSION: u8 = 1;
const MAX_SEALED_LOCAL_ROW_BYTES: usize = MAX_ENDPOINT_TEXT_BYTES + 128;
const MAX_PENDING_OUTBOUND_BYTES: usize = MAX_ENDPOINT_TEXT_BYTES + 512;
const OUTBOUND_FLAGS: u16 = 0;
const OUTBOUND_HOP_LIMIT: u8 = 8;
const OUTBOUND_REPLICATION_BUDGET: u8 = 2;
const RECORD_KEY_DOMAIN: &[u8] = b"rvn1/indexed-session/record-key/v1";
const BINDING_DIGEST_DOMAIN: &[u8] = b"rvn1/indexed-session/binding/v1";
#[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
const PLATFORM_SERVICE: &str = "app.raven.node.atsam-indexed-session";
#[cfg(not(any(
    target_os = "macos",
    windows,
    all(target_os = "linux", target_env = "gnu")
)))]
const PROTECTED_STORE_UNAVAILABLE: &str = "no supported platform-protected secret backend";
const MAX_ADDRESS_BYTES: usize = 128;
const MAX_PROFILE_BYTES: usize = 64;

type EndpointInboxDbRow = (Vec<u8>, Vec<u8>, Vec<u8>, i64, i64, Vec<u8>);
type EndpointPendingAckDbRow = (
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
    Vec<u8>,
    i64,
    i64,
    Option<Vec<u8>>,
);
type EndpointInboxRecoveryDbRow = (Vec<u8>, Vec<u8>, i64, i64, Vec<u8>);
type EndpointReceiptIdentity = ([u8; 16], [u8; 32], u64);
type EndpointOutboxDbRow = (Vec<u8>, Vec<u8>, i64, Vec<u8>, Vec<u8>, i64, i64, Vec<u8>);
type EndpointAckIntentDbRow = (Vec<u8>, Vec<u8>, i64, i64, Option<Vec<u8>>);
type EndpointOutboxDetailsDbRow = (Option<Vec<u8>>, Option<Vec<u8>>, Vec<u8>, Vec<u8>, i64);

struct AckReceiptIdentity {
    outer_message_id: [u8; 16],
    remote_device: [u8; 32],
    acked_message_id: [u8; 16],
}

fn endpoint_time_window_valid(created_at_ms: u64, expires_at_ms: u64, now_ms: u64) -> bool {
    created_at_ms < expires_at_ms
        && expires_at_ms.saturating_sub(created_at_ms) <= MAX_ENDPOINT_ENVELOPE_LIFETIME_MS
        && created_at_ms <= now_ms.saturating_add(MAX_ENDPOINT_FUTURE_SKEW_MS)
        && expires_at_ms > now_ms
}

fn valid_endpoint_text(plaintext: &[u8]) -> bool {
    if plaintext.is_empty() || plaintext.len() > MAX_ENDPOINT_TEXT_BYTES {
        return false;
    }
    let Ok(text) = std::str::from_utf8(plaintext) else {
        return false;
    };
    text.chars().all(|character| {
        character == '\t'
            || character == '\n'
            || character == '\r'
            || (character >= ' ' && character != '\u{7f}')
    })
}

#[derive(Clone, PartialEq, Eq)]
pub enum EndpointAcceptance {
    Committed {
        session_id: [u8; 32],
        object_digest: [u8; 32],
        message_id: [u8; 16],
        plaintext: Vec<u8>,
    },
    Duplicate {
        session_id: [u8; 32],
        object_digest: [u8; 32],
        message_id: [u8; 16],
    },
}

impl fmt::Debug for EndpointAcceptance {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (kind, plaintext) = match self {
            Self::Committed { .. } => ("Committed", Some("<redacted>")),
            Self::Duplicate { .. } => ("Duplicate", None),
        };
        let mut value = formatter.debug_struct("EndpointAcceptance");
        value
            .field("kind", &kind)
            .field("identifiers", &"<redacted>");
        if let Some(plaintext) = plaintext {
            value.field("plaintext", &plaintext);
        }
        value.finish()
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct EndpointInboxRow {
    pub session_id: [u8; 32],
    pub object_digest: [u8; 32],
    pub message_id: [u8; 16],
    pub sender_device: [u8; 32],
    pub created_at_ms: u64,
    pub received_at_ms: u64,
    pub plaintext: Vec<u8>,
}

impl fmt::Debug for EndpointInboxRow {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("EndpointInboxRow")
            .field("identifiers", &"<redacted>")
            .field("created_at_ms", &self.created_at_ms)
            .field("received_at_ms", &self.received_at_ms)
            .field("plaintext", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EndpointAckIntentState {
    Pending = 0,
    Queued = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
#[repr(u8)]
pub enum EndpointDeliveryState {
    Sent = 0,
    Delivered = 1,
    Read = 2,
}

impl EndpointDeliveryState {
    fn from_u8(value: u8) -> Result<Self, IndexedSessionStoreError> {
        match value {
            0 => Ok(Self::Sent),
            1 => Ok(Self::Delivered),
            2 => Ok(Self::Read),
            _ => Err(IndexedSessionStoreError::CorruptEndpointState),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EndpointAckAcceptance {
    Committed {
        session_id: [u8; 32],
        object_digest: [u8; 32],
        acked_message_id: [u8; 16],
        delivery_state: EndpointDeliveryState,
    },
    Duplicate {
        session_id: [u8; 32],
        object_digest: [u8; 32],
        acked_message_id: [u8; 16],
        delivery_state: EndpointDeliveryState,
    },
}

impl EndpointAckIntentState {
    fn from_u8(value: u8) -> Result<Self, IndexedSessionStoreError> {
        match value {
            0 => Ok(Self::Pending),
            1 => Ok(Self::Queued),
            _ => Err(IndexedSessionStoreError::CorruptEndpointState),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EndpointAckIntent {
    pub session_id: [u8; 32],
    pub object_digest: [u8; 32],
    pub message_id: [u8; 16],
    pub remote_device: [u8; 32],
    pub status: u8,
    pub state: EndpointAckIntentState,
    pub immutable_ack_bytes: Option<Vec<u8>>,
}

/// A local-device signing capability borrowed from the exact current device
/// registry entry. Its fields are private so callers cannot construct a token
/// around an unregistered signer or a lookalike certificate.
pub struct AuthorizedEndpointDevice<'a> {
    certificate: &'a DeviceCertificate,
    signer: &'a Identity,
    registry: &'a DeviceRegistry,
}

impl fmt::Debug for AuthorizedEndpointDevice<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AuthorizedEndpointDevice")
            .field("device", &"<redacted>")
            .finish()
    }
}

impl<'a> AuthorizedEndpointDevice<'a> {
    /// Creates a short-lived authorization token. The registry remains
    /// immutably borrowed for the token lifetime, preventing a revoke/update
    /// race inside one outbound transaction.
    pub fn authorize(
        certificate: &'a DeviceCertificate,
        signer: &'a Identity,
        registry: &'a DeviceRegistry,
        now_ms: u64,
    ) -> Result<Self, IndexedSessionStoreError> {
        if signer.public_key_bytes() != certificate.device_ed_pub
            || certificate.verify(now_ms).is_err()
            || registry.revoked.contains(&certificate.device_id)
            || registry.certs.get(&certificate.device_id) != Some(certificate)
        {
            return Err(IndexedSessionStoreError::LocalDeviceUnauthorized);
        }
        Ok(Self {
            certificate,
            signer,
            registry,
        })
    }

    fn validate_current(&self, now_ms: u64) -> Result<(), IndexedSessionStoreError> {
        if self.signer.public_key_bytes() != self.certificate.device_ed_pub
            || self.certificate.verify(now_ms).is_err()
            || self.registry.revoked.contains(&self.certificate.device_id)
            || self.registry.certs.get(&self.certificate.device_id) != Some(self.certificate)
        {
            return Err(IndexedSessionStoreError::LocalDeviceUnauthorized);
        }
        Ok(())
    }

    fn sign_verified(&self, bytes: &[u8]) -> Result<[u8; 64], IndexedSessionStoreError> {
        let signature = self.signer.sign(bytes);
        if !Identity::verify(&self.certificate.device_ed_pub, bytes, &signature) {
            return Err(IndexedSessionStoreError::LocalSignerFailure);
        }
        Ok(signature)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EndpointOutboundKind {
    Message = 1,
    Ack = 2,
}

impl EndpointOutboundKind {
    fn from_u8(value: u8) -> Result<Self, IndexedSessionStoreError> {
        match value {
            1 => Ok(Self::Message),
            2 => Ok(Self::Ack),
            _ => Err(IndexedSessionStoreError::CorruptEndpointState),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum EndpointOutboxState {
    Prepared = 0,
    Queued = 1,
}

impl EndpointOutboxState {
    fn from_u8(value: u8) -> Result<Self, IndexedSessionStoreError> {
        match value {
            0 => Ok(Self::Prepared),
            1 => Ok(Self::Queued),
            _ => Err(IndexedSessionStoreError::CorruptEndpointState),
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct EndpointOutbound {
    pub kind: EndpointOutboundKind,
    pub session_id: [u8; 32],
    pub object_digest: [u8; 32],
    pub message_id: [u8; 16],
    pub recipient_device: [u8; 32],
    pub ratchet_index: u32,
    pub state: EndpointOutboxState,
    /// Exact signed RVN1 bytes. These contain ciphertext, never application
    /// plaintext or ratchet keys.
    pub immutable_envelope_bytes: Vec<u8>,
}

impl fmt::Debug for EndpointOutbound {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("EndpointOutbound")
            .field("kind", &self.kind)
            .field("session", &"<redacted>")
            .field("object", &"<redacted>")
            .field("message", &"<redacted>")
            .field("recipient", &"<redacted>")
            .field("ratchet_index", &self.ratchet_index)
            .field("state", &self.state)
            .field("immutable_envelope_bytes", &"<ciphertext>")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum LocalRole {
    Initiator = 0,
    Responder = 1,
}

impl LocalRole {
    fn from_u8(value: u8) -> Result<Self, IndexedSessionStoreError> {
        match value {
            0 => Ok(Self::Initiator),
            1 => Ok(Self::Responder),
            _ => Err(IndexedSessionStoreError::CorruptProtectedState),
        }
    }

    fn outbound_direction(self) -> Direction {
        match self {
            Self::Initiator => Direction::InitiatorToResponder,
            Self::Responder => Direction::ResponderToInitiator,
        }
    }

    fn inbound_direction(self) -> Direction {
        match self {
            Self::Initiator => Direction::ResponderToInitiator,
            Self::Responder => Direction::InitiatorToResponder,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SessionLifecycle {
    Provisional = 0,
    Confirmed = 1,
}

impl SessionLifecycle {
    fn from_u8(value: u8) -> Result<Self, IndexedSessionStoreError> {
        match value {
            0 => Ok(Self::Provisional),
            1 => Ok(Self::Confirmed),
            _ => Err(IndexedSessionStoreError::CorruptProtectedState),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum RatchetLane {
    Message = 0,
    Ack = 1,
}

/// Public identity of a session record. The digest of these exact fields is
/// the protected-backend account and SQLite primary key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexedSessionRecordKey {
    pub profile_id: Vec<u8>,
    pub initiator_address: String,
    pub responder_address: String,
    pub initiator_device_ed25519: [u8; 32],
    pub responder_device_ed25519: [u8; 32],
    pub init_id: [u8; 16],
}

/// PairInit-bound public metadata. Secret material is never stored in this
/// value or in SQLite.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexedSessionBinding {
    pub key: IndexedSessionRecordKey,
    pub session_id: [u8; 32],
    pub init_hash: [u8; 32],
    pub transcript_hash: [u8; 32],
    pub initiator_cert_digest: [u8; 32],
    pub responder_cert_digest: [u8; 32],
    pub responder_prekey_bundle_digest: [u8; 32],
    pub signed_prekey_id: u32,
    pub one_time_prekey_id: u32,
    pub created_at_ms: u64,
    pub expires_at_ms: u64,
    pub local_role: LocalRole,
    pub lifecycle: SessionLifecycle,
    pub response_hash: Option<[u8; 32]>,
}

impl IndexedSessionBinding {
    pub fn validate(&self) -> Result<(), IndexedSessionStoreError> {
        if self.key.profile_id.as_slice() != PROFILE_ID {
            return Err(IndexedSessionStoreError::UnsupportedProfile);
        }
        session_context(&self.key.initiator_address, &self.key.responder_address)
            .map_err(|_| IndexedSessionStoreError::InvalidBinding)?;
        if self.key.initiator_address.len() > MAX_ADDRESS_BYTES
            || self.key.responder_address.len() > MAX_ADDRESS_BYTES
            || self.key.profile_id.len() > MAX_PROFILE_BYTES
            || self.key.init_id == [0; 16]
            || self.created_at_ms >= self.expires_at_ms
            || self.created_at_ms > i64::MAX as u64
            || self.expires_at_ms > i64::MAX as u64
        {
            return Err(IndexedSessionStoreError::InvalidBinding);
        }
        let expected_session_id = session_id_from_init_hash(&self.init_hash);
        if self.session_id != expected_session_id {
            return Err(IndexedSessionStoreError::InvalidBinding);
        }
        match (self.lifecycle, self.response_hash) {
            (SessionLifecycle::Provisional, None) | (SessionLifecycle::Confirmed, Some(_)) => {}
            _ => return Err(IndexedSessionStoreError::InvalidBinding),
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum IndexedSessionStoreError {
    #[error("indexed session SQLite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("protected session store unavailable: {0}")]
    ProtectedStore(String),
    #[error("protected session state is missing")]
    ProtectedStateMissing,
    #[error("protected session state is corrupt")]
    CorruptProtectedState,
    #[error("protected state generation is behind metadata; refusing rollback")]
    RollbackDetected,
    #[error("session record not found")]
    NotFound,
    #[error("unsupported indexed-session profile")]
    UnsupportedProfile,
    #[error("invalid PairInit session binding")]
    InvalidBinding,
    #[error("same init_id is already bound to a different init hash")]
    InitIdConflict,
    #[error("session binding conflicts with an existing record")]
    BindingConflict,
    #[error("session is already confirmed with a different response")]
    ConfirmationConflict,
    #[error("endpoint session has not completed PairResponse key confirmation")]
    SessionNotConfirmed,
    #[error("ratchet index space exhausted")]
    IndexExhausted,
    #[error("receive index is a replay or no longer retained")]
    Replay,
    #[error("receive index jumps more than 256 messages")]
    ForwardJumpTooLarge,
    #[error("ciphertext authentication failed; receive state was not advanced")]
    AuthenticationFailed,
    #[error("endpoint envelope is malformed")]
    InvalidEndpointEnvelope,
    #[error("endpoint envelope is not a message")]
    EndpointTypeMismatch,
    #[error("endpoint envelope or bound session is not currently valid")]
    EndpointNotCurrentlyValid,
    #[error("endpoint indexed-message header is malformed or unsupported")]
    InvalidIndexedMessage,
    #[error("endpoint destination device hint does not match the selected session")]
    DeviceHintMismatch,
    #[error("endpoint route tag does not match the selected session")]
    RouteTagMismatch,
    #[error("endpoint sender device certificate is invalid")]
    InvalidDeviceCertificate,
    #[error("endpoint sender device is locally revoked")]
    RevokedDevice,
    #[error("endpoint sender device is not the PairInit-bound remote device")]
    DeviceBindingMismatch,
    #[error("endpoint outer device signature verification failed")]
    OuterSignatureInvalid,
    #[error("endpoint text payload violates the bounded application policy")]
    InvalidEndpointPayload,
    #[error("local endpoint device is not currently authorized")]
    LocalDeviceUnauthorized,
    #[error("local endpoint device is not the PairInit-bound device certificate")]
    LocalDeviceBindingMismatch,
    #[error("local endpoint signing operation failed verification")]
    LocalSignerFailure,
    #[error("outbound randomness source failed")]
    EndpointRandomnessUnavailable,
    #[error("an earlier outbound object must be retried before reserving another key")]
    OutboundPending,
    #[error("outbound identifier, nonce, or immutable object collides with durable state")]
    OutboundCollision,
    #[error("durable outbound queue handoff failed or returned the wrong object digest")]
    OutboundQueueHandoff,
    #[error("outbound object does not match its protected journal or committed intent")]
    OutboundBindingMismatch,
    #[error("authenticated sender reused a logical message ID for a different object")]
    LogicalMessageConflict,
    #[error("endpoint inbox/receipt/ACK-intent state is corrupt")]
    CorruptEndpointState,
    #[error("local inbox authentication failed")]
    LocalInboxAuthenticationFailed,
    #[error("immutable ACK bytes conflict with a previously prepared retry")]
    AckBytesConflict,
    #[error("ACK enqueue failed")]
    AckEnqueue,
    #[error("ACK does not match an exact outstanding message and recipient device")]
    AckOutstandingMismatch,
    #[error("ACK inner timestamp does not equal the authenticated outer timestamp")]
    AckTimestampMismatch,
    #[error("ACK inner device signature verification failed")]
    AckInnerSignatureInvalid,
    #[error("authenticated ACK nonce was reused for a different object")]
    AckNonceConflict,
    #[error("PairInit verification failed: {0}")]
    PairInit(#[from] PairInitError),
    #[cfg(test)]
    #[error("test crash after protected write")]
    InjectedCrashAfterProtectedWrite,
    #[cfg(test)]
    #[error("test endpoint failure at {0:?}")]
    InjectedEndpointFailure(&'static str),
}

impl IndexedSessionStoreError {
    /// This intentionally never includes protected bytes, roots, or keys.
    pub fn redacted_display(&self) -> String {
        self.to_string()
    }
}

#[derive(Zeroize, ZeroizeOnDrop)]
pub struct SendKeyReservation {
    #[zeroize(skip)]
    pub session_id: [u8; 32],
    #[zeroize(skip)]
    pub direction: Direction,
    #[zeroize(skip)]
    pub lane: RatchetLane,
    #[zeroize(skip)]
    pub index: u32,
    pub key: [u8; 32],
}

impl fmt::Debug for SendKeyReservation {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SendKeyReservation")
            .field("session_id", &hex::encode(self.session_id))
            .field("direction", &self.direction)
            .field("lane", &self.lane)
            .field("index", &self.index)
            .field("key", &"<redacted>")
            .finish()
    }
}

#[derive(Zeroize, ZeroizeOnDrop)]
struct SendRatchet {
    next_index: u64,
    chain_key: [u8; 32],
}

struct ReceiveRatchet {
    next_index: u64,
    chain_key: [u8; 32],
    skipped_keys: BTreeMap<u32, [u8; 32]>,
}

impl Zeroize for ReceiveRatchet {
    fn zeroize(&mut self) {
        self.next_index.zeroize();
        self.chain_key.zeroize();
        for key in self.skipped_keys.values_mut() {
            key.zeroize();
        }
        self.skipped_keys.clear();
    }
}

impl Drop for ReceiveRatchet {
    fn drop(&mut self) {
        self.zeroize();
    }
}

#[derive(Zeroize, ZeroizeOnDrop)]
struct SecretRatchets {
    root: [u8; 32],
    message_send: SendRatchet,
    ack_send: SendRatchet,
    message_receive: ReceiveRatchet,
    ack_receive: ReceiveRatchet,
}

struct ProtectedSessionState {
    generation: u64,
    binding: IndexedSessionBinding,
    ratchets: SecretRatchets,
    pending_acceptance: Option<PendingAcceptance>,
    pending_ack_acceptance: Option<PendingAckAcceptance>,
    pending_outbound: Option<PendingOutbound>,
}

impl Drop for ProtectedSessionState {
    fn drop(&mut self) {
        self.ratchets.zeroize();
    }
}

/// Recoverable write-ahead record stored only in the platform-protected
/// session blob. `sealed_local_inbox_row` is AEAD ciphertext and this type
/// never contains application plaintext.
struct PendingAcceptance {
    session_id: [u8; 32],
    object_digest: [u8; 32],
    message_id: [u8; 16],
    sender_device: [u8; 32],
    sealed_local_inbox_row: Vec<u8>,
    ack_status: u8,
    created_at_ms: u64,
    received_at_ms: u64,
    public_generation: u64,
}

struct PendingAckAcceptance {
    session_id: [u8; 32],
    object_digest: [u8; 32],
    outer_message_id: [u8; 16],
    remote_device: [u8; 32],
    acked_message_id: [u8; 16],
    status: u8,
    ack_nonce: [u8; 12],
    created_at_ms: u64,
    public_generation: u64,
}

/// Protected write-ahead record for one fully materialized outbound object.
/// The immutable bytes contain only an already-sealed, device-signed RVN1
/// envelope. Message plaintext and the reserved ratchet key are never stored.
struct PendingOutbound {
    kind: EndpointOutboundKind,
    session_id: [u8; 32],
    object_digest: [u8; 32],
    message_id: [u8; 16],
    recipient_device: [u8; 32],
    ratchet_index: u32,
    source_ack_intent: Option<[u8; 32]>,
    ack_nonce: Option<[u8; 12]>,
    seal_nonce: [u8; 12],
    anti_replay_nonce: [u8; 12],
    immutable_envelope_bytes: Vec<u8>,
    public_generation: u64,
}

impl fmt::Debug for PendingOutbound {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PendingOutbound")
            .field("kind", &self.kind)
            .field("identifiers", &"<redacted>")
            .field("ratchet_index", &self.ratchet_index)
            .field("immutable_envelope_bytes", &"<ciphertext>")
            .field("public_generation", &self.public_generation)
            .finish()
    }
}

impl Zeroize for PendingOutbound {
    fn zeroize(&mut self) {
        self.session_id.zeroize();
        self.object_digest.zeroize();
        self.message_id.zeroize();
        self.recipient_device.zeroize();
        self.ratchet_index.zeroize();
        if let Some(value) = self.source_ack_intent.as_mut() {
            value.zeroize();
        }
        if let Some(value) = self.ack_nonce.as_mut() {
            value.zeroize();
        }
        self.seal_nonce.zeroize();
        self.anti_replay_nonce.zeroize();
        self.immutable_envelope_bytes.zeroize();
        self.public_generation.zeroize();
    }
}

impl Drop for PendingOutbound {
    fn drop(&mut self) {
        self.zeroize();
    }
}

impl fmt::Debug for PendingAckAcceptance {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PendingAckAcceptance")
            .field("identifiers", &"<redacted>")
            .field("status", &self.status)
            .field("ack_nonce", &"<redacted>")
            .field("created_at_ms", &self.created_at_ms)
            .field("public_generation", &self.public_generation)
            .finish()
    }
}

impl Zeroize for PendingAckAcceptance {
    fn zeroize(&mut self) {
        self.session_id.zeroize();
        self.object_digest.zeroize();
        self.outer_message_id.zeroize();
        self.remote_device.zeroize();
        self.acked_message_id.zeroize();
        self.status.zeroize();
        self.ack_nonce.zeroize();
        self.created_at_ms.zeroize();
        self.public_generation.zeroize();
    }
}

impl Drop for PendingAckAcceptance {
    fn drop(&mut self) {
        self.zeroize();
    }
}

impl fmt::Debug for PendingAcceptance {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PendingAcceptance")
            .field("identifiers", &"<redacted>")
            .field("sealed_local_inbox_row", &"<sealed>")
            .field("ack_status", &self.ack_status)
            .field("created_at_ms", &self.created_at_ms)
            .field("received_at_ms", &self.received_at_ms)
            .field("public_generation", &self.public_generation)
            .finish()
    }
}

impl Zeroize for PendingAcceptance {
    fn zeroize(&mut self) {
        self.session_id.zeroize();
        self.object_digest.zeroize();
        self.message_id.zeroize();
        self.sender_device.zeroize();
        self.sealed_local_inbox_row.zeroize();
        self.ack_status.zeroize();
        self.created_at_ms.zeroize();
        self.received_at_ms.zeroize();
        self.public_generation.zeroize();
    }
}

impl Drop for PendingAcceptance {
    fn drop(&mut self) {
        self.zeroize();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EndpointFaultPoint {
    BeforeProtectedReplacement,
    AfterProtectedReplacement,
    BeforeDatabaseCommit,
    AfterDatabaseCommit,
    BeforeJournalClear,
    AfterJournalClear,
    #[cfg(test)]
    BeforeAckEnqueue,
    #[cfg(test)]
    AfterAckEnqueue,
    BeforeOutboundQueueHandoff,
    AfterOutboundQueueHandoff,
}

impl EndpointFaultPoint {
    #[cfg(test)]
    fn label(self) -> &'static str {
        match self {
            Self::BeforeProtectedReplacement => "before protected replacement",
            Self::AfterProtectedReplacement => "after protected replacement",
            Self::BeforeDatabaseCommit => "before database commit",
            Self::AfterDatabaseCommit => "after database commit",
            Self::BeforeJournalClear => "before journal clear",
            Self::AfterJournalClear => "after journal clear",
            #[cfg(test)]
            Self::BeforeAckEnqueue => "before ACK enqueue",
            #[cfg(test)]
            Self::AfterAckEnqueue => "after ACK enqueue",
            Self::BeforeOutboundQueueHandoff => "before outbound queue handoff",
            Self::AfterOutboundQueueHandoff => "after outbound queue handoff",
        }
    }
}

fn maybe_injected_endpoint_fault(
    injected: Option<EndpointFaultPoint>,
    point: EndpointFaultPoint,
) -> Result<(), IndexedSessionStoreError> {
    #[cfg(test)]
    if injected == Some(point) {
        return Err(IndexedSessionStoreError::InjectedEndpointFailure(
            point.label(),
        ));
    }
    #[cfg(not(test))]
    let _ = (injected, point);
    Ok(())
}

trait ProtectedSessionBackend: Send + Sync {
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>, IndexedSessionStoreError>;
    fn put(&self, account: &str, value: &[u8]) -> Result<(), IndexedSessionStoreError>;
}

#[cfg(not(any(
    target_os = "macos",
    windows,
    all(target_os = "linux", target_env = "gnu")
)))]
fn unsupported_protected_store_error() -> IndexedSessionStoreError {
    IndexedSessionStoreError::ProtectedStore(PROTECTED_STORE_UNAVAILABLE.into())
}

struct PlatformProtectedSessionBackend {
    #[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
    namespace: String,
    #[cfg(windows)]
    secret_dir: PathBuf,
}

impl PlatformProtectedSessionBackend {
    #[cfg(any(
        target_os = "macos",
        windows,
        all(target_os = "linux", target_env = "gnu")
    ))]
    fn new(data_dir: &Path) -> Result<Self, IndexedSessionStoreError> {
        std::fs::create_dir_all(data_dir)
            .map_err(|error| IndexedSessionStoreError::ProtectedStore(error.to_string()))?;
        #[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
        let namespace = {
            let canonical =
                std::fs::canonicalize(data_dir).unwrap_or_else(|_| data_dir.to_path_buf());
            let mut hasher = Sha256::new();
            hasher.update(b"raven/indexed-session-store/v1/");
            hasher.update(canonical.to_string_lossy().as_bytes());
            hex::encode(hasher.finalize())
        };

        #[cfg(all(target_os = "linux", target_env = "gnu"))]
        {
            use secret_service::{EncryptionType, SecretService};
            let service = SecretService::new(EncryptionType::Dh).map_err(|error| {
                IndexedSessionStoreError::ProtectedStore(format!(
                    "secret-service connection failed: {error}"
                ))
            })?;
            let collection = service.get_default_collection().map_err(|error| {
                IndexedSessionStoreError::ProtectedStore(format!(
                    "secret-service collection failed: {error}"
                ))
            })?;
            if collection.is_locked() {
                collection.unlock().map_err(|error| {
                    IndexedSessionStoreError::ProtectedStore(format!(
                        "secret-service unlock failed: {error}"
                    ))
                })?;
            }
        }

        Ok(Self {
            #[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
            namespace,
            #[cfg(windows)]
            secret_dir: data_dir.join("indexed-session-secrets"),
        })
    }

    #[cfg(not(any(
        target_os = "macos",
        windows,
        all(target_os = "linux", target_env = "gnu")
    )))]
    fn new(_data_dir: &Path) -> Result<Self, IndexedSessionStoreError> {
        Err(unsupported_protected_store_error())
    }

    #[cfg(any(target_os = "macos", all(target_os = "linux", target_env = "gnu")))]
    fn scoped_account(&self, account: &str) -> String {
        format!("{}:{account}", self.namespace)
    }
}

/// Unsupported targets deliberately have a backend implementation so the
/// platform constructor remains type-correct when coerced to the backend trait
/// object. Every operation fails closed; this is not a file-backed fallback.
#[cfg(not(any(
    target_os = "macos",
    windows,
    all(target_os = "linux", target_env = "gnu")
)))]
impl ProtectedSessionBackend for PlatformProtectedSessionBackend {
    fn get(&self, _account: &str) -> Result<Option<Vec<u8>>, IndexedSessionStoreError> {
        Err(unsupported_protected_store_error())
    }

    fn put(&self, _account: &str, _value: &[u8]) -> Result<(), IndexedSessionStoreError> {
        Err(unsupported_protected_store_error())
    }
}

#[cfg(target_os = "macos")]
impl ProtectedSessionBackend for PlatformProtectedSessionBackend {
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>, IndexedSessionStoreError> {
        use security_framework::passwords::get_generic_password;
        match get_generic_password(PLATFORM_SERVICE, &self.scoped_account(account)) {
            Ok(value) => Ok(Some(value)),
            Err(error) if error.code() == -25_300 => Ok(None),
            Err(error) => Err(IndexedSessionStoreError::ProtectedStore(format!(
                "keychain read failed: {error}"
            ))),
        }
    }

    fn put(&self, account: &str, value: &[u8]) -> Result<(), IndexedSessionStoreError> {
        use security_framework::passwords::set_generic_password;
        set_generic_password(PLATFORM_SERVICE, &self.scoped_account(account), value).map_err(
            |error| {
                IndexedSessionStoreError::ProtectedStore(format!("keychain update failed: {error}"))
            },
        )
    }
}

#[cfg(all(target_os = "linux", target_env = "gnu"))]
impl ProtectedSessionBackend for PlatformProtectedSessionBackend {
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>, IndexedSessionStoreError> {
        use secret_service::{EncryptionType, SecretService};
        let service = SecretService::new(EncryptionType::Dh).map_err(|error| {
            IndexedSessionStoreError::ProtectedStore(format!(
                "secret-service connection failed: {error}"
            ))
        })?;
        let collection = service.get_default_collection().map_err(|error| {
            IndexedSessionStoreError::ProtectedStore(format!(
                "secret-service collection failed: {error}"
            ))
        })?;
        if collection.is_locked() {
            collection.unlock().map_err(|error| {
                IndexedSessionStoreError::ProtectedStore(format!(
                    "secret-service unlock failed: {error}"
                ))
            })?;
        }
        let scoped = self.scoped_account(account);
        let items = collection
            .search_items(vec![
                ("service", PLATFORM_SERVICE),
                ("account", scoped.as_str()),
            ])
            .map_err(|error| {
                IndexedSessionStoreError::ProtectedStore(format!(
                    "secret-service search failed: {error}"
                ))
            })?;
        let Some(item) = items.into_iter().next() else {
            return Ok(None);
        };
        item.get_secret().map(Some).map_err(|error| {
            IndexedSessionStoreError::ProtectedStore(format!("secret-service read failed: {error}"))
        })
    }

    fn put(&self, account: &str, value: &[u8]) -> Result<(), IndexedSessionStoreError> {
        use secret_service::{EncryptionType, SecretService};
        let service = SecretService::new(EncryptionType::Dh).map_err(|error| {
            IndexedSessionStoreError::ProtectedStore(format!(
                "secret-service connection failed: {error}"
            ))
        })?;
        let collection = service.get_default_collection().map_err(|error| {
            IndexedSessionStoreError::ProtectedStore(format!(
                "secret-service collection failed: {error}"
            ))
        })?;
        if collection.is_locked() {
            collection.unlock().map_err(|error| {
                IndexedSessionStoreError::ProtectedStore(format!(
                    "secret-service unlock failed: {error}"
                ))
            })?;
        }
        let scoped = self.scoped_account(account);
        collection
            .create_item(
                "RAVEN ATSAM indexed session state",
                vec![("service", PLATFORM_SERVICE), ("account", scoped.as_str())],
                value,
                true,
                "application/octet-stream",
            )
            .map_err(|error| {
                IndexedSessionStoreError::ProtectedStore(format!(
                    "secret-service update failed: {error}"
                ))
            })?;
        Ok(())
    }
}

#[cfg(windows)]
impl ProtectedSessionBackend for PlatformProtectedSessionBackend {
    fn get(&self, account: &str) -> Result<Option<Vec<u8>>, IndexedSessionStoreError> {
        let path = self.secret_dir.join(format!("{account}.dpapi"));
        if !path.exists() {
            return Ok(None);
        }
        let mut protected = std::fs::read(path)
            .map_err(|error| IndexedSessionStoreError::ProtectedStore(error.to_string()))?;
        let result = dpapi_unprotect(&protected);
        protected.zeroize();
        result.map(Some)
    }

    fn put(&self, account: &str, value: &[u8]) -> Result<(), IndexedSessionStoreError> {
        use std::io::Write;
        std::fs::create_dir_all(&self.secret_dir)
            .map_err(|error| IndexedSessionStoreError::ProtectedStore(error.to_string()))?;
        let target = self.secret_dir.join(format!("{account}.dpapi"));
        let temp = self
            .secret_dir
            .join(format!(".{account}.{:016x}.tmp", rand::random::<u64>()));
        let mut protected = dpapi_protect(value)?;
        let result = (|| {
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temp)
                .map_err(|error| IndexedSessionStoreError::ProtectedStore(error.to_string()))?;
            file.write_all(&protected)
                .and_then(|_| file.sync_all())
                .map_err(|error| IndexedSessionStoreError::ProtectedStore(error.to_string()))?;
            replace_file_windows(&temp, &target)
        })();
        protected.zeroize();
        if result.is_err() {
            let _ = std::fs::remove_file(&temp);
        }
        result
    }
}

#[cfg(windows)]
fn dpapi_protect(value: &[u8]) -> Result<Vec<u8>, IndexedSessionStoreError> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptProtectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };
    let mut input = CRYPT_INTEGER_BLOB {
        cbData: value
            .len()
            .try_into()
            .map_err(|_| IndexedSessionStoreError::ProtectedStore("state too large".into()))?,
        pbData: value.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptProtectData(
            &mut input,
            std::ptr::null(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if ok == 0 || output.pbData.is_null() {
        return Err(IndexedSessionStoreError::ProtectedStore(
            "CryptProtectData failed".into(),
        ));
    }
    let bytes = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) };
    let result = bytes.to_vec();
    unsafe {
        LocalFree(output.pbData as _);
    }
    Ok(result)
}

#[cfg(windows)]
fn dpapi_unprotect(value: &[u8]) -> Result<Vec<u8>, IndexedSessionStoreError> {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
    };
    let mut input = CRYPT_INTEGER_BLOB {
        cbData: value
            .len()
            .try_into()
            .map_err(|_| IndexedSessionStoreError::CorruptProtectedState)?,
        pbData: value.as_ptr() as *mut u8,
    };
    let mut output = CRYPT_INTEGER_BLOB {
        cbData: 0,
        pbData: std::ptr::null_mut(),
    };
    let ok = unsafe {
        CryptUnprotectData(
            &mut input,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut output,
        )
    };
    if ok == 0 || output.pbData.is_null() {
        return Err(IndexedSessionStoreError::ProtectedStore(
            "CryptUnprotectData failed".into(),
        ));
    }
    let bytes = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) };
    let result = bytes.to_vec();
    unsafe {
        LocalFree(output.pbData as _);
    }
    Ok(result)
}

#[cfg(windows)]
fn replace_file_windows(temp: &Path, target: &Path) -> Result<(), IndexedSessionStoreError> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };
    let mut from: Vec<u16> = temp.as_os_str().encode_wide().collect();
    from.push(0);
    let mut to: Vec<u16> = target.as_os_str().encode_wide().collect();
    to.push(0);
    let ok = unsafe {
        MoveFileExW(
            from.as_ptr(),
            to.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if ok == 0 {
        return Err(IndexedSessionStoreError::ProtectedStore(
            "atomic DPAPI state replacement failed".into(),
        ));
    }
    Ok(())
}

pub struct IndexedSessionStore {
    conn: Connection,
    backend: Arc<dyn ProtectedSessionBackend>,
    #[cfg(test)]
    crash_after_protected_write: bool,
    #[cfg(test)]
    endpoint_fault: Cell<Option<EndpointFaultPoint>>,
}

impl IndexedSessionStore {
    /// Opens the platform implementation. GNU/Linux requires Secret Service;
    /// unsupported platforms fail closed. There is no plaintext file fallback.
    pub fn open(data_dir: &Path) -> Result<Self, IndexedSessionStoreError> {
        let backend = Arc::new(PlatformProtectedSessionBackend::new(data_dir)?);
        Self::open_with_backend(&data_dir.join(INDEXED_SESSION_METADATA_FILE), backend)
    }

    fn open_with_backend(
        metadata_path: &Path,
        backend: Arc<dyn ProtectedSessionBackend>,
    ) -> Result<Self, IndexedSessionStoreError> {
        if let Some(parent) = metadata_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| IndexedSessionStoreError::ProtectedStore(error.to_string()))?;
        }
        let conn = Connection::open(metadata_path)?;
        conn.busy_timeout(Duration::from_secs(10))?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             PRAGMA foreign_keys=ON;
             CREATE TABLE IF NOT EXISTS indexed_session_heads (
               record_key BLOB PRIMARY KEY NOT NULL CHECK(length(record_key) = 32),
               binding_digest BLOB NOT NULL CHECK(length(binding_digest) = 32),
               profile_id BLOB NOT NULL,
               initiator_address TEXT NOT NULL,
               responder_address TEXT NOT NULL,
               initiator_device BLOB NOT NULL CHECK(length(initiator_device) = 32),
               responder_device BLOB NOT NULL CHECK(length(responder_device) = 32),
               init_id BLOB NOT NULL CHECK(length(init_id) = 16),
               init_hash BLOB NOT NULL CHECK(length(init_hash) = 32),
               session_id BLOB NOT NULL UNIQUE CHECK(length(session_id) = 32),
               generation INTEGER NOT NULL CHECK(generation >= 0),
               created_at_ms INTEGER NOT NULL,
               expires_at_ms INTEGER NOT NULL,
               UNIQUE(profile_id, initiator_address, responder_address,
                      initiator_device, responder_device, init_id)
             );
             CREATE UNIQUE INDEX IF NOT EXISTS indexed_session_init_id_unique
             ON indexed_session_heads(init_id);
             CREATE TABLE IF NOT EXISTS endpoint_receipts (
               session_id BLOB NOT NULL CHECK(length(session_id) = 32),
               object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
               message_id BLOB NOT NULL CHECK(length(message_id) = 16),
               sender_device BLOB NOT NULL CHECK(length(sender_device) = 32),
               session_generation INTEGER NOT NULL CHECK(session_generation >= 0),
               PRIMARY KEY(session_id, object_digest),
               UNIQUE(session_id, sender_device, message_id),
               FOREIGN KEY(session_id) REFERENCES indexed_session_heads(session_id)
             );
             CREATE TABLE IF NOT EXISTS endpoint_inbox (
               session_id BLOB NOT NULL CHECK(length(session_id) = 32),
               object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
               message_id BLOB NOT NULL CHECK(length(message_id) = 16),
               sender_device BLOB NOT NULL CHECK(length(sender_device) = 32),
               created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
               received_at_ms INTEGER NOT NULL CHECK(received_at_ms >= 0),
               sealed_local_row BLOB NOT NULL,
               PRIMARY KEY(session_id, object_digest),
               FOREIGN KEY(session_id, object_digest)
                 REFERENCES endpoint_receipts(session_id, object_digest)
             );
             CREATE TABLE IF NOT EXISTS endpoint_ack_intents (
               session_id BLOB NOT NULL CHECK(length(session_id) = 32),
               object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
               message_id BLOB NOT NULL CHECK(length(message_id) = 16),
               remote_device BLOB NOT NULL CHECK(length(remote_device) = 32),
               status INTEGER NOT NULL CHECK(status IN (1, 2)),
               state INTEGER NOT NULL CHECK(state IN (0, 1)),
               immutable_ack_bytes BLOB,
               PRIMARY KEY(session_id, object_digest),
               FOREIGN KEY(session_id, object_digest)
                 REFERENCES endpoint_receipts(session_id, object_digest)
             );
             CREATE TABLE IF NOT EXISTS endpoint_outstanding_messages (
               session_id BLOB NOT NULL CHECK(length(session_id) = 32),
               message_id BLOB NOT NULL CHECK(length(message_id) = 16),
               recipient_device BLOB NOT NULL CHECK(length(recipient_device) = 32),
               delivery_state INTEGER NOT NULL CHECK(delivery_state IN (0, 1, 2)),
               PRIMARY KEY(session_id, message_id, recipient_device),
               FOREIGN KEY(session_id) REFERENCES indexed_session_heads(session_id)
             );
             CREATE TABLE IF NOT EXISTS endpoint_ack_receipts (
               session_id BLOB NOT NULL CHECK(length(session_id) = 32),
               object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
               outer_message_id BLOB NOT NULL CHECK(length(outer_message_id) = 16),
               remote_device BLOB NOT NULL CHECK(length(remote_device) = 32),
               acked_message_id BLOB NOT NULL CHECK(length(acked_message_id) = 16),
               status INTEGER NOT NULL CHECK(status IN (1, 2)),
               ack_nonce BLOB NOT NULL CHECK(length(ack_nonce) = 12),
               created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
               session_generation INTEGER NOT NULL CHECK(session_generation >= 0),
               PRIMARY KEY(session_id, object_digest),
               UNIQUE(session_id, remote_device, outer_message_id),
               UNIQUE(session_id, remote_device, ack_nonce),
               FOREIGN KEY(session_id) REFERENCES indexed_session_heads(session_id)
             );
             CREATE TABLE IF NOT EXISTS endpoint_outbox (
               session_id BLOB NOT NULL CHECK(length(session_id) = 32),
               object_digest BLOB NOT NULL CHECK(length(object_digest) = 32),
               kind INTEGER NOT NULL CHECK(kind IN (1, 2)),
               message_id BLOB NOT NULL CHECK(length(message_id) = 16),
               recipient_device BLOB NOT NULL CHECK(length(recipient_device) = 32),
               ratchet_index INTEGER NOT NULL CHECK(ratchet_index >= 0),
               source_ack_intent BLOB CHECK(source_ack_intent IS NULL OR length(source_ack_intent) = 32),
               ack_nonce BLOB CHECK(ack_nonce IS NULL OR length(ack_nonce) = 12),
               seal_nonce BLOB NOT NULL CHECK(length(seal_nonce) = 12),
               anti_replay_nonce BLOB NOT NULL CHECK(length(anti_replay_nonce) = 12),
               immutable_envelope_bytes BLOB NOT NULL
                 CHECK(length(immutable_envelope_bytes) >= 86
                   AND length(immutable_envelope_bytes) <= 262656),
               state INTEGER NOT NULL CHECK(state IN (0, 1)),
               session_generation INTEGER NOT NULL CHECK(session_generation >= 0),
               PRIMARY KEY(session_id, object_digest),
               UNIQUE(session_id, message_id),
               UNIQUE(session_id, seal_nonce),
               UNIQUE(session_id, anti_replay_nonce),
               UNIQUE(session_id, ack_nonce),
               UNIQUE(session_id, source_ack_intent),
               CHECK((kind = 1 AND source_ack_intent IS NULL AND ack_nonce IS NULL)
                  OR (kind = 2 AND source_ack_intent IS NOT NULL AND ack_nonce IS NOT NULL)),
               FOREIGN KEY(session_id) REFERENCES indexed_session_heads(session_id)
             );",
        )?;
        let mut store = Self {
            conn,
            backend,
            #[cfg(test)]
            crash_after_protected_write: false,
            #[cfg(test)]
            endpoint_fault: Cell::new(None),
        };
        store.recover_all_pending_acceptances()?;
        Ok(store)
    }

    /// Test-only raw fixture creation. Shipping callers must enter through
    /// `create_verified_pair_init_session`; accepting an arbitrary binding and
    /// root would bypass PairInit trust verification.
    #[cfg(test)]
    fn create_session(
        &mut self,
        binding: IndexedSessionBinding,
        root: [u8; 32],
    ) -> Result<(), IndexedSessionStoreError> {
        self.create_trusted_session(binding, root)
    }

    fn create_trusted_session(
        &mut self,
        binding: IndexedSessionBinding,
        mut root: [u8; 32],
    ) -> Result<(), IndexedSessionStoreError> {
        let result = self.create_session_inner(binding, &root);
        root.zeroize();
        result
    }

    /// Verifies the signed PairInit and its exact trust records, derives all
    /// public record identifiers through the frozen PairInit module, and then
    /// persists the supplied already-derived provisional root. Networking is
    /// still deliberately not wired to this API.
    pub fn create_verified_pair_init_session(
        &mut self,
        init: &PairInit,
        trust: &PairInitTrust<'_>,
        now_ms: u64,
        local_role: LocalRole,
        root: [u8; 32],
    ) -> Result<IndexedSessionRecordKey, IndexedSessionStoreError> {
        verify_init(init, trust, now_ms)?;
        let key = IndexedSessionRecordKey {
            profile_id: PROFILE_ID.to_vec(),
            initiator_address: init.initiator_address.clone(),
            responder_address: init.responder_address.clone(),
            initiator_device_ed25519: init.initiator_device_ed_pub,
            responder_device_ed25519: init.responder_device_ed_pub,
            init_id: init.init_id,
        };
        let binding = IndexedSessionBinding {
            key: key.clone(),
            session_id: pair_session_id(init)?,
            init_hash: pair_init_hash(init)?,
            transcript_hash: pair_transcript_hash(init)?,
            initiator_cert_digest: init.initiator_device_cert_hash,
            responder_cert_digest: init.responder_device_cert_hash,
            responder_prekey_bundle_digest: init.responder_prekey_bundle_hash,
            signed_prekey_id: init.signed_prekey_id,
            one_time_prekey_id: init.one_time_prekey_id,
            created_at_ms: init.created_at_ms,
            expires_at_ms: init.expires_at_ms,
            local_role,
            lifecycle: SessionLifecycle::Provisional,
            response_hash: None,
        };
        self.create_trusted_session(binding, root)?;
        Ok(key)
    }

    fn create_session_inner(
        &mut self,
        binding: IndexedSessionBinding,
        root: &[u8; 32],
    ) -> Result<(), IndexedSessionStoreError> {
        binding.validate()?;
        let record_key = record_key_digest(&binding.key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let metadata = metadata_head(&tx, &record_key)?;
        let mut protected = backend.get(&account)?;

        if let Some(bytes) = protected.as_mut() {
            let state_result = decode_protected_state(bytes);
            bytes.zeroize();
            let state = state_result?;
            ensure_record_key(&state.binding, &record_key)?;
            if state.binding.key.init_id == binding.key.init_id
                && state.binding.init_hash != binding.init_hash
            {
                return Err(IndexedSessionStoreError::InitIdConflict);
            }
            if !same_initial_binding(&state.binding, &binding) || state.ratchets.root != *root {
                return Err(IndexedSessionStoreError::BindingConflict);
            }
            reconcile_metadata(&tx, metadata, &record_key, &state)?;
            tx.commit()?;
            return Ok(());
        }

        if metadata.is_some() {
            return Err(IndexedSessionStoreError::ProtectedStateMissing);
        }
        if let Some(owner) = metadata_init_owner(&tx, &binding.key.init_id)? {
            if owner.init_hash != binding.init_hash {
                return Err(IndexedSessionStoreError::InitIdConflict);
            }
            if owner.record_key != record_key {
                return Err(IndexedSessionStoreError::BindingConflict);
            }
        }
        if metadata_session_owner(&tx, &binding.session_id)?.is_some() {
            return Err(IndexedSessionStoreError::BindingConflict);
        }

        let state = ProtectedSessionState {
            generation: 0,
            ratchets: initial_ratchets(&binding, root),
            binding,
            pending_acceptance: None,
            pending_ack_acceptance: None,
            pending_outbound: None,
        };
        let mut encoded = encode_protected_state(&state)?;
        let put_result = backend.put(&account, &encoded);
        encoded.zeroize();
        put_result?;
        #[cfg(test)]
        if self.crash_after_protected_write {
            return Err(IndexedSessionStoreError::InjectedCrashAfterProtectedWrite);
        }
        insert_metadata(&tx, &record_key, &state)?;
        tx.commit()?;
        Ok(())
    }

    #[cfg(test)]
    fn reserve_send_key(
        &mut self,
        key: &IndexedSessionRecordKey,
        lane: RatchetLane,
    ) -> Result<SendKeyReservation, IndexedSessionStoreError> {
        self.recover_pending_for_key(key)?;
        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        if &state.binding.key != key {
            return Err(IndexedSessionStoreError::BindingConflict);
        }
        let direction = state.binding.local_role.outbound_direction();
        let (sender, recipient) = endpoints_for_direction(&state.binding, direction);
        let ratchet = match lane {
            RatchetLane::Message => &mut state.ratchets.message_send,
            RatchetLane::Ack => &mut state.ratchets.ack_send,
        };
        if ratchet.next_index > u32::MAX as u64 {
            return Err(IndexedSessionStoreError::IndexExhausted);
        }
        let index = ratchet.next_index as u32;
        let mut reserved_key = message_key(&ratchet.chain_key, sender, recipient);
        ratchet.chain_key = advance_chain_key(&ratchet.chain_key);
        ratchet.next_index += 1;
        state.generation = state
            .generation
            .checked_add(1)
            .ok_or(IndexedSessionStoreError::IndexExhausted)?;
        let result = write_mutation(
            &tx,
            backend.as_ref(),
            &account,
            &record_key,
            &state,
            #[cfg(test)]
            self.crash_after_protected_write,
        );
        if let Err(error) = result {
            reserved_key.zeroize();
            return Err(error);
        }
        tx.commit()?;
        Ok(SendKeyReservation {
            session_id: state.binding.session_id,
            direction,
            lane,
            index,
            key: reserved_key,
        })
    }

    /// Supplies a candidate receive key to `authenticate` while holding the
    /// cross-process mutation lock. State advances only when the callback
    /// returns `Some`, then the protected head is durable before the value is
    /// returned. This does not make a caller's inbox write atomic with this
    /// commit.
    #[cfg(test)]
    fn authenticate_receive<T, F>(
        &mut self,
        key: &IndexedSessionRecordKey,
        lane: RatchetLane,
        index: u32,
        authenticate: F,
    ) -> Result<T, IndexedSessionStoreError>
    where
        F: FnOnce(&[u8; 32]) -> Option<T>,
    {
        self.recover_pending_for_key(key)?;
        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        if &state.binding.key != key {
            return Err(IndexedSessionStoreError::BindingConflict);
        }
        let direction = state.binding.local_role.inbound_direction();
        let (sender, recipient) = endpoints_for_direction(&state.binding, direction);
        let ratchet = match lane {
            RatchetLane::Message => &mut state.ratchets.message_receive,
            RatchetLane::Ack => &mut state.ratchets.ack_receive,
        };
        let mut candidate = prepare_receive_key(ratchet, index, sender, recipient)?;
        let Some(value) = authenticate(&candidate) else {
            candidate.zeroize();
            return Err(IndexedSessionStoreError::AuthenticationFailed);
        };
        candidate.zeroize();
        state.generation = state
            .generation
            .checked_add(1)
            .ok_or(IndexedSessionStoreError::IndexExhausted)?;
        write_mutation(
            &tx,
            backend.as_ref(),
            &account,
            &record_key,
            &state,
            #[cfg(test)]
            self.crash_after_protected_write,
        )?;
        tx.commit()?;
        Ok(value)
    }

    /// Seals, journals, commits, and durably hands off one text message. The
    /// API fixes all envelope policy fields and generates every identifier and
    /// nonce from the supplied cryptographic RNG. A failed queue handoff leaves
    /// one prepared outbox row; callers must use `retry_endpoint_outbound`
    /// rather than reserve a second ratchet key.
    #[allow(clippy::too_many_arguments)]
    pub fn send_message_envelope<R, F>(
        &mut self,
        key: &IndexedSessionRecordKey,
        text: &str,
        local_device: &AuthorizedEndpointDevice<'_>,
        created_at_ms: u64,
        expires_at_ms: u64,
        now_ms: u64,
        rng: &mut R,
        enqueue_idempotently: &mut F,
    ) -> Result<EndpointOutbound, IndexedSessionStoreError>
    where
        R: RngCore + CryptoRng,
        F: FnMut(&[u8; 32], &[u8]) -> Result<[u8; 32], ()>,
    {
        if !valid_endpoint_text(text.as_bytes()) {
            return Err(IndexedSessionStoreError::InvalidEndpointPayload);
        }
        if !endpoint_time_window_valid(created_at_ms, expires_at_ms, now_ms)
            || created_at_ms > i64::MAX as u64
            || expires_at_ms > i64::MAX as u64
            || now_ms > i64::MAX as u64
        {
            return Err(IndexedSessionStoreError::EndpointNotCurrentlyValid);
        }
        self.recover_pending_for_key(key)?;
        #[cfg(test)]
        let endpoint_fault = self.endpoint_fault.take();
        #[cfg(not(test))]
        let endpoint_fault = None;

        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        let authorization_index = u32::try_from(state.ratchets.message_send.next_index)
            .map_err(|_| IndexedSessionStoreError::IndexExhausted)?;
        validate_outbound_session_and_signer(
            &state,
            key,
            local_device,
            EndpointOutboundKind::Message,
            authorization_index,
            created_at_ms,
            expires_at_ms,
            now_ms,
        )?;
        ensure_no_pending_protected_mutation(&state)?;
        if prepared_outbound_exists(&tx, &state.binding.session_id)? {
            return Err(IndexedSessionStoreError::OutboundPending);
        }

        let message_id = random_nonzero::<16, _>(rng)?;
        let seal_nonce = random_nonzero::<12, _>(rng)?;
        let anti_replay_nonce = random_nonzero::<12, _>(rng)?;
        ensure_fresh_outbound_coordinates(
            &tx,
            &state.binding.session_id,
            &message_id,
            &seal_nonce,
            &anti_replay_nonce,
            None,
        )?;

        let direction = state.binding.local_role.outbound_direction();
        let (sender, recipient) = endpoints_for_direction(&state.binding, direction);
        let ratchet = &mut state.ratchets.message_send;
        if ratchet.next_index > u32::MAX as u64 {
            return Err(IndexedSessionStoreError::IndexExhausted);
        }
        let index = ratchet.next_index as u32;
        let mut reserved_key = message_key(&ratchet.chain_key, sender, recipient);
        ratchet.chain_key = advance_chain_key(&ratchet.chain_key);
        ratchet.next_index += 1;
        let sealed_result = seal_indexed_message_with_key(
            &reserved_key,
            &state.binding.key.initiator_address,
            &state.binding.key.responder_address,
            direction,
            index,
            &message_id,
            text.as_bytes(),
            &seal_nonce,
        );
        reserved_key.zeroize();
        let sealed =
            sealed_result.map_err(|_| IndexedSessionStoreError::OutboundBindingMismatch)?;
        let mut envelope = outbound_envelope(
            &state,
            EnvType::Message,
            index,
            message_id,
            anti_replay_nonce,
            created_at_ms,
            expires_at_ms,
            sealed,
        )?;
        sign_outbound_envelope(&mut envelope, local_device)?;
        let immutable_envelope_bytes = envelope.pack();
        validate_materialized_outbound(&envelope, &immutable_envelope_bytes)?;
        let object_digest = authenticated_object_digest(&envelope);
        if endpoint_outbound_by_object(&tx, &state.binding.session_id, &object_digest)?.is_some() {
            return Err(IndexedSessionStoreError::OutboundCollision);
        }

        state.generation = state
            .generation
            .checked_add(1)
            .ok_or(IndexedSessionStoreError::IndexExhausted)?;
        state.pending_outbound = Some(PendingOutbound {
            kind: EndpointOutboundKind::Message,
            session_id: state.binding.session_id,
            object_digest,
            message_id,
            recipient_device: *remote_device_for_binding(&state.binding),
            ratchet_index: index,
            source_ack_intent: None,
            ack_nonce: None,
            seal_nonce,
            anti_replay_nonce,
            immutable_envelope_bytes,
            public_generation: state.generation,
        });

        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::BeforeProtectedReplacement,
        )?;
        write_mutation(
            &tx,
            backend.as_ref(),
            &account,
            &record_key,
            &state,
            #[cfg(test)]
            false,
        )?;
        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::AfterProtectedReplacement,
        )?;
        insert_pending_outbound(
            &tx,
            &state,
            state
                .pending_outbound
                .as_ref()
                .ok_or(IndexedSessionStoreError::CorruptProtectedState)?,
        )?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::BeforeDatabaseCommit)?;
        tx.commit()?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::AfterDatabaseCommit)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::BeforeJournalClear)?;
        state.pending_outbound = None;
        put_protected_state(backend.as_ref(), &account, &state)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::AfterJournalClear)?;
        self.handoff_endpoint_outbound(
            &state,
            &object_digest,
            local_device,
            now_ms,
            endpoint_fault,
            enqueue_idempotently,
        )
    }

    /// Materializes an ACK only from the exact committed inbox intent selected
    /// by `intent_object_digest`. The caller cannot supply an acknowledged ID,
    /// remote device, or status.
    #[allow(clippy::too_many_arguments)]
    pub fn enqueue_committed_ack<R, F>(
        &mut self,
        key: &IndexedSessionRecordKey,
        intent_object_digest: &[u8; 32],
        local_device: &AuthorizedEndpointDevice<'_>,
        created_at_ms: u64,
        expires_at_ms: u64,
        now_ms: u64,
        rng: &mut R,
        enqueue_idempotently: &mut F,
    ) -> Result<EndpointOutbound, IndexedSessionStoreError>
    where
        R: RngCore + CryptoRng,
        F: FnMut(&[u8; 32], &[u8]) -> Result<[u8; 32], ()>,
    {
        if !endpoint_time_window_valid(created_at_ms, expires_at_ms, now_ms)
            || created_at_ms > i64::MAX as u64
            || expires_at_ms > i64::MAX as u64
            || now_ms > i64::MAX as u64
        {
            return Err(IndexedSessionStoreError::EndpointNotCurrentlyValid);
        }
        self.recover_pending_for_key(key)?;
        #[cfg(test)]
        let endpoint_fault = self.endpoint_fault.take();
        #[cfg(not(test))]
        let endpoint_fault = None;

        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        let authorization_index = u32::try_from(state.ratchets.ack_send.next_index)
            .map_err(|_| IndexedSessionStoreError::IndexExhausted)?;
        validate_outbound_session_and_signer(
            &state,
            key,
            local_device,
            EndpointOutboundKind::Ack,
            authorization_index,
            created_at_ms,
            expires_at_ms,
            now_ms,
        )?;
        ensure_no_pending_protected_mutation(&state)?;

        let intent = committed_ack_intent(&tx, &state.binding.session_id, intent_object_digest)?;
        let receipt =
            endpoint_receipt_by_object(&tx, &state.binding.session_id, intent_object_digest)?
                .ok_or(IndexedSessionStoreError::CorruptEndpointState)?;
        if intent.remote_device != *remote_device_for_binding(&state.binding)
            || receipt.0 != intent.message_id
            || receipt.1 != intent.remote_device
        {
            return Err(IndexedSessionStoreError::OutboundBindingMismatch);
        }
        if intent.state == EndpointAckIntentState::Queued {
            let existing =
                outbound_by_ack_intent(&tx, &state.binding.session_id, intent_object_digest)?
                    .ok_or(IndexedSessionStoreError::CorruptEndpointState)?;
            validate_committed_outbound(&tx, &state, &existing)?;
            tx.commit()?;
            return Ok(existing);
        }
        if let Some(existing) =
            outbound_by_ack_intent(&tx, &state.binding.session_id, intent_object_digest)?
        {
            if intent.immutable_ack_bytes.as_deref()
                != Some(existing.immutable_envelope_bytes.as_slice())
            {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
            let object_digest = existing.object_digest;
            tx.commit()?;
            return self.handoff_endpoint_outbound(
                &state,
                &object_digest,
                local_device,
                now_ms,
                endpoint_fault,
                enqueue_idempotently,
            );
        }
        if intent.immutable_ack_bytes.is_some() {
            return Err(IndexedSessionStoreError::OutboundBindingMismatch);
        }
        if prepared_outbound_exists(&tx, &state.binding.session_id)? {
            return Err(IndexedSessionStoreError::OutboundPending);
        }

        let message_id = random_nonzero::<16, _>(rng)?;
        let seal_nonce = random_nonzero::<12, _>(rng)?;
        let anti_replay_nonce = random_nonzero::<12, _>(rng)?;
        let ack_nonce = random_nonzero::<12, _>(rng)?;
        ensure_fresh_outbound_coordinates(
            &tx,
            &state.binding.session_id,
            &message_id,
            &seal_nonce,
            &anti_replay_nonce,
            Some(&ack_nonce),
        )?;

        let direction = state.binding.local_role.outbound_direction();
        let (sender, recipient) = endpoints_for_direction(&state.binding, direction);
        let ratchet = &mut state.ratchets.ack_send;
        if ratchet.next_index > u32::MAX as u64 {
            return Err(IndexedSessionStoreError::IndexExhausted);
        }
        let index = ratchet.next_index as u32;
        let mut reserved_key = message_key(&ratchet.chain_key, sender, recipient);
        ratchet.chain_key = advance_chain_key(&ratchet.chain_key);
        ratchet.next_index += 1;

        let ack_record = Ack {
            acked_message_id: intent.message_id,
            status: intent.status,
            ack_nonce,
            created_at: created_at_ms,
        };
        let signed_ack = SignedAck {
            signature: local_device.sign_verified(&ack_record.signing_bytes())?,
            record: ack_record,
        };
        let mut ack_plaintext = encode_signed_ack(&signed_ack)
            .map_err(|_| IndexedSessionStoreError::OutboundBindingMismatch)?;
        let sealed_result = seal_indexed_message_with_key(
            &reserved_key,
            &state.binding.key.initiator_address,
            &state.binding.key.responder_address,
            direction,
            index,
            &message_id,
            &ack_plaintext,
            &seal_nonce,
        );
        reserved_key.zeroize();
        ack_plaintext.zeroize();
        let sealed =
            sealed_result.map_err(|_| IndexedSessionStoreError::OutboundBindingMismatch)?;
        let mut envelope = outbound_envelope(
            &state,
            EnvType::Ack,
            index,
            message_id,
            anti_replay_nonce,
            created_at_ms,
            expires_at_ms,
            sealed,
        )?;
        sign_outbound_envelope(&mut envelope, local_device)?;
        let immutable_envelope_bytes = envelope.pack();
        validate_materialized_outbound(&envelope, &immutable_envelope_bytes)?;
        let object_digest = authenticated_object_digest(&envelope);
        if endpoint_outbound_by_object(&tx, &state.binding.session_id, &object_digest)?.is_some() {
            return Err(IndexedSessionStoreError::OutboundCollision);
        }

        state.generation = state
            .generation
            .checked_add(1)
            .ok_or(IndexedSessionStoreError::IndexExhausted)?;
        state.pending_outbound = Some(PendingOutbound {
            kind: EndpointOutboundKind::Ack,
            session_id: state.binding.session_id,
            object_digest,
            message_id,
            recipient_device: intent.remote_device,
            ratchet_index: index,
            source_ack_intent: Some(*intent_object_digest),
            ack_nonce: Some(ack_nonce),
            seal_nonce,
            anti_replay_nonce,
            immutable_envelope_bytes,
            public_generation: state.generation,
        });

        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::BeforeProtectedReplacement,
        )?;
        write_mutation(
            &tx,
            backend.as_ref(),
            &account,
            &record_key,
            &state,
            #[cfg(test)]
            false,
        )?;
        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::AfterProtectedReplacement,
        )?;
        insert_pending_outbound(
            &tx,
            &state,
            state
                .pending_outbound
                .as_ref()
                .ok_or(IndexedSessionStoreError::CorruptProtectedState)?,
        )?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::BeforeDatabaseCommit)?;
        tx.commit()?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::AfterDatabaseCommit)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::BeforeJournalClear)?;
        state.pending_outbound = None;
        put_protected_state(backend.as_ref(), &account, &state)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::AfterJournalClear)?;
        self.handoff_endpoint_outbound(
            &state,
            &object_digest,
            local_device,
            now_ms,
            endpoint_fault,
            enqueue_idempotently,
        )
    }

    /// Retries an already prepared immutable object without reserving a key or
    /// invoking a signing operation/RNG. Current authorization of the exact
    /// PairInit-bound local device is still required. The queue callback must
    /// return the exact digest it durably persisted.
    pub fn retry_endpoint_outbound<F>(
        &mut self,
        key: &IndexedSessionRecordKey,
        object_digest: &[u8; 32],
        local_device: &AuthorizedEndpointDevice<'_>,
        now_ms: u64,
        enqueue_idempotently: &mut F,
    ) -> Result<EndpointOutbound, IndexedSessionStoreError>
    where
        F: FnMut(&[u8; 32], &[u8]) -> Result<[u8; 32], ()>,
    {
        self.recover_pending_for_key(key)?;
        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let state = load_and_reconcile(&tx, self.backend.as_ref(), &account, &record_key)?;
        if &state.binding.key != key {
            return Err(IndexedSessionStoreError::BindingConflict);
        }
        let row = endpoint_outbound_by_object(&tx, &state.binding.session_id, object_digest)?
            .ok_or(IndexedSessionStoreError::NotFound)?;
        validate_committed_outbound(&tx, &state, &row)?;
        let envelope = Envelope::unpack(&row.immutable_envelope_bytes)
            .ok_or(IndexedSessionStoreError::InvalidEndpointEnvelope)?;
        validate_outbound_session_and_signer(
            &state,
            key,
            local_device,
            row.kind,
            row.ratchet_index,
            envelope.created_at,
            envelope.expires_at,
            now_ms,
        )?;
        tx.commit()?;
        if row.state == EndpointOutboxState::Queued {
            return Ok(row);
        }
        #[cfg(test)]
        let endpoint_fault = self.endpoint_fault.take();
        #[cfg(not(test))]
        let endpoint_fault = None;
        self.handoff_endpoint_outbound(
            &state,
            object_digest,
            local_device,
            now_ms,
            endpoint_fault,
            enqueue_idempotently,
        )
    }

    /// Returns bounded immutable ciphertext objects that still require queue
    /// handoff. Application plaintext is never exposed by this query.
    pub fn pending_endpoint_outbound(
        &self,
    ) -> Result<Vec<EndpointOutbound>, IndexedSessionStoreError> {
        let mut statement = self.conn.prepare(
            "SELECT session_id, object_digest, kind, message_id, recipient_device,
                    ratchet_index, state, immutable_envelope_bytes
             FROM endpoint_outbox WHERE state = 0 ORDER BY rowid ASC",
        )?;
        let rows = statement.query_map([], |row| -> rusqlite::Result<EndpointOutboxDbRow> {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
                row.get(7)?,
            ))
        })?;
        let mut result = Vec::new();
        for row in rows {
            result.push(decode_endpoint_outbound_row(row?)?);
        }
        Ok(result)
    }

    fn handoff_endpoint_outbound<F>(
        &mut self,
        state: &ProtectedSessionState,
        object_digest: &[u8; 32],
        local_device: &AuthorizedEndpointDevice<'_>,
        now_ms: u64,
        endpoint_fault: Option<EndpointFaultPoint>,
        enqueue_idempotently: &mut F,
    ) -> Result<EndpointOutbound, IndexedSessionStoreError>
    where
        F: FnMut(&[u8; 32], &[u8]) -> Result<[u8; 32], ()>,
    {
        let session_id = &state.binding.session_id;
        let row = endpoint_outbound_by_object(&self.conn, session_id, object_digest)?
            .ok_or(IndexedSessionStoreError::NotFound)?;
        validate_committed_outbound(&self.conn, state, &row)?;
        let envelope = Envelope::unpack(&row.immutable_envelope_bytes)
            .ok_or(IndexedSessionStoreError::InvalidEndpointEnvelope)?;
        validate_outbound_session_and_signer(
            state,
            &state.binding.key,
            local_device,
            row.kind,
            row.ratchet_index,
            envelope.created_at,
            envelope.expires_at,
            now_ms,
        )?;
        if row.state == EndpointOutboxState::Queued {
            return Ok(row);
        }
        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::BeforeOutboundQueueHandoff,
        )?;
        let persisted = enqueue_idempotently(object_digest, &row.immutable_envelope_bytes)
            .map_err(|_| IndexedSessionStoreError::OutboundQueueHandoff)?;
        if persisted != *object_digest {
            return Err(IndexedSessionStoreError::OutboundQueueHandoff);
        }
        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::AfterOutboundQueueHandoff,
        )?;
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = endpoint_outbound_by_object(&tx, session_id, object_digest)?
            .ok_or(IndexedSessionStoreError::OutboundBindingMismatch)?;
        validate_committed_outbound(&tx, state, &current)?;
        if current.state == EndpointOutboxState::Queued {
            let mut expected = row.clone();
            expected.state = EndpointOutboxState::Queued;
            if current != expected {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
            tx.commit()?;
            return Ok(current);
        }
        if current != row {
            return Err(IndexedSessionStoreError::OutboundBindingMismatch);
        }
        let changed = tx.execute(
            "UPDATE endpoint_outbox SET state = 1
             WHERE session_id = ?1 AND object_digest = ?2 AND state = 0
               AND immutable_envelope_bytes = ?3",
            params![
                session_id.as_slice(),
                object_digest.as_slice(),
                row.immutable_envelope_bytes.as_slice()
            ],
        )?;
        if changed == 0 {
            let current = endpoint_outbound_by_object(&tx, session_id, object_digest)?
                .ok_or(IndexedSessionStoreError::OutboundBindingMismatch)?;
            validate_committed_outbound(&tx, state, &current)?;
            let mut expected = row.clone();
            expected.state = EndpointOutboxState::Queued;
            if current != expected {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
            tx.commit()?;
            return Ok(current);
        }
        if changed != 1 {
            return Err(IndexedSessionStoreError::CorruptEndpointState);
        }
        if row.kind == EndpointOutboundKind::Ack {
            let ack_changed = tx.execute(
                "UPDATE endpoint_ack_intents SET state = 1
                 WHERE session_id = ?1 AND immutable_ack_bytes = ?2 AND state = 0",
                params![
                    session_id.as_slice(),
                    row.immutable_envelope_bytes.as_slice()
                ],
            )?;
            if ack_changed != 1 {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
        }
        tx.commit()?;
        Ok(EndpointOutbound {
            state: EndpointOutboxState::Queued,
            ..row
        })
    }

    /// Executes the production-disabled endpoint acceptance transaction from
    /// `ATSAM_ENDPOINT_TRANSACTION_V1.md`. No live transport calls this API.
    #[allow(clippy::too_many_arguments)]
    pub fn accept_message_envelope(
        &mut self,
        key: &IndexedSessionRecordKey,
        packed_envelope: &[u8],
        sender_certificate: &DeviceCertificate,
        sender_revoked: bool,
        now_ms: u64,
    ) -> Result<EndpointAcceptance, IndexedSessionStoreError> {
        let env = Envelope::unpack(packed_envelope)
            .ok_or(IndexedSessionStoreError::InvalidEndpointEnvelope)?;
        if env.env_type != EnvType::Message as u8 {
            return Err(IndexedSessionStoreError::EndpointTypeMismatch);
        }
        if !endpoint_time_window_valid(env.created_at, env.expires_at, now_ms)
            || env.created_at > i64::MAX as u64
            || env.expires_at > i64::MAX as u64
            || now_ms > i64::MAX as u64
        {
            return Err(IndexedSessionStoreError::EndpointNotCurrentlyValid);
        }
        let index = parse_indexed_message_header(&env.message_ciphertext)
            .map_err(|_| IndexedSessionStoreError::InvalidIndexedMessage)?;
        #[cfg(test)]
        let endpoint_fault = self.endpoint_fault.take();
        #[cfg(not(test))]
        let endpoint_fault = None;

        self.recover_pending_for_key(key)?;
        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        if &state.binding.key != key {
            return Err(IndexedSessionStoreError::BindingConflict);
        }
        if state.binding.lifecycle != SessionLifecycle::Confirmed {
            return Err(IndexedSessionStoreError::SessionNotConfirmed);
        }
        if state.pending_acceptance.is_some()
            || state.pending_ack_acceptance.is_some()
            || state.pending_outbound.is_some()
        {
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
        if now_ms < state.binding.created_at_ms
            || now_ms >= state.binding.expires_at_ms
            || env.created_at < state.binding.created_at_ms
            || env.expires_at > state.binding.expires_at_ms
        {
            return Err(IndexedSessionStoreError::EndpointNotCurrentlyValid);
        }

        let direction = state.binding.local_role.inbound_direction();
        let local_device = local_device_for_binding(&state.binding);
        let expected_hint = endpoint_device_hint(local_device);
        if env.dest_device_hint != 0 && env.dest_device_hint != expected_hint {
            return Err(IndexedSessionStoreError::DeviceHintMismatch);
        }
        let expected_route = derive_route_tag(
            &state.ratchets.root,
            env.created_at,
            index,
            env.env_type,
            direction,
        )
        .map_err(|_| IndexedSessionStoreError::RouteTagMismatch)?;
        if env.routing_tag != expected_route {
            return Err(IndexedSessionStoreError::RouteTagMismatch);
        }

        if sender_revoked {
            return Err(IndexedSessionStoreError::RevokedDevice);
        }
        sender_certificate
            .verify(now_ms)
            .map_err(|_| IndexedSessionStoreError::InvalidDeviceCertificate)?;
        let remote_device = *remote_device_for_binding(&state.binding);
        if sender_certificate.device_ed_pub != remote_device {
            return Err(IndexedSessionStoreError::DeviceBindingMismatch);
        }
        let expected_certificate_digest = *remote_certificate_digest(&state.binding);
        let actual_certificate_digest = device_certificate_hash(sender_certificate)
            .map_err(|_| IndexedSessionStoreError::InvalidDeviceCertificate)?;
        if actual_certificate_digest != expected_certificate_digest {
            return Err(IndexedSessionStoreError::DeviceBindingMismatch);
        }
        if !env.verify(&remote_device) {
            return Err(IndexedSessionStoreError::OuterSignatureInvalid);
        }

        let object_digest = authenticated_object_digest(&env);
        if endpoint_receipt_by_object(&tx, &state.binding.session_id, &object_digest)?.is_some() {
            ensure_exact_committed_object(
                &tx,
                &state.binding.session_id,
                &object_digest,
                &env.message_id,
                &remote_device,
            )?;
            tx.commit()?;
            return Ok(EndpointAcceptance::Duplicate {
                session_id: state.binding.session_id,
                object_digest,
                message_id: env.message_id,
            });
        }
        if let Some(existing_digest) = endpoint_logical_object(
            &tx,
            &state.binding.session_id,
            &remote_device,
            &env.message_id,
        )? {
            if existing_digest != object_digest {
                return Err(IndexedSessionStoreError::LogicalMessageConflict);
            }
        }

        let (sender, recipient) = endpoints_for_direction(&state.binding, direction);
        let mut candidate = prepare_receive_key(
            &mut state.ratchets.message_receive,
            index,
            sender,
            recipient,
        )?;
        let plaintext_result = open_indexed_message_with_key(
            &candidate,
            &state.binding.key.initiator_address,
            &state.binding.key.responder_address,
            direction,
            &env.message_id,
            &env.message_ciphertext,
        );
        candidate.zeroize();
        let plaintext =
            plaintext_result.map_err(|_| IndexedSessionStoreError::AuthenticationFailed)?;
        if !valid_endpoint_text(&plaintext) {
            return Err(IndexedSessionStoreError::InvalidEndpointPayload);
        }

        state.generation = state
            .generation
            .checked_add(1)
            .ok_or(IndexedSessionStoreError::IndexExhausted)?;
        let sealed_local_inbox_row = seal_local_inbox_row(
            &state.ratchets.root,
            &state.binding.session_id,
            &object_digest,
            &env.message_id,
            &remote_device,
            &plaintext,
        )?;
        state.pending_acceptance = Some(PendingAcceptance {
            session_id: state.binding.session_id,
            object_digest,
            message_id: env.message_id,
            sender_device: remote_device,
            sealed_local_inbox_row,
            ack_status: 1,
            created_at_ms: env.created_at,
            received_at_ms: now_ms,
            public_generation: state.generation,
        });

        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::BeforeProtectedReplacement,
        )?;
        write_mutation(
            &tx,
            backend.as_ref(),
            &account,
            &record_key,
            &state,
            #[cfg(test)]
            false,
        )?;
        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::AfterProtectedReplacement,
        )?;
        let pending = state
            .pending_acceptance
            .as_ref()
            .ok_or(IndexedSessionStoreError::CorruptProtectedState)?;
        insert_pending_acceptance(&tx, &state.binding, pending)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::BeforeDatabaseCommit)?;
        tx.commit()?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::AfterDatabaseCommit)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::BeforeJournalClear)?;
        state.pending_acceptance = None;
        put_protected_state(backend.as_ref(), &account, &state)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::AfterJournalClear)?;

        Ok(EndpointAcceptance::Committed {
            session_id: state.binding.session_id,
            object_digest,
            message_id: env.message_id,
            plaintext,
        })
    }

    /// Reads and authenticates a committed locally sealed inbox row.
    pub fn load_endpoint_inbox(
        &mut self,
        key: &IndexedSessionRecordKey,
        object_digest: &[u8; 32],
    ) -> Result<Option<EndpointInboxRow>, IndexedSessionStoreError> {
        self.recover_pending_for_key(key)?;
        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        if &state.binding.key != key {
            return Err(IndexedSessionStoreError::BindingConflict);
        }
        let raw: Option<EndpointInboxDbRow> = tx
            .query_row(
                "SELECT message_id, sender_device, object_digest, created_at_ms,
                        received_at_ms, sealed_local_row
                 FROM endpoint_inbox WHERE session_id = ?1 AND object_digest = ?2",
                params![
                    state.binding.session_id.as_slice(),
                    object_digest.as_slice()
                ],
                |row| {
                    Ok((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                    ))
                },
            )
            .optional()?;
        let Some((message_id, sender_device, stored_digest, created_at, received_at, sealed)) = raw
        else {
            tx.commit()?;
            return Ok(None);
        };
        let message_id = exact_array::<16>(&message_id)?;
        let sender_device = exact_array::<32>(&sender_device)?;
        let stored_digest = exact_array::<32>(&stored_digest)?;
        if stored_digest != *object_digest || created_at < 0 || received_at < 0 {
            return Err(IndexedSessionStoreError::CorruptEndpointState);
        }
        let plaintext = open_local_inbox_row(
            &state.ratchets.root,
            &state.binding.session_id,
            object_digest,
            &message_id,
            &sender_device,
            &sealed,
        )?;
        tx.commit()?;
        Ok(Some(EndpointInboxRow {
            session_id: state.binding.session_id,
            object_digest: *object_digest,
            message_id,
            sender_device,
            created_at_ms: created_at as u64,
            received_at_ms: received_at as u64,
            plaintext,
        }))
    }

    /// Returns only ACK intents in a committed SQLite transaction.
    pub fn pending_endpoint_ack_intents(
        &self,
    ) -> Result<Vec<EndpointAckIntent>, IndexedSessionStoreError> {
        let mut statement = self.conn.prepare(
            "SELECT session_id, object_digest, message_id, remote_device,
                    status, state, immutable_ack_bytes
             FROM endpoint_ack_intents WHERE state = 0
             ORDER BY rowid ASC",
        )?;
        let rows = statement.query_map([], |row| -> rusqlite::Result<EndpointPendingAckDbRow> {
            Ok((
                row.get::<_, Vec<u8>>(0)?,
                row.get::<_, Vec<u8>>(1)?,
                row.get::<_, Vec<u8>>(2)?,
                row.get::<_, Vec<u8>>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, Option<Vec<u8>>>(6)?,
            ))
        })?;
        let mut result = Vec::new();
        for row in rows {
            let (session, digest, message, remote, status, state, bytes) = row?;
            if !matches!(status, 1 | 2) || !(0..=u8::MAX as i64).contains(&state) {
                return Err(IndexedSessionStoreError::CorruptEndpointState);
            }
            result.push(EndpointAckIntent {
                session_id: exact_array(&session)?,
                object_digest: exact_array(&digest)?,
                message_id: exact_array(&message)?,
                remote_device: exact_array(&remote)?,
                status: status as u8,
                state: EndpointAckIntentState::from_u8(state as u8)?,
                immutable_ack_bytes: bytes,
            });
        }
        Ok(result)
    }

    /// Persists immutable ACK bytes before invoking an idempotent durable queue
    /// insertion. A crash after insertion leaves the intent pending so retry
    /// reuses exactly the same bytes.
    #[cfg(test)]
    fn enqueue_endpoint_ack<F>(
        &mut self,
        session_id: &[u8; 32],
        object_digest: &[u8; 32],
        immutable_ack_bytes: &[u8],
        enqueue_idempotently: F,
    ) -> Result<(), IndexedSessionStoreError>
    where
        F: FnOnce(&[u8]) -> Result<(), String>,
    {
        if immutable_ack_bytes.is_empty()
            || immutable_ack_bytes.len() > crate::envelope::MAX_WIRE_ENVELOPE_BYTES
        {
            return Err(IndexedSessionStoreError::InvalidEndpointEnvelope);
        }
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let raw: Option<(i64, Option<Vec<u8>>)> = tx
            .query_row(
                "SELECT state, immutable_ack_bytes FROM endpoint_ack_intents
                 WHERE session_id = ?1 AND object_digest = ?2",
                params![session_id.as_slice(), object_digest.as_slice()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        let Some((state, existing)) = raw else {
            return Err(IndexedSessionStoreError::NotFound);
        };
        if state == EndpointAckIntentState::Queued as i64 {
            if existing.as_deref() != Some(immutable_ack_bytes) {
                return Err(IndexedSessionStoreError::AckBytesConflict);
            }
            tx.commit()?;
            return Ok(());
        }
        if state != EndpointAckIntentState::Pending as i64 {
            return Err(IndexedSessionStoreError::CorruptEndpointState);
        }
        if let Some(existing) = existing {
            if existing != immutable_ack_bytes {
                return Err(IndexedSessionStoreError::AckBytesConflict);
            }
        } else {
            tx.execute(
                "UPDATE endpoint_ack_intents SET immutable_ack_bytes = ?1
                 WHERE session_id = ?2 AND object_digest = ?3 AND state = 0",
                params![
                    immutable_ack_bytes,
                    session_id.as_slice(),
                    object_digest.as_slice()
                ],
            )?;
        }
        tx.commit()?;
        self.maybe_endpoint_fault(EndpointFaultPoint::BeforeAckEnqueue)?;
        enqueue_idempotently(immutable_ack_bytes)
            .map_err(|_| IndexedSessionStoreError::AckEnqueue)?;
        self.maybe_endpoint_fault(EndpointFaultPoint::AfterAckEnqueue)?;
        let changed = self.conn.execute(
            "UPDATE endpoint_ack_intents SET state = 1
             WHERE session_id = ?1 AND object_digest = ?2 AND state = 0
               AND immutable_ack_bytes = ?3",
            params![
                session_id.as_slice(),
                object_digest.as_slice(),
                immutable_ack_bytes
            ],
        )?;
        if changed != 1 {
            return Err(IndexedSessionStoreError::CorruptEndpointState);
        }
        Ok(())
    }

    /// Registers the exact outbound logical row that may later be advanced by
    /// an authenticated ACK. The session's expected remote device is fixed by
    /// PairInit; callers cannot register an arbitrary recipient.
    #[cfg(test)]
    fn register_outstanding_message(
        &mut self,
        key: &IndexedSessionRecordKey,
        message_id: &[u8; 16],
    ) -> Result<(), IndexedSessionStoreError> {
        self.recover_pending_for_key(key)?;
        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        if &state.binding.key != key {
            return Err(IndexedSessionStoreError::BindingConflict);
        }
        let remote = remote_device_for_binding(&state.binding);
        tx.execute(
            "INSERT INTO endpoint_outstanding_messages
             (session_id, message_id, recipient_device, delivery_state)
             VALUES (?1, ?2, ?3, 0)
             ON CONFLICT(session_id, message_id, recipient_device) DO NOTHING",
            params![
                state.binding.session_id.as_slice(),
                message_id.as_slice(),
                remote.as_slice()
            ],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn outstanding_delivery_state(
        &self,
        session_id: &[u8; 32],
        message_id: &[u8; 16],
        recipient_device: &[u8; 32],
    ) -> Result<Option<EndpointDeliveryState>, IndexedSessionStoreError> {
        let value: Option<i64> = self
            .conn
            .query_row(
                "SELECT delivery_state FROM endpoint_outstanding_messages
                 WHERE session_id = ?1 AND message_id = ?2 AND recipient_device = ?3",
                params![
                    session_id.as_slice(),
                    message_id.as_slice(),
                    recipient_device.as_slice()
                ],
                |row| row.get(0),
            )
            .optional()?;
        value
            .map(|raw| {
                u8::try_from(raw)
                    .map_err(|_| IndexedSessionStoreError::CorruptEndpointState)
                    .and_then(EndpointDeliveryState::from_u8)
            })
            .transpose()
    }

    /// Accepts one sealed proto `0x03` ACK and conditionally advances only the
    /// exact outstanding `(message_id, recipient_device)` row. The ACK receive
    /// ratchet and database update use the same protected journal recovery
    /// pattern as message acceptance.
    pub fn accept_ack_envelope(
        &mut self,
        key: &IndexedSessionRecordKey,
        packed_envelope: &[u8],
        sender_certificate: &DeviceCertificate,
        sender_revoked: bool,
        now_ms: u64,
    ) -> Result<EndpointAckAcceptance, IndexedSessionStoreError> {
        let env = Envelope::unpack(packed_envelope)
            .ok_or(IndexedSessionStoreError::InvalidEndpointEnvelope)?;
        if env.env_type != EnvType::Ack as u8 {
            return Err(IndexedSessionStoreError::EndpointTypeMismatch);
        }
        if !endpoint_time_window_valid(env.created_at, env.expires_at, now_ms)
            || env.created_at > i64::MAX as u64
            || env.expires_at > i64::MAX as u64
            || now_ms > i64::MAX as u64
        {
            return Err(IndexedSessionStoreError::EndpointNotCurrentlyValid);
        }
        let index = parse_indexed_message_header(&env.message_ciphertext)
            .map_err(|_| IndexedSessionStoreError::InvalidIndexedMessage)?;
        #[cfg(test)]
        let endpoint_fault = self.endpoint_fault.take();
        #[cfg(not(test))]
        let endpoint_fault = None;

        self.recover_pending_for_key(key)?;
        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        if &state.binding.key != key {
            return Err(IndexedSessionStoreError::BindingConflict);
        }
        if state.binding.lifecycle != SessionLifecycle::Confirmed {
            return Err(IndexedSessionStoreError::SessionNotConfirmed);
        }
        if state.pending_acceptance.is_some()
            || state.pending_ack_acceptance.is_some()
            || state.pending_outbound.is_some()
        {
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
        if now_ms < state.binding.created_at_ms
            || now_ms >= state.binding.expires_at_ms
            || env.created_at < state.binding.created_at_ms
            || env.expires_at > state.binding.expires_at_ms
        {
            return Err(IndexedSessionStoreError::EndpointNotCurrentlyValid);
        }

        let direction = state.binding.local_role.inbound_direction();
        let expected_hint = endpoint_device_hint(local_device_for_binding(&state.binding));
        if env.dest_device_hint != 0 && env.dest_device_hint != expected_hint {
            return Err(IndexedSessionStoreError::DeviceHintMismatch);
        }
        let expected_route = derive_route_tag(
            &state.ratchets.root,
            env.created_at,
            index,
            env.env_type,
            direction,
        )
        .map_err(|_| IndexedSessionStoreError::RouteTagMismatch)?;
        if env.routing_tag != expected_route {
            return Err(IndexedSessionStoreError::RouteTagMismatch);
        }
        if sender_revoked {
            return Err(IndexedSessionStoreError::RevokedDevice);
        }
        sender_certificate
            .verify(now_ms)
            .map_err(|_| IndexedSessionStoreError::InvalidDeviceCertificate)?;
        let remote = *remote_device_for_binding(&state.binding);
        if sender_certificate.device_ed_pub != remote
            || device_certificate_hash(sender_certificate)
                .map_err(|_| IndexedSessionStoreError::InvalidDeviceCertificate)?
                != *remote_certificate_digest(&state.binding)
        {
            return Err(IndexedSessionStoreError::DeviceBindingMismatch);
        }
        if !env.verify(&remote) {
            return Err(IndexedSessionStoreError::OuterSignatureInvalid);
        }
        let object_digest = authenticated_object_digest(&env);
        if let Some(existing) =
            endpoint_ack_receipt(&tx, &state.binding.session_id, &object_digest)?
        {
            if existing.outer_message_id != env.message_id || existing.remote_device != remote {
                return Err(IndexedSessionStoreError::CorruptEndpointState);
            }
            let delivery_state = self_delivery_state_in_tx(
                &tx,
                &state.binding.session_id,
                &existing.acked_message_id,
                &remote,
            )?
            .ok_or(IndexedSessionStoreError::CorruptEndpointState)?;
            tx.commit()?;
            return Ok(EndpointAckAcceptance::Duplicate {
                session_id: state.binding.session_id,
                object_digest,
                acked_message_id: existing.acked_message_id,
                delivery_state,
            });
        }

        let (sender, recipient) = endpoints_for_direction(&state.binding, direction);
        let mut candidate =
            prepare_receive_key(&mut state.ratchets.ack_receive, index, sender, recipient)?;
        let plaintext_result = open_indexed_message_with_key(
            &candidate,
            &state.binding.key.initiator_address,
            &state.binding.key.responder_address,
            direction,
            &env.message_id,
            &env.message_ciphertext,
        );
        candidate.zeroize();
        let plaintext =
            plaintext_result.map_err(|_| IndexedSessionStoreError::AuthenticationFailed)?;
        let signed = decode_signed_ack(&plaintext)
            .map_err(|_| IndexedSessionStoreError::InvalidIndexedMessage)?;
        if signed.record.created_at != env.created_at {
            return Err(IndexedSessionStoreError::AckTimestampMismatch);
        }
        if !signed.record.verify(&signed.signature, &remote) {
            return Err(IndexedSessionStoreError::AckInnerSignatureInvalid);
        }
        let Some(existing_state) = self_delivery_state_in_tx(
            &tx,
            &state.binding.session_id,
            &signed.record.acked_message_id,
            &remote,
        )?
        else {
            return Err(IndexedSessionStoreError::AckOutstandingMismatch);
        };
        if let Some(existing_object) = ack_nonce_object(
            &tx,
            &state.binding.session_id,
            &remote,
            &signed.record.ack_nonce,
        )? {
            if existing_object != object_digest {
                return Err(IndexedSessionStoreError::AckNonceConflict);
            }
        }
        let target_state = EndpointDeliveryState::from_u8(signed.record.status)?;
        let delivery_state = std::cmp::max(existing_state, target_state);
        state.generation = state
            .generation
            .checked_add(1)
            .ok_or(IndexedSessionStoreError::IndexExhausted)?;
        state.pending_ack_acceptance = Some(PendingAckAcceptance {
            session_id: state.binding.session_id,
            object_digest,
            outer_message_id: env.message_id,
            remote_device: remote,
            acked_message_id: signed.record.acked_message_id,
            status: signed.record.status,
            ack_nonce: signed.record.ack_nonce,
            created_at_ms: env.created_at,
            public_generation: state.generation,
        });
        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::BeforeProtectedReplacement,
        )?;
        write_mutation(
            &tx,
            backend.as_ref(),
            &account,
            &record_key,
            &state,
            #[cfg(test)]
            false,
        )?;
        maybe_injected_endpoint_fault(
            endpoint_fault,
            EndpointFaultPoint::AfterProtectedReplacement,
        )?;
        let pending = state
            .pending_ack_acceptance
            .as_ref()
            .ok_or(IndexedSessionStoreError::CorruptProtectedState)?;
        insert_pending_ack_acceptance(&tx, &state.binding, pending)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::BeforeDatabaseCommit)?;
        tx.commit()?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::AfterDatabaseCommit)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::BeforeJournalClear)?;
        state.pending_ack_acceptance = None;
        put_protected_state(backend.as_ref(), &account, &state)?;
        maybe_injected_endpoint_fault(endpoint_fault, EndpointFaultPoint::AfterJournalClear)?;
        Ok(EndpointAckAcceptance::Committed {
            session_id: state.binding.session_id,
            object_digest,
            acked_message_id: signed.record.acked_message_id,
            delivery_state,
        })
    }

    fn recover_all_pending_acceptances(&mut self) -> Result<(), IndexedSessionStoreError> {
        let record_keys = {
            let mut statement = self
                .conn
                .prepare("SELECT record_key FROM indexed_session_heads ORDER BY record_key")?;
            let rows = statement.query_map([], |row| row.get::<_, Vec<u8>>(0))?;
            let mut keys = Vec::new();
            for row in rows {
                keys.push(exact_array::<32>(&row?)?);
            }
            keys
        };
        for record_key in record_keys {
            self.recover_pending_for_digest(&record_key)?;
        }
        Ok(())
    }

    fn recover_pending_for_key(
        &mut self,
        key: &IndexedSessionRecordKey,
    ) -> Result<(), IndexedSessionStoreError> {
        self.recover_pending_for_digest(&record_key_digest(key)?)
    }

    fn recover_pending_for_digest(
        &mut self,
        record_key: &[u8; 32],
    ) -> Result<(), IndexedSessionStoreError> {
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut state = load_and_reconcile(&tx, backend.as_ref(), &account, record_key)?;
        let Some(pending) = state.pending_acceptance.as_ref() else {
            if let Some(pending_ack) = state.pending_ack_acceptance.as_ref() {
                if state.pending_outbound.is_some() {
                    return Err(IndexedSessionStoreError::CorruptProtectedState);
                }
                insert_pending_ack_acceptance(&tx, &state.binding, pending_ack)?;
                tx.commit()?;
                state.pending_ack_acceptance = None;
                return put_protected_state(backend.as_ref(), &account, &state);
            }
            if let Some(pending_outbound) = state.pending_outbound.as_ref() {
                insert_pending_outbound(&tx, &state, pending_outbound)?;
                tx.commit()?;
                state.pending_outbound = None;
                return put_protected_state(backend.as_ref(), &account, &state);
            }
            tx.commit()?;
            return Ok(());
        };
        if state.pending_ack_acceptance.is_some() || state.pending_outbound.is_some() {
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
        insert_pending_acceptance(&tx, &state.binding, pending)?;
        tx.commit()?;
        state.pending_acceptance = None;
        put_protected_state(backend.as_ref(), &account, &state)
    }

    #[cfg(test)]
    fn maybe_endpoint_fault(
        &self,
        point: EndpointFaultPoint,
    ) -> Result<(), IndexedSessionStoreError> {
        #[cfg(test)]
        if self.endpoint_fault.get() == Some(point) {
            self.endpoint_fault.set(None);
            return Err(IndexedSessionStoreError::InjectedEndpointFailure(
                point.label(),
            ));
        }
        #[cfg(not(test))]
        let _ = point;
        Ok(())
    }

    /// Verifies an exact PairResponse against both the accepted PairInit and
    /// the protected provisional root before monotonically confirming state.
    /// Both initiator and responder call this method; responder self-confirm
    /// verifies the exact signed response it generated through the same path.
    pub fn confirm_verified_pair_response(
        &mut self,
        key: &IndexedSessionRecordKey,
        accepted_init: &PairInit,
        response: &PairResponse,
        now_ms: u64,
    ) -> Result<(), IndexedSessionStoreError> {
        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        if &state.binding.key != key
            || accepted_init.initiator_address != key.initiator_address
            || accepted_init.responder_address != key.responder_address
            || accepted_init.initiator_device_ed_pub != key.initiator_device_ed25519
            || accepted_init.responder_device_ed_pub != key.responder_device_ed25519
            || accepted_init.init_id != key.init_id
            || pair_init_hash(accepted_init)? != state.binding.init_hash
            || pair_session_id(accepted_init)? != state.binding.session_id
            || pair_transcript_hash(accepted_init)? != state.binding.transcript_hash
        {
            return Err(IndexedSessionStoreError::BindingConflict);
        }
        verify_response(response, accepted_init, &state.ratchets.root, now_ms)?;
        let response_hash: [u8; 32] = Sha256::digest(encode_pair_response(response)?).into();
        drop(state);
        tx.commit()?;
        self.confirm_session_inner(key, response_hash)
    }

    /// Test-only state transition; production callers cannot inject an
    /// arbitrary response hash.
    #[cfg(test)]
    fn confirm_session(
        &mut self,
        key: &IndexedSessionRecordKey,
        response_hash: [u8; 32],
    ) -> Result<(), IndexedSessionStoreError> {
        self.confirm_session_inner(key, response_hash)
    }

    fn confirm_session_inner(
        &mut self,
        key: &IndexedSessionRecordKey,
        response_hash: [u8; 32],
    ) -> Result<(), IndexedSessionStoreError> {
        self.recover_pending_for_key(key)?;
        let record_key = record_key_digest(key)?;
        let account = hex::encode(record_key);
        let backend = Arc::clone(&self.backend);
        let tx = self
            .conn
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut state = load_and_reconcile(&tx, backend.as_ref(), &account, &record_key)?;
        match (state.binding.lifecycle, state.binding.response_hash) {
            (SessionLifecycle::Confirmed, Some(existing)) if existing == response_hash => {
                tx.commit()?;
                return Ok(());
            }
            (SessionLifecycle::Confirmed, _) => {
                return Err(IndexedSessionStoreError::ConfirmationConflict)
            }
            (SessionLifecycle::Provisional, None) => {}
            _ => return Err(IndexedSessionStoreError::CorruptProtectedState),
        }
        state.binding.lifecycle = SessionLifecycle::Confirmed;
        state.binding.response_hash = Some(response_hash);
        state.generation = state
            .generation
            .checked_add(1)
            .ok_or(IndexedSessionStoreError::IndexExhausted)?;
        write_mutation(
            &tx,
            backend.as_ref(),
            &account,
            &record_key,
            &state,
            #[cfg(test)]
            self.crash_after_protected_write,
        )?;
        tx.commit()?;
        Ok(())
    }

    #[cfg(test)]
    fn inject_crash_after_next_protected_write(&mut self) {
        self.crash_after_protected_write = true;
    }

    #[cfg(test)]
    fn inject_endpoint_fault(&self, point: EndpointFaultPoint) {
        self.endpoint_fault.set(Some(point));
    }
}

pub fn endpoint_device_hint(device_ed25519: &[u8; 32]) -> u64 {
    let mut hasher = Sha256::new();
    hasher.update(b"rvn1/device-hint/v1");
    hasher.update(device_ed25519);
    let digest = hasher.finalize();
    u64::from_be_bytes(digest[..8].try_into().expect("fixed SHA-256 prefix"))
}

fn local_device_for_binding(binding: &IndexedSessionBinding) -> &[u8; 32] {
    match binding.local_role {
        LocalRole::Initiator => &binding.key.initiator_device_ed25519,
        LocalRole::Responder => &binding.key.responder_device_ed25519,
    }
}

fn remote_device_for_binding(binding: &IndexedSessionBinding) -> &[u8; 32] {
    match binding.local_role {
        LocalRole::Initiator => &binding.key.responder_device_ed25519,
        LocalRole::Responder => &binding.key.initiator_device_ed25519,
    }
}

fn remote_certificate_digest(binding: &IndexedSessionBinding) -> &[u8; 32] {
    match binding.local_role {
        LocalRole::Initiator => &binding.responder_cert_digest,
        LocalRole::Responder => &binding.initiator_cert_digest,
    }
}

fn local_certificate_digest(binding: &IndexedSessionBinding) -> &[u8; 32] {
    match binding.local_role {
        LocalRole::Initiator => &binding.initiator_cert_digest,
        LocalRole::Responder => &binding.responder_cert_digest,
    }
}

fn local_address_for_binding(binding: &IndexedSessionBinding) -> &str {
    match binding.local_role {
        LocalRole::Initiator => &binding.key.initiator_address,
        LocalRole::Responder => &binding.key.responder_address,
    }
}

// The explicit coordinates are security bindings, not an ergonomic facade:
// grouping them into a caller-constructible request object would make it
// easier to validate one set and materialize another.
#[allow(clippy::too_many_arguments)]
fn validate_outbound_session_and_signer(
    state: &ProtectedSessionState,
    key: &IndexedSessionRecordKey,
    local_device: &AuthorizedEndpointDevice<'_>,
    kind: EndpointOutboundKind,
    ratchet_index: u32,
    created_at_ms: u64,
    expires_at_ms: u64,
    now_ms: u64,
) -> Result<(), IndexedSessionStoreError> {
    if !endpoint_time_window_valid(created_at_ms, expires_at_ms, now_ms) {
        return Err(IndexedSessionStoreError::EndpointNotCurrentlyValid);
    }
    if &state.binding.key != key {
        return Err(IndexedSessionStoreError::BindingConflict);
    }
    match state.binding.lifecycle {
        SessionLifecycle::Confirmed => {}
        SessionLifecycle::Provisional
            if kind == EndpointOutboundKind::Message
                && state.binding.local_role == LocalRole::Initiator
                && ratchet_index == 0 => {}
        SessionLifecycle::Provisional => return Err(IndexedSessionStoreError::SessionNotConfirmed),
    }
    if now_ms < state.binding.created_at_ms
        || now_ms >= state.binding.expires_at_ms
        || created_at_ms < state.binding.created_at_ms
        || expires_at_ms > state.binding.expires_at_ms
    {
        return Err(IndexedSessionStoreError::EndpointNotCurrentlyValid);
    }
    local_device.validate_current(now_ms)?;
    let certificate = local_device.certificate;
    let certificate_digest = device_certificate_hash(certificate)
        .map_err(|_| IndexedSessionStoreError::LocalDeviceUnauthorized)?;
    if certificate.device_ed_pub != *local_device_for_binding(&state.binding)
        || certificate_digest != *local_certificate_digest(&state.binding)
        || crate::address::encode_address(&certificate.user_ed_pub)
            != local_address_for_binding(&state.binding)
        || created_at_ms < certificate.not_before_ms
        || expires_at_ms > certificate.not_after_ms
    {
        return Err(IndexedSessionStoreError::LocalDeviceBindingMismatch);
    }
    Ok(())
}

fn ensure_no_pending_protected_mutation(
    state: &ProtectedSessionState,
) -> Result<(), IndexedSessionStoreError> {
    if state.pending_acceptance.is_some()
        || state.pending_ack_acceptance.is_some()
        || state.pending_outbound.is_some()
    {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    Ok(())
}

fn random_nonzero<const N: usize, R: RngCore + CryptoRng>(
    rng: &mut R,
) -> Result<[u8; N], IndexedSessionStoreError> {
    let mut value = [0u8; N];
    rng.try_fill_bytes(&mut value)
        .map_err(|_| IndexedSessionStoreError::EndpointRandomnessUnavailable)?;
    if value.iter().all(|byte| *byte == 0) {
        value.zeroize();
        return Err(IndexedSessionStoreError::EndpointRandomnessUnavailable);
    }
    Ok(value)
}

fn ensure_fresh_outbound_coordinates(
    conn: &Connection,
    session_id: &[u8; 32],
    message_id: &[u8; 16],
    seal_nonce: &[u8; 12],
    anti_replay_nonce: &[u8; 12],
    ack_nonce: Option<&[u8; 12]>,
) -> Result<(), IndexedSessionStoreError> {
    let collision: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM endpoint_outbox
             WHERE session_id = ?1 AND (message_id = ?2
               OR seal_nonce = ?3
               OR anti_replay_nonce = ?4
               OR (?5 IS NOT NULL AND ack_nonce = ?5)) LIMIT 1",
            params![
                session_id.as_slice(),
                message_id.as_slice(),
                seal_nonce.as_slice(),
                anti_replay_nonce.as_slice(),
                ack_nonce.map(|value| value.as_slice())
            ],
            |row| row.get(0),
        )
        .optional()?;
    if collision.is_some() {
        return Err(IndexedSessionStoreError::OutboundCollision);
    }
    let historical_id: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM endpoint_outstanding_messages
             WHERE session_id = ?1 AND message_id = ?2
             UNION ALL
             SELECT 1 FROM endpoint_ack_receipts
             WHERE session_id = ?1 AND outer_message_id = ?2
             LIMIT 1",
            params![session_id.as_slice(), message_id.as_slice()],
            |row| row.get(0),
        )
        .optional()?;
    if historical_id.is_some() {
        return Err(IndexedSessionStoreError::OutboundCollision);
    }
    Ok(())
}

fn prepared_outbound_exists(
    conn: &Connection,
    session_id: &[u8; 32],
) -> Result<bool, IndexedSessionStoreError> {
    Ok(conn
        .query_row(
            "SELECT 1 FROM endpoint_outbox WHERE session_id = ?1 AND state = 0 LIMIT 1",
            params![session_id.as_slice()],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .is_some())
}

#[allow(clippy::too_many_arguments)]
fn outbound_envelope(
    state: &ProtectedSessionState,
    env_type: EnvType,
    index: u32,
    message_id: [u8; 16],
    anti_replay_nonce: [u8; 12],
    created_at_ms: u64,
    expires_at_ms: u64,
    message_ciphertext: Vec<u8>,
) -> Result<Envelope, IndexedSessionStoreError> {
    let direction = state.binding.local_role.outbound_direction();
    let routing_tag = derive_route_tag(
        &state.ratchets.root,
        created_at_ms,
        index,
        env_type as u8,
        direction,
    )
    .map_err(|_| IndexedSessionStoreError::OutboundBindingMismatch)?;
    Ok(Envelope {
        env_type: env_type as u8,
        flags: OUTBOUND_FLAGS,
        message_id,
        routing_tag,
        dest_device_hint: endpoint_device_hint(remote_device_for_binding(&state.binding)),
        created_at: created_at_ms,
        expires_at: expires_at_ms,
        hop_limit: OUTBOUND_HOP_LIMIT,
        replication_budget: OUTBOUND_REPLICATION_BUDGET,
        anti_replay_nonce,
        ratchet_header_ciphertext: Vec::new(),
        message_ciphertext,
        sender_authentication: vec![0; 64],
    })
}

fn sign_outbound_envelope(
    envelope: &mut Envelope,
    local_device: &AuthorizedEndpointDevice<'_>,
) -> Result<(), IndexedSessionStoreError> {
    envelope.sender_authentication = local_device
        .sign_verified(&envelope.signing_bytes())?
        .to_vec();
    if !envelope.verify(&local_device.certificate.device_ed_pub) {
        return Err(IndexedSessionStoreError::LocalSignerFailure);
    }
    Ok(())
}

fn validate_materialized_outbound(
    envelope: &Envelope,
    packed: &[u8],
) -> Result<(), IndexedSessionStoreError> {
    if packed.is_empty()
        || packed.len() > MAX_PENDING_OUTBOUND_BYTES
        || Envelope::unpack(packed).as_ref() != Some(envelope)
        || envelope.flags != OUTBOUND_FLAGS
        || envelope.hop_limit != OUTBOUND_HOP_LIMIT
        || envelope.replication_budget != OUTBOUND_REPLICATION_BUDGET
        || !envelope.ratchet_header_ciphertext.is_empty()
    {
        return Err(IndexedSessionStoreError::InvalidEndpointEnvelope);
    }
    Ok(())
}

fn exact_array<const N: usize>(value: &[u8]) -> Result<[u8; N], IndexedSessionStoreError> {
    value
        .try_into()
        .map_err(|_| IndexedSessionStoreError::CorruptEndpointState)
}

fn decode_endpoint_outbound_row(
    raw: EndpointOutboxDbRow,
) -> Result<EndpointOutbound, IndexedSessionStoreError> {
    let (session, object, kind, message, recipient, index, state, immutable) = raw;
    if !(0..=u32::MAX as i64).contains(&index)
        || !(0..=u8::MAX as i64).contains(&kind)
        || !(0..=u8::MAX as i64).contains(&state)
        || immutable.len() < crate::envelope::PREFIX_LEN
        || immutable.len() > MAX_PENDING_OUTBOUND_BYTES
    {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    let result = EndpointOutbound {
        kind: EndpointOutboundKind::from_u8(kind as u8)?,
        session_id: exact_array(&session)?,
        object_digest: exact_array(&object)?,
        message_id: exact_array(&message)?,
        recipient_device: exact_array(&recipient)?,
        ratchet_index: index as u32,
        state: EndpointOutboxState::from_u8(state as u8)?,
        immutable_envelope_bytes: immutable,
    };
    let envelope = Envelope::unpack(&result.immutable_envelope_bytes)
        .ok_or(IndexedSessionStoreError::CorruptEndpointState)?;
    if envelope.message_id != result.message_id
        || parse_indexed_message_header(&envelope.message_ciphertext)
            .map_err(|_| IndexedSessionStoreError::CorruptEndpointState)?
            != result.ratchet_index
        || authenticated_object_digest(&envelope) != result.object_digest
        || envelope.env_type != result.kind as u8
    {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    Ok(result)
}

fn endpoint_outbound_by_object(
    conn: &Connection,
    session_id: &[u8; 32],
    object_digest: &[u8; 32],
) -> Result<Option<EndpointOutbound>, IndexedSessionStoreError> {
    let raw: Option<EndpointOutboxDbRow> = conn
        .query_row(
            "SELECT session_id, object_digest, kind, message_id, recipient_device,
                    ratchet_index, state, immutable_envelope_bytes
             FROM endpoint_outbox WHERE session_id = ?1 AND object_digest = ?2",
            params![session_id.as_slice(), object_digest.as_slice()],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                ))
            },
        )
        .optional()?;
    raw.map(decode_endpoint_outbound_row).transpose()
}

fn outbound_by_ack_intent(
    conn: &Connection,
    session_id: &[u8; 32],
    intent_object_digest: &[u8; 32],
) -> Result<Option<EndpointOutbound>, IndexedSessionStoreError> {
    let raw: Option<EndpointOutboxDbRow> = conn
        .query_row(
            "SELECT session_id, object_digest, kind, message_id, recipient_device,
                    ratchet_index, state, immutable_envelope_bytes
             FROM endpoint_outbox
             WHERE session_id = ?1 AND source_ack_intent = ?2",
            params![session_id.as_slice(), intent_object_digest.as_slice()],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                ))
            },
        )
        .optional()?;
    let value = raw.map(decode_endpoint_outbound_row).transpose()?;
    if value
        .as_ref()
        .is_some_and(|row| row.kind != EndpointOutboundKind::Ack)
    {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    Ok(value)
}

fn committed_ack_intent(
    conn: &Connection,
    session_id: &[u8; 32],
    object_digest: &[u8; 32],
) -> Result<EndpointAckIntent, IndexedSessionStoreError> {
    let raw: Option<EndpointAckIntentDbRow> = conn
        .query_row(
            "SELECT message_id, remote_device, status, state, immutable_ack_bytes
             FROM endpoint_ack_intents WHERE session_id = ?1 AND object_digest = ?2",
            params![session_id.as_slice(), object_digest.as_slice()],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()?;
    let Some((message, remote, status, state, immutable)) = raw else {
        return Err(IndexedSessionStoreError::NotFound);
    };
    if !matches!(status, 1 | 2) || !(0..=u8::MAX as i64).contains(&state) {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    Ok(EndpointAckIntent {
        session_id: *session_id,
        object_digest: *object_digest,
        message_id: exact_array(&message)?,
        remote_device: exact_array(&remote)?,
        status: status as u8,
        state: EndpointAckIntentState::from_u8(state as u8)?,
        immutable_ack_bytes: immutable,
    })
}

fn insert_pending_outbound(
    tx: &Transaction<'_>,
    state: &ProtectedSessionState,
    pending: &PendingOutbound,
) -> Result<(), IndexedSessionStoreError> {
    let binding = &state.binding;
    validate_pending_outbound_shape(pending)?;
    if pending.session_id != binding.session_id
        || pending.recipient_device != *remote_device_for_binding(binding)
        || pending.public_generation > i64::MAX as u64
    {
        return Err(IndexedSessionStoreError::OutboundBindingMismatch);
    }
    let envelope = Envelope::unpack(&pending.immutable_envelope_bytes)
        .ok_or(IndexedSessionStoreError::InvalidEndpointEnvelope)?;
    let direction = binding.local_role.outbound_direction();
    let expected_route = derive_route_tag(
        &state.ratchets.root,
        envelope.created_at,
        pending.ratchet_index,
        envelope.env_type,
        direction,
    )
    .map_err(|_| IndexedSessionStoreError::OutboundBindingMismatch)?;
    if !envelope.verify(local_device_for_binding(binding))
        || envelope.dest_device_hint != endpoint_device_hint(remote_device_for_binding(binding))
        || envelope.routing_tag != expected_route
        || envelope.created_at < binding.created_at_ms
        || envelope.expires_at > binding.expires_at_ms
    {
        return Err(IndexedSessionStoreError::OutboundBindingMismatch);
    }
    let metadata_generation: i64 = tx.query_row(
        "SELECT generation FROM indexed_session_heads WHERE session_id = ?1",
        params![pending.session_id.as_slice()],
        |row| row.get(0),
    )?;
    if metadata_generation < 0 || metadata_generation as u64 != pending.public_generation {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }

    let existing = endpoint_outbound_by_object(tx, &pending.session_id, &pending.object_digest)?;
    if existing.is_none() {
        ensure_fresh_outbound_coordinates(
            tx,
            &pending.session_id,
            &pending.message_id,
            &pending.seal_nonce,
            &pending.anti_replay_nonce,
            pending.ack_nonce.as_ref(),
        )?;
        tx.execute(
            "INSERT INTO endpoint_outbox
             (session_id, object_digest, kind, message_id, recipient_device,
              ratchet_index, source_ack_intent, ack_nonce, seal_nonce, anti_replay_nonce,
              immutable_envelope_bytes, state, session_generation)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0, ?12)",
            params![
                pending.session_id.as_slice(),
                pending.object_digest.as_slice(),
                pending.kind as u8,
                pending.message_id.as_slice(),
                pending.recipient_device.as_slice(),
                pending.ratchet_index,
                pending
                    .source_ack_intent
                    .as_ref()
                    .map(|value| value.as_slice()),
                pending.ack_nonce.as_ref().map(|value| value.as_slice()),
                pending.seal_nonce.as_slice(),
                pending.anti_replay_nonce.as_slice(),
                pending.immutable_envelope_bytes.as_slice(),
                pending.public_generation as i64,
            ],
        )?;
    }
    let existing = endpoint_outbound_by_object(tx, &pending.session_id, &pending.object_digest)?
        .ok_or(IndexedSessionStoreError::CorruptEndpointState)?;
    let details: EndpointOutboxDetailsDbRow = tx.query_row(
        "SELECT source_ack_intent, ack_nonce, seal_nonce, anti_replay_nonce, session_generation
         FROM endpoint_outbox WHERE session_id = ?1 AND object_digest = ?2",
        params![
            pending.session_id.as_slice(),
            pending.object_digest.as_slice()
        ],
        |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        },
    )?;
    if existing.kind != pending.kind
        || existing.message_id != pending.message_id
        || existing.recipient_device != pending.recipient_device
        || existing.ratchet_index != pending.ratchet_index
        || existing.immutable_envelope_bytes != pending.immutable_envelope_bytes
        || details.0.as_deref() != pending.source_ack_intent.as_ref().map(|v| v.as_slice())
        || details.1.as_deref() != pending.ack_nonce.as_ref().map(|v| v.as_slice())
        || details.2.as_slice() != pending.seal_nonce
        || details.3.as_slice() != pending.anti_replay_nonce
        || details.4 != pending.public_generation as i64
    {
        return Err(IndexedSessionStoreError::OutboundBindingMismatch);
    }

    match pending.kind {
        EndpointOutboundKind::Message => {
            tx.execute(
                "INSERT INTO endpoint_outstanding_messages
                 (session_id, message_id, recipient_device, delivery_state)
                 VALUES (?1, ?2, ?3, 0)
                 ON CONFLICT(session_id, message_id, recipient_device) DO NOTHING",
                params![
                    pending.session_id.as_slice(),
                    pending.message_id.as_slice(),
                    pending.recipient_device.as_slice()
                ],
            )?;
            if self_delivery_state_in_tx(
                tx,
                &pending.session_id,
                &pending.message_id,
                &pending.recipient_device,
            )? != Some(EndpointDeliveryState::Sent)
            {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
        }
        EndpointOutboundKind::Ack => {
            let source = pending
                .source_ack_intent
                .as_ref()
                .ok_or(IndexedSessionStoreError::OutboundBindingMismatch)?;
            let intent = committed_ack_intent(tx, &pending.session_id, source)?;
            let receipt = endpoint_receipt_by_object(tx, &pending.session_id, source)?
                .ok_or(IndexedSessionStoreError::CorruptEndpointState)?;
            if intent.state != EndpointAckIntentState::Pending
                || intent.remote_device != pending.recipient_device
                || receipt.0 != intent.message_id
                || receipt.1 != intent.remote_device
                || intent
                    .immutable_ack_bytes
                    .as_deref()
                    .is_some_and(|bytes| bytes != pending.immutable_envelope_bytes.as_slice())
            {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
            let changed = tx.execute(
                "UPDATE endpoint_ack_intents SET immutable_ack_bytes = ?1
                 WHERE session_id = ?2 AND object_digest = ?3 AND state = 0
                   AND (immutable_ack_bytes IS NULL OR immutable_ack_bytes = ?1)",
                params![
                    pending.immutable_envelope_bytes.as_slice(),
                    pending.session_id.as_slice(),
                    source.as_slice()
                ],
            )?;
            if changed != 1 {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
        }
    }
    Ok(())
}

fn validate_committed_outbound(
    conn: &Connection,
    state: &ProtectedSessionState,
    row: &EndpointOutbound,
) -> Result<(), IndexedSessionStoreError> {
    if row.session_id != state.binding.session_id
        || row.recipient_device != *remote_device_for_binding(&state.binding)
    {
        return Err(IndexedSessionStoreError::OutboundBindingMismatch);
    }
    let envelope = Envelope::unpack(&row.immutable_envelope_bytes)
        .ok_or(IndexedSessionStoreError::InvalidEndpointEnvelope)?;
    let direction = state.binding.local_role.outbound_direction();
    let expected_route = derive_route_tag(
        &state.ratchets.root,
        envelope.created_at,
        row.ratchet_index,
        envelope.env_type,
        direction,
    )
    .map_err(|_| IndexedSessionStoreError::OutboundBindingMismatch)?;
    let ratchet_next = match row.kind {
        EndpointOutboundKind::Message => state.ratchets.message_send.next_index,
        EndpointOutboundKind::Ack => state.ratchets.ack_send.next_index,
    };
    if envelope.flags != OUTBOUND_FLAGS
        || envelope.message_id != row.message_id
        || envelope.routing_tag != expected_route
        || envelope.dest_device_hint
            != endpoint_device_hint(remote_device_for_binding(&state.binding))
        || envelope.created_at < state.binding.created_at_ms
        || envelope.expires_at > state.binding.expires_at_ms
        || !endpoint_time_window_valid(
            envelope.created_at,
            envelope.expires_at,
            envelope.created_at,
        )
        || envelope.hop_limit != OUTBOUND_HOP_LIMIT
        || envelope.replication_budget != OUTBOUND_REPLICATION_BUDGET
        || envelope.anti_replay_nonce == [0; 12]
        || !envelope.ratchet_header_ciphertext.is_empty()
        || !envelope.verify(local_device_for_binding(&state.binding))
        || authenticated_object_digest(&envelope) != row.object_digest
        || parse_indexed_message_header(&envelope.message_ciphertext)
            .map_err(|_| IndexedSessionStoreError::OutboundBindingMismatch)?
            != row.ratchet_index
        || ratchet_next <= row.ratchet_index as u64
        || (row.kind == EndpointOutboundKind::Ack
            && envelope.message_ciphertext.len()
                != crate::atsam_indexed_session::ACK_SEALED_WIRE_LEN)
    {
        return Err(IndexedSessionStoreError::OutboundBindingMismatch);
    }

    let details: EndpointOutboxDetailsDbRow = conn.query_row(
        "SELECT source_ack_intent, ack_nonce, seal_nonce, anti_replay_nonce, session_generation
         FROM endpoint_outbox WHERE session_id = ?1 AND object_digest = ?2",
        params![row.session_id.as_slice(), row.object_digest.as_slice()],
        |db_row| {
            Ok((
                db_row.get(0)?,
                db_row.get(1)?,
                db_row.get(2)?,
                db_row.get(3)?,
                db_row.get(4)?,
            ))
        },
    )?;
    if details.2.as_slice()
        != &envelope.message_ciphertext[crate::atsam_indexed_session::INDEXED_SEALED_HEADER_LEN - 12
            ..crate::atsam_indexed_session::INDEXED_SEALED_HEADER_LEN]
        || details.3.as_slice() != envelope.anti_replay_nonce
        || details.4 < 0
        || details.4 as u64 > state.generation
    {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    match row.kind {
        EndpointOutboundKind::Message => {
            if details.0.is_some()
                || details.1.is_some()
                || self_delivery_state_in_connection(
                    conn,
                    &row.session_id,
                    &row.message_id,
                    &row.recipient_device,
                )?
                .is_none()
            {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
        }
        EndpointOutboundKind::Ack => {
            let source: [u8; 32] = exact_array(
                details
                    .0
                    .as_deref()
                    .ok_or(IndexedSessionStoreError::OutboundBindingMismatch)?,
            )?;
            let ack_nonce: [u8; 12] = exact_array(
                details
                    .1
                    .as_deref()
                    .ok_or(IndexedSessionStoreError::OutboundBindingMismatch)?,
            )?;
            if ack_nonce == [0; 12] {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
            let intent = committed_ack_intent(conn, &row.session_id, &source)?;
            let receipt = endpoint_receipt_by_object(conn, &row.session_id, &source)?
                .ok_or(IndexedSessionStoreError::CorruptEndpointState)?;
            let expected_state = match row.state {
                EndpointOutboxState::Prepared => EndpointAckIntentState::Pending,
                EndpointOutboxState::Queued => EndpointAckIntentState::Queued,
            };
            if intent.remote_device != row.recipient_device
                || receipt.0 != intent.message_id
                || receipt.1 != intent.remote_device
                || intent.state != expected_state
                || intent.immutable_ack_bytes.as_deref()
                    != Some(row.immutable_envelope_bytes.as_slice())
            {
                return Err(IndexedSessionStoreError::OutboundBindingMismatch);
            }
        }
    }
    Ok(())
}

fn self_delivery_state_in_connection(
    conn: &Connection,
    session_id: &[u8; 32],
    message_id: &[u8; 16],
    recipient_device: &[u8; 32],
) -> Result<Option<EndpointDeliveryState>, IndexedSessionStoreError> {
    let raw: Option<i64> = conn
        .query_row(
            "SELECT delivery_state FROM endpoint_outstanding_messages
             WHERE session_id = ?1 AND message_id = ?2 AND recipient_device = ?3",
            params![
                session_id.as_slice(),
                message_id.as_slice(),
                recipient_device.as_slice()
            ],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|value| {
        u8::try_from(value)
            .map_err(|_| IndexedSessionStoreError::CorruptEndpointState)
            .and_then(EndpointDeliveryState::from_u8)
    })
    .transpose()
}

fn endpoint_receipt_by_object(
    conn: &Connection,
    session_id: &[u8; 32],
    object_digest: &[u8; 32],
) -> Result<Option<EndpointReceiptIdentity>, IndexedSessionStoreError> {
    let raw: Option<(Vec<u8>, Vec<u8>, i64)> = conn
        .query_row(
            "SELECT message_id, sender_device, session_generation
             FROM endpoint_receipts WHERE session_id = ?1 AND object_digest = ?2",
            params![session_id.as_slice(), object_digest.as_slice()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let Some((message_id, sender_device, generation)) = raw else {
        return Ok(None);
    };
    if generation < 0 {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    Ok(Some((
        exact_array(&message_id)?,
        exact_array(&sender_device)?,
        generation as u64,
    )))
}

fn self_delivery_state_in_tx(
    tx: &Transaction<'_>,
    session_id: &[u8; 32],
    message_id: &[u8; 16],
    recipient_device: &[u8; 32],
) -> Result<Option<EndpointDeliveryState>, IndexedSessionStoreError> {
    let raw: Option<i64> = tx
        .query_row(
            "SELECT delivery_state FROM endpoint_outstanding_messages
             WHERE session_id = ?1 AND message_id = ?2 AND recipient_device = ?3",
            params![
                session_id.as_slice(),
                message_id.as_slice(),
                recipient_device.as_slice()
            ],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|value| {
        u8::try_from(value)
            .map_err(|_| IndexedSessionStoreError::CorruptEndpointState)
            .and_then(EndpointDeliveryState::from_u8)
    })
    .transpose()
}

fn endpoint_ack_receipt(
    tx: &Transaction<'_>,
    session_id: &[u8; 32],
    object_digest: &[u8; 32],
) -> Result<Option<AckReceiptIdentity>, IndexedSessionStoreError> {
    let raw: Option<(Vec<u8>, Vec<u8>, Vec<u8>)> = tx
        .query_row(
            "SELECT outer_message_id, remote_device, acked_message_id
             FROM endpoint_ack_receipts WHERE session_id = ?1 AND object_digest = ?2",
            params![session_id.as_slice(), object_digest.as_slice()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    raw.map(|(outer_message, remote, acked)| {
        Ok(AckReceiptIdentity {
            outer_message_id: exact_array(&outer_message)?,
            remote_device: exact_array(&remote)?,
            acked_message_id: exact_array(&acked)?,
        })
    })
    .transpose()
}

fn ack_nonce_object(
    tx: &Transaction<'_>,
    session_id: &[u8; 32],
    remote_device: &[u8; 32],
    ack_nonce: &[u8; 12],
) -> Result<Option<[u8; 32]>, IndexedSessionStoreError> {
    let raw: Option<Vec<u8>> = tx
        .query_row(
            "SELECT object_digest FROM endpoint_ack_receipts
             WHERE session_id = ?1 AND remote_device = ?2 AND ack_nonce = ?3",
            params![
                session_id.as_slice(),
                remote_device.as_slice(),
                ack_nonce.as_slice()
            ],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|value| exact_array(&value)).transpose()
}

fn insert_pending_ack_acceptance(
    tx: &Transaction<'_>,
    binding: &IndexedSessionBinding,
    pending: &PendingAckAcceptance,
) -> Result<(), IndexedSessionStoreError> {
    if pending.session_id != binding.session_id
        || pending.remote_device != *remote_device_for_binding(binding)
        || !matches!(pending.status, 1 | 2)
        || pending.created_at_ms > i64::MAX as u64
        || pending.public_generation > i64::MAX as u64
    {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let metadata_generation: i64 = tx.query_row(
        "SELECT generation FROM indexed_session_heads WHERE session_id = ?1",
        params![pending.session_id.as_slice()],
        |row| row.get(0),
    )?;
    if metadata_generation < 0 || metadata_generation as u64 != pending.public_generation {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    let existing_state = self_delivery_state_in_tx(
        tx,
        &pending.session_id,
        &pending.acked_message_id,
        &pending.remote_device,
    )?
    .ok_or(IndexedSessionStoreError::AckOutstandingMismatch)?;
    let target = EndpointDeliveryState::from_u8(pending.status)?;
    let final_state = std::cmp::max(existing_state, target);
    if let Some(existing_object) = ack_nonce_object(
        tx,
        &pending.session_id,
        &pending.remote_device,
        &pending.ack_nonce,
    )? {
        if existing_object != pending.object_digest {
            return Err(IndexedSessionStoreError::AckNonceConflict);
        }
    }
    if endpoint_ack_receipt(tx, &pending.session_id, &pending.object_digest)?.is_none() {
        tx.execute(
            "INSERT INTO endpoint_ack_receipts
             (session_id, object_digest, outer_message_id, remote_device,
              acked_message_id, status, ack_nonce, created_at_ms, session_generation)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                pending.session_id.as_slice(),
                pending.object_digest.as_slice(),
                pending.outer_message_id.as_slice(),
                pending.remote_device.as_slice(),
                pending.acked_message_id.as_slice(),
                pending.status,
                pending.ack_nonce.as_slice(),
                pending.created_at_ms as i64,
                pending.public_generation as i64,
            ],
        )?;
    }
    let identity = endpoint_ack_receipt(tx, &pending.session_id, &pending.object_digest)?
        .ok_or(IndexedSessionStoreError::CorruptEndpointState)?;
    if identity.outer_message_id != pending.outer_message_id
        || identity.remote_device != pending.remote_device
        || identity.acked_message_id != pending.acked_message_id
    {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    let changed = tx.execute(
        "UPDATE endpoint_outstanding_messages SET delivery_state = ?1
         WHERE session_id = ?2 AND message_id = ?3 AND recipient_device = ?4
           AND delivery_state <= ?1",
        params![
            final_state as u8,
            pending.session_id.as_slice(),
            pending.acked_message_id.as_slice(),
            pending.remote_device.as_slice()
        ],
    )?;
    if changed != 1 {
        return Err(IndexedSessionStoreError::AckOutstandingMismatch);
    }
    Ok(())
}

fn endpoint_logical_object(
    tx: &Transaction<'_>,
    session_id: &[u8; 32],
    sender_device: &[u8; 32],
    message_id: &[u8; 16],
) -> Result<Option<[u8; 32]>, IndexedSessionStoreError> {
    let raw: Option<Vec<u8>> = tx
        .query_row(
            "SELECT object_digest FROM endpoint_receipts
             WHERE session_id = ?1 AND sender_device = ?2 AND message_id = ?3",
            params![
                session_id.as_slice(),
                sender_device.as_slice(),
                message_id.as_slice()
            ],
            |row| row.get(0),
        )
        .optional()?;
    raw.map(|value| exact_array(&value)).transpose()
}

fn ensure_exact_committed_object(
    tx: &Transaction<'_>,
    session_id: &[u8; 32],
    object_digest: &[u8; 32],
    message_id: &[u8; 16],
    sender_device: &[u8; 32],
) -> Result<(), IndexedSessionStoreError> {
    let Some((existing_message, existing_sender, _)) =
        endpoint_receipt_by_object(tx, session_id, object_digest)?
    else {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    };
    if existing_message != *message_id || existing_sender != *sender_device {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    let logical = endpoint_logical_object(tx, session_id, sender_device, message_id)?
        .ok_or(IndexedSessionStoreError::CorruptEndpointState)?;
    if logical != *object_digest {
        return Err(IndexedSessionStoreError::LogicalMessageConflict);
    }
    Ok(())
}

fn insert_pending_acceptance(
    tx: &Transaction<'_>,
    binding: &IndexedSessionBinding,
    pending: &PendingAcceptance,
) -> Result<(), IndexedSessionStoreError> {
    if pending.session_id != binding.session_id
        || pending.sender_device != *remote_device_for_binding(binding)
        || !matches!(pending.ack_status, 1 | 2)
        || pending.sealed_local_inbox_row.len() < 1 + 12 + 16
        || pending.sealed_local_inbox_row.len() > MAX_SEALED_LOCAL_ROW_BYTES
        || pending.created_at_ms
            > pending
                .received_at_ms
                .saturating_add(MAX_ENDPOINT_FUTURE_SKEW_MS)
        || pending.created_at_ms > i64::MAX as u64
        || pending.received_at_ms > i64::MAX as u64
        || pending.public_generation > i64::MAX as u64
    {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let metadata_generation: i64 = tx.query_row(
        "SELECT generation FROM indexed_session_heads WHERE session_id = ?1",
        params![pending.session_id.as_slice()],
        |row| row.get(0),
    )?;
    if metadata_generation < 0 || metadata_generation as u64 != pending.public_generation {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    if let Some(existing) = endpoint_logical_object(
        tx,
        &pending.session_id,
        &pending.sender_device,
        &pending.message_id,
    )? {
        if existing != pending.object_digest {
            return Err(IndexedSessionStoreError::LogicalMessageConflict);
        }
    }

    if endpoint_receipt_by_object(tx, &pending.session_id, &pending.object_digest)?.is_none() {
        tx.execute(
            "INSERT INTO endpoint_receipts
             (session_id, object_digest, message_id, sender_device, session_generation)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                pending.session_id.as_slice(),
                pending.object_digest.as_slice(),
                pending.message_id.as_slice(),
                pending.sender_device.as_slice(),
                pending.public_generation as i64,
            ],
        )?;
        tx.execute(
            "INSERT INTO endpoint_inbox
             (session_id, object_digest, message_id, sender_device, created_at_ms,
              received_at_ms, sealed_local_row)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                pending.session_id.as_slice(),
                pending.object_digest.as_slice(),
                pending.message_id.as_slice(),
                pending.sender_device.as_slice(),
                pending.created_at_ms as i64,
                pending.received_at_ms as i64,
                pending.sealed_local_inbox_row.as_slice(),
            ],
        )?;
        tx.execute(
            "INSERT INTO endpoint_ack_intents
             (session_id, object_digest, message_id, remote_device, status, state,
              immutable_ack_bytes)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, NULL)",
            params![
                pending.session_id.as_slice(),
                pending.object_digest.as_slice(),
                pending.message_id.as_slice(),
                pending.sender_device.as_slice(),
                pending.ack_status,
            ],
        )?;
    }
    ensure_exact_committed_object(
        tx,
        &pending.session_id,
        &pending.object_digest,
        &pending.message_id,
        &pending.sender_device,
    )?;
    let inbox: Option<EndpointInboxRecoveryDbRow> = tx
        .query_row(
            "SELECT message_id, sender_device, created_at_ms, received_at_ms,
                    sealed_local_row
             FROM endpoint_inbox WHERE session_id = ?1 AND object_digest = ?2",
            params![
                pending.session_id.as_slice(),
                pending.object_digest.as_slice()
            ],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()?;
    let Some((message, sender, created_at, received_at, sealed)) = inbox else {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    };
    if exact_array::<16>(&message)? != pending.message_id
        || exact_array::<32>(&sender)? != pending.sender_device
        || created_at != pending.created_at_ms as i64
        || received_at != pending.received_at_ms as i64
        || sealed != pending.sealed_local_inbox_row
    {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    let ack: Option<(Vec<u8>, Vec<u8>, i64, i64)> = tx
        .query_row(
            "SELECT message_id, remote_device, status, state
             FROM endpoint_ack_intents WHERE session_id = ?1 AND object_digest = ?2",
            params![
                pending.session_id.as_slice(),
                pending.object_digest.as_slice()
            ],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    let Some((message, remote, status, state)) = ack else {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    };
    if exact_array::<16>(&message)? != pending.message_id
        || exact_array::<32>(&remote)? != pending.sender_device
        || status != pending.ack_status as i64
        || !matches!(state, 0 | 1)
    {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    Ok(())
}

fn local_storage_key(root: &[u8; 32], session_id: &[u8; 32]) -> [u8; 32] {
    let hkdf = Hkdf::<Sha256>::new(None, root);
    let mut info = Vec::with_capacity(LOCAL_STORAGE_LABEL.len() + 1 + session_id.len());
    info.extend_from_slice(LOCAL_STORAGE_LABEL);
    info.push(0);
    info.extend_from_slice(session_id);
    let mut output = [0u8; 32];
    hkdf.expand(&info, &mut output)
        .expect("fixed local storage key length");
    info.zeroize();
    output
}

fn local_storage_aad(
    session_id: &[u8; 32],
    object_digest: &[u8; 32],
    message_id: &[u8; 16],
    sender_device: &[u8; 32],
) -> Vec<u8> {
    let mut aad = Vec::with_capacity(LOCAL_STORAGE_AAD_LABEL.len() + 1 + 32 + 32 + 16 + 32);
    aad.extend_from_slice(LOCAL_STORAGE_AAD_LABEL);
    aad.push(0);
    aad.extend_from_slice(session_id);
    aad.extend_from_slice(object_digest);
    aad.extend_from_slice(message_id);
    aad.extend_from_slice(sender_device);
    aad
}

fn seal_local_inbox_row(
    root: &[u8; 32],
    session_id: &[u8; 32],
    object_digest: &[u8; 32],
    message_id: &[u8; 16],
    sender_device: &[u8; 32],
    plaintext: &[u8],
) -> Result<Vec<u8>, IndexedSessionStoreError> {
    let mut key = local_storage_key(root, session_id);
    let aad = local_storage_aad(session_id, object_digest, message_id, sender_device);
    let mut nonce = [0u8; 12];
    OsRng.fill_bytes(&mut nonce);
    let result = ChaCha20Poly1305::new((&key).into())
        .encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: plaintext,
                aad: &aad,
            },
        )
        .map_err(|_| IndexedSessionStoreError::LocalInboxAuthenticationFailed);
    key.zeroize();
    let ciphertext = result?;
    let mut sealed = Vec::with_capacity(1 + nonce.len() + ciphertext.len());
    sealed.push(LOCAL_ROW_VERSION);
    sealed.extend_from_slice(&nonce);
    sealed.extend_from_slice(&ciphertext);
    Ok(sealed)
}

fn open_local_inbox_row(
    root: &[u8; 32],
    session_id: &[u8; 32],
    object_digest: &[u8; 32],
    message_id: &[u8; 16],
    sender_device: &[u8; 32],
    sealed: &[u8],
) -> Result<Vec<u8>, IndexedSessionStoreError> {
    if sealed.len() < 1 + 12 + 16
        || sealed.len() > MAX_SEALED_LOCAL_ROW_BYTES
        || sealed[0] != LOCAL_ROW_VERSION
    {
        return Err(IndexedSessionStoreError::CorruptEndpointState);
    }
    let mut key = local_storage_key(root, session_id);
    let aad = local_storage_aad(session_id, object_digest, message_id, sender_device);
    let result = ChaCha20Poly1305::new((&key).into()).decrypt(
        Nonce::from_slice(&sealed[1..13]),
        Payload {
            msg: &sealed[13..],
            aad: &aad,
        },
    );
    key.zeroize();
    result.map_err(|_| IndexedSessionStoreError::LocalInboxAuthenticationFailed)
}

fn put_protected_state(
    backend: &dyn ProtectedSessionBackend,
    account: &str,
    state: &ProtectedSessionState,
) -> Result<(), IndexedSessionStoreError> {
    let mut encoded = encode_protected_state(state)?;
    let result = backend.put(account, &encoded);
    encoded.zeroize();
    result
}

fn endpoints_for_direction(binding: &IndexedSessionBinding, direction: Direction) -> (&str, &str) {
    match direction {
        Direction::InitiatorToResponder => (
            binding.key.initiator_address.as_str(),
            binding.key.responder_address.as_str(),
        ),
        Direction::ResponderToInitiator => (
            binding.key.responder_address.as_str(),
            binding.key.initiator_address.as_str(),
        ),
    }
}

/// Compares the immutable PairInit-derived binding. Confirmation lifecycle and
/// response hash are intentionally excluded so replaying the exact signed
/// PairInit remains idempotent after a session has been confirmed.
fn same_initial_binding(
    existing: &IndexedSessionBinding,
    candidate: &IndexedSessionBinding,
) -> bool {
    existing.key == candidate.key
        && existing.session_id == candidate.session_id
        && existing.init_hash == candidate.init_hash
        && existing.transcript_hash == candidate.transcript_hash
        && existing.initiator_cert_digest == candidate.initiator_cert_digest
        && existing.responder_cert_digest == candidate.responder_cert_digest
        && existing.responder_prekey_bundle_digest == candidate.responder_prekey_bundle_digest
        && existing.signed_prekey_id == candidate.signed_prekey_id
        && existing.one_time_prekey_id == candidate.one_time_prekey_id
        && existing.created_at_ms == candidate.created_at_ms
        && existing.expires_at_ms == candidate.expires_at_ms
        && existing.local_role == candidate.local_role
        && candidate.lifecycle == SessionLifecycle::Provisional
        && candidate.response_hash.is_none()
}

fn initial_ratchets(binding: &IndexedSessionBinding, root: &[u8; 32]) -> SecretRatchets {
    let outbound = binding.local_role.outbound_direction();
    let inbound = binding.local_role.inbound_direction();
    let (out_sender, out_recipient) = endpoints_for_direction(binding, outbound);
    let (in_sender, in_recipient) = endpoints_for_direction(binding, inbound);
    let mut ack_root = ack_base_key(root);
    let result = SecretRatchets {
        root: *root,
        message_send: SendRatchet {
            next_index: 0,
            chain_key: initial_chain_key(root, out_sender, out_recipient),
        },
        ack_send: SendRatchet {
            next_index: 0,
            chain_key: initial_chain_key(&ack_root, out_sender, out_recipient),
        },
        message_receive: ReceiveRatchet {
            next_index: 0,
            chain_key: initial_chain_key(root, in_sender, in_recipient),
            skipped_keys: BTreeMap::new(),
        },
        ack_receive: ReceiveRatchet {
            next_index: 0,
            chain_key: initial_chain_key(&ack_root, in_sender, in_recipient),
            skipped_keys: BTreeMap::new(),
        },
    };
    ack_root.zeroize();
    result
}

fn prepare_receive_key(
    ratchet: &mut ReceiveRatchet,
    index: u32,
    sender: &str,
    recipient: &str,
) -> Result<[u8; 32], IndexedSessionStoreError> {
    let index_u64 = index as u64;
    if index_u64 < ratchet.next_index {
        return ratchet
            .skipped_keys
            .remove(&index)
            .ok_or(IndexedSessionStoreError::Replay);
    }
    let gap = index_u64 - ratchet.next_index;
    if gap > MAX_FORWARD_JUMP {
        return Err(IndexedSessionStoreError::ForwardJumpTooLarge);
    }
    let mut cursor = ratchet.next_index;
    while cursor < index_u64 {
        let skipped = message_key(&ratchet.chain_key, sender, recipient);
        ratchet.skipped_keys.insert(cursor as u32, skipped);
        ratchet.chain_key = advance_chain_key(&ratchet.chain_key);
        cursor += 1;
    }
    while ratchet.skipped_keys.len() > MAX_SKIPPED_KEYS {
        let Some(oldest) = ratchet.skipped_keys.keys().next().copied() else {
            break;
        };
        if let Some(mut evicted) = ratchet.skipped_keys.remove(&oldest) {
            evicted.zeroize();
        }
    }
    let candidate = message_key(&ratchet.chain_key, sender, recipient);
    ratchet.chain_key = advance_chain_key(&ratchet.chain_key);
    ratchet.next_index = index_u64 + 1;
    Ok(candidate)
}

fn record_key_digest(key: &IndexedSessionRecordKey) -> Result<[u8; 32], IndexedSessionStoreError> {
    if key.profile_id.as_slice() != PROFILE_ID
        || key.profile_id.len() > MAX_PROFILE_BYTES
        || key.initiator_address.len() > MAX_ADDRESS_BYTES
        || key.responder_address.len() > MAX_ADDRESS_BYTES
        || key.init_id == [0; 16]
    {
        return Err(IndexedSessionStoreError::InvalidBinding);
    }
    session_context(&key.initiator_address, &key.responder_address)
        .map_err(|_| IndexedSessionStoreError::InvalidBinding)?;
    let mut hasher = Sha256::new();
    hasher.update(RECORD_KEY_DOMAIN);
    hash_len_prefixed(&mut hasher, &key.profile_id);
    hash_len_prefixed(&mut hasher, key.initiator_address.as_bytes());
    hash_len_prefixed(&mut hasher, key.responder_address.as_bytes());
    hasher.update(key.initiator_device_ed25519);
    hasher.update(key.responder_device_ed25519);
    hasher.update(key.init_id);
    Ok(hasher.finalize().into())
}

fn binding_digest(binding: &IndexedSessionBinding) -> Result<[u8; 32], IndexedSessionStoreError> {
    binding.validate()?;
    let mut hasher = Sha256::new();
    hasher.update(BINDING_DIGEST_DOMAIN);
    hasher.update(record_key_digest(&binding.key)?);
    hasher.update(binding.session_id);
    hasher.update(binding.init_hash);
    hasher.update(binding.transcript_hash);
    hasher.update(binding.initiator_cert_digest);
    hasher.update(binding.responder_cert_digest);
    hasher.update(binding.responder_prekey_bundle_digest);
    hasher.update(binding.signed_prekey_id.to_be_bytes());
    hasher.update(binding.one_time_prekey_id.to_be_bytes());
    hasher.update(binding.created_at_ms.to_be_bytes());
    hasher.update(binding.expires_at_ms.to_be_bytes());
    hasher.update([binding.local_role as u8, binding.lifecycle as u8]);
    match binding.response_hash {
        Some(hash) => {
            hasher.update([1]);
            hasher.update(hash);
        }
        None => {
            hasher.update([0]);
        }
    }
    Ok(hasher.finalize().into())
}

fn hash_len_prefixed(hasher: &mut Sha256, value: &[u8]) {
    hasher.update((value.len() as u32).to_be_bytes());
    hasher.update(value);
}

#[derive(Debug, Clone, Copy)]
struct MetadataHead {
    binding_digest: [u8; 32],
    generation: u64,
}

struct MetadataInitOwner {
    record_key: [u8; 32],
    init_hash: [u8; 32],
}

fn metadata_head(
    tx: &Transaction<'_>,
    record_key: &[u8; 32],
) -> Result<Option<MetadataHead>, IndexedSessionStoreError> {
    let raw: Option<(Vec<u8>, i64)> = tx
        .query_row(
            "SELECT binding_digest, generation FROM indexed_session_heads
             WHERE record_key = ?1",
            params![record_key.as_slice()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((digest, generation)) = raw else {
        return Ok(None);
    };
    if digest.len() != 32 || generation < 0 {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let mut binding_digest = [0u8; 32];
    binding_digest.copy_from_slice(&digest);
    Ok(Some(MetadataHead {
        binding_digest,
        generation: generation as u64,
    }))
}

fn metadata_session_owner(
    tx: &Transaction<'_>,
    session_id: &[u8; 32],
) -> Result<Option<[u8; 32]>, IndexedSessionStoreError> {
    let raw: Option<Vec<u8>> = tx
        .query_row(
            "SELECT record_key FROM indexed_session_heads WHERE session_id = ?1",
            params![session_id.as_slice()],
            |row| row.get(0),
        )
        .optional()?;
    let Some(raw) = raw else {
        return Ok(None);
    };
    if raw.len() != 32 {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let mut result = [0u8; 32];
    result.copy_from_slice(&raw);
    Ok(Some(result))
}

fn metadata_init_owner(
    tx: &Transaction<'_>,
    init_id: &[u8; 16],
) -> Result<Option<MetadataInitOwner>, IndexedSessionStoreError> {
    let raw: Option<(Vec<u8>, Vec<u8>)> = tx
        .query_row(
            "SELECT record_key, init_hash FROM indexed_session_heads WHERE init_id = ?1",
            params![init_id.as_slice()],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((record_key, init_hash)) = raw else {
        return Ok(None);
    };
    if record_key.len() != 32 || init_hash.len() != 32 {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let mut owner = [0u8; 32];
    owner.copy_from_slice(&record_key);
    let mut digest = [0u8; 32];
    digest.copy_from_slice(&init_hash);
    Ok(Some(MetadataInitOwner {
        record_key: owner,
        init_hash: digest,
    }))
}

fn insert_metadata(
    tx: &Transaction<'_>,
    record_key: &[u8; 32],
    state: &ProtectedSessionState,
) -> Result<(), IndexedSessionStoreError> {
    let binding = &state.binding;
    let digest = binding_digest(binding)?;
    tx.execute(
        "INSERT INTO indexed_session_heads
         (record_key, binding_digest, profile_id, initiator_address,
          responder_address, initiator_device, responder_device, init_id,
          init_hash, session_id, generation, created_at_ms, expires_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
        params![
            record_key.as_slice(),
            digest.as_slice(),
            binding.key.profile_id.as_slice(),
            binding.key.initiator_address,
            binding.key.responder_address,
            binding.key.initiator_device_ed25519.as_slice(),
            binding.key.responder_device_ed25519.as_slice(),
            binding.key.init_id.as_slice(),
            binding.init_hash.as_slice(),
            binding.session_id.as_slice(),
            state.generation as i64,
            binding.created_at_ms as i64,
            binding.expires_at_ms as i64,
        ],
    )?;
    Ok(())
}

fn update_metadata(
    tx: &Transaction<'_>,
    record_key: &[u8; 32],
    state: &ProtectedSessionState,
) -> Result<(), IndexedSessionStoreError> {
    if state.generation > i64::MAX as u64 {
        return Err(IndexedSessionStoreError::IndexExhausted);
    }
    let digest = binding_digest(&state.binding)?;
    let changed = tx.execute(
        "UPDATE indexed_session_heads
         SET binding_digest = ?1, generation = ?2
         WHERE record_key = ?3",
        params![
            digest.as_slice(),
            state.generation as i64,
            record_key.as_slice()
        ],
    )?;
    if changed != 1 {
        return Err(IndexedSessionStoreError::NotFound);
    }
    Ok(())
}

fn ensure_record_key(
    binding: &IndexedSessionBinding,
    expected: &[u8; 32],
) -> Result<(), IndexedSessionStoreError> {
    if record_key_digest(&binding.key)? != *expected {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    Ok(())
}

fn reconcile_metadata(
    tx: &Transaction<'_>,
    metadata: Option<MetadataHead>,
    record_key: &[u8; 32],
    state: &ProtectedSessionState,
) -> Result<(), IndexedSessionStoreError> {
    let protected_digest = binding_digest(&state.binding)?;
    match metadata {
        None => insert_metadata(tx, record_key, state),
        Some(head) if head.generation > state.generation => {
            Err(IndexedSessionStoreError::RollbackDetected)
        }
        Some(head) if head.generation == state.generation => {
            if head.binding_digest != protected_digest {
                return Err(IndexedSessionStoreError::CorruptProtectedState);
            }
            Ok(())
        }
        Some(_) => update_metadata(tx, record_key, state),
    }
}

fn load_and_reconcile(
    tx: &Transaction<'_>,
    backend: &dyn ProtectedSessionBackend,
    account: &str,
    record_key: &[u8; 32],
) -> Result<ProtectedSessionState, IndexedSessionStoreError> {
    let metadata = metadata_head(tx, record_key)?;
    let mut encoded = backend.get(account)?.ok_or_else(|| {
        if metadata.is_some() {
            IndexedSessionStoreError::ProtectedStateMissing
        } else {
            IndexedSessionStoreError::NotFound
        }
    })?;
    let result = decode_protected_state(&encoded);
    encoded.zeroize();
    let state = result?;
    ensure_record_key(&state.binding, record_key)?;
    reconcile_metadata(tx, metadata, record_key, &state)?;
    Ok(state)
}

#[allow(clippy::too_many_arguments)]
fn write_mutation(
    tx: &Transaction<'_>,
    backend: &dyn ProtectedSessionBackend,
    account: &str,
    record_key: &[u8; 32],
    state: &ProtectedSessionState,
    #[cfg(test)] crash_after_protected_write: bool,
) -> Result<(), IndexedSessionStoreError> {
    let mut encoded = encode_protected_state(state)?;
    let result = backend.put(account, &encoded);
    encoded.zeroize();
    result?;
    #[cfg(test)]
    if crash_after_protected_write {
        return Err(IndexedSessionStoreError::InjectedCrashAfterProtectedWrite);
    }
    update_metadata(tx, record_key, state)
}

fn store_integrity_key(root: &[u8; 32], session_id: &[u8; 32]) -> [u8; 32] {
    let hkdf = Hkdf::<Sha256>::new(None, root);
    let mut info = Vec::with_capacity(STORE_INTEGRITY_LABEL.len() + 1 + session_id.len());
    info.extend_from_slice(STORE_INTEGRITY_LABEL);
    info.push(0);
    info.extend_from_slice(session_id);
    let mut output = [0u8; 32];
    hkdf.expand(&info, &mut output)
        .expect("fixed 32-byte store integrity key");
    info.zeroize();
    output
}

fn encode_protected_state(
    state: &ProtectedSessionState,
) -> Result<Vec<u8>, IndexedSessionStoreError> {
    state.binding.validate()?;
    if state.ratchets.message_receive.skipped_keys.len() > MAX_SKIPPED_KEYS
        || state.ratchets.ack_receive.skipped_keys.len() > MAX_SKIPPED_KEYS
        || usize::from(state.pending_acceptance.is_some())
            + usize::from(state.pending_ack_acceptance.is_some())
            + usize::from(state.pending_outbound.is_some())
            > 1
    {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let mut writer = BinaryWriter::new();
    writer.bytes(STORE_MAGIC);
    writer.u8(STORE_VERSION);
    writer.u64(state.generation);
    encode_binding(&mut writer, &state.binding)?;
    writer.bytes(&state.ratchets.root);
    encode_send_ratchet(&mut writer, &state.ratchets.message_send);
    encode_send_ratchet(&mut writer, &state.ratchets.ack_send);
    encode_receive_ratchet(&mut writer, &state.ratchets.message_receive)?;
    encode_receive_ratchet(&mut writer, &state.ratchets.ack_receive)?;
    encode_pending_acceptance(&mut writer, state.pending_acceptance.as_ref())?;
    encode_pending_ack_acceptance(&mut writer, state.pending_ack_acceptance.as_ref())?;
    encode_pending_outbound(&mut writer, state.pending_outbound.as_ref())?;
    let mut integrity_key = store_integrity_key(&state.ratchets.root, &state.binding.session_id);
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(&integrity_key)
        .map_err(|_| IndexedSessionStoreError::CorruptProtectedState)?;
    mac.update(&writer.value);
    writer.bytes(&mac.finalize().into_bytes());
    integrity_key.zeroize();
    Ok(writer.value)
}

fn decode_protected_state(
    encoded: &[u8],
) -> Result<ProtectedSessionState, IndexedSessionStoreError> {
    if encoded.len() < STORE_MAGIC.len() + 1 + 8 + 32 {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let content_len = encoded
        .len()
        .checked_sub(32)
        .ok_or(IndexedSessionStoreError::CorruptProtectedState)?;
    let (content, tag) = encoded.split_at(content_len);
    let mut reader = BinaryReader::new(content);
    if reader.take(STORE_MAGIC.len())? != STORE_MAGIC {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let version = reader.u8()?;
    if !matches!(
        version,
        LEGACY_STORE_VERSION | ACCEPTANCE_STORE_VERSION | STORE_VERSION
    ) {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let generation = reader.u64()?;
    let binding = decode_binding(&mut reader)?;
    binding.validate()?;
    let mut root = reader.array::<32>()?;
    let decoded_tail = (|| {
        let message_send = decode_send_ratchet(&mut reader)?;
        let ack_send = decode_send_ratchet(&mut reader)?;
        let message_receive = decode_receive_ratchet(&mut reader)?;
        let ack_receive = decode_receive_ratchet(&mut reader)?;
        let pending_acceptance = if version >= ACCEPTANCE_STORE_VERSION {
            decode_pending_acceptance(&mut reader, &binding)?
        } else {
            None
        };
        let pending_ack_acceptance = if version >= ACCEPTANCE_STORE_VERSION {
            decode_pending_ack_acceptance(&mut reader, &binding)?
        } else {
            None
        };
        let pending_outbound = if version == STORE_VERSION {
            decode_pending_outbound(&mut reader, &binding)?
        } else {
            None
        };
        Ok::<_, IndexedSessionStoreError>((
            message_send,
            ack_send,
            message_receive,
            ack_receive,
            pending_acceptance,
            pending_ack_acceptance,
            pending_outbound,
        ))
    })();
    let (
        message_send,
        ack_send,
        message_receive,
        ack_receive,
        pending_acceptance,
        pending_ack_acceptance,
        pending_outbound,
    ) = match decoded_tail {
        Ok(value) => value,
        Err(error) => {
            root.zeroize();
            return Err(error);
        }
    };
    if usize::from(pending_acceptance.is_some())
        + usize::from(pending_ack_acceptance.is_some())
        + usize::from(pending_outbound.is_some())
        > 1
    {
        root.zeroize();
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    if !reader.is_empty() {
        root.zeroize();
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let mut integrity_key = store_integrity_key(&root, &binding.session_id);
    let mut mac = match <Hmac<Sha256> as Mac>::new_from_slice(&integrity_key) {
        Ok(value) => value,
        Err(_) => {
            integrity_key.zeroize();
            root.zeroize();
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
    };
    mac.update(content);
    let verified = mac.verify_slice(tag).is_ok();
    integrity_key.zeroize();
    if !verified {
        root.zeroize();
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    Ok(ProtectedSessionState {
        generation,
        binding,
        ratchets: SecretRatchets {
            root,
            message_send,
            ack_send,
            message_receive,
            ack_receive,
        },
        pending_acceptance,
        pending_ack_acceptance,
        pending_outbound,
    })
}

fn encode_pending_acceptance(
    writer: &mut BinaryWriter,
    pending: Option<&PendingAcceptance>,
) -> Result<(), IndexedSessionStoreError> {
    let Some(pending) = pending else {
        writer.u8(0);
        return Ok(());
    };
    if pending.sealed_local_inbox_row.len() < 1 + 12 + 16
        || pending.sealed_local_inbox_row.len() > MAX_SEALED_LOCAL_ROW_BYTES
        || !matches!(pending.ack_status, 1 | 2)
        || pending.created_at_ms
            > pending
                .received_at_ms
                .saturating_add(MAX_ENDPOINT_FUTURE_SKEW_MS)
    {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    writer.u8(1);
    writer.bytes(&pending.session_id);
    writer.bytes(&pending.object_digest);
    writer.bytes(&pending.message_id);
    writer.bytes(&pending.sender_device);
    writer.length_prefixed_u32(&pending.sealed_local_inbox_row, MAX_SEALED_LOCAL_ROW_BYTES)?;
    writer.u8(pending.ack_status);
    writer.u64(pending.created_at_ms);
    writer.u64(pending.received_at_ms);
    writer.u64(pending.public_generation);
    Ok(())
}

fn decode_pending_acceptance(
    reader: &mut BinaryReader<'_>,
    binding: &IndexedSessionBinding,
) -> Result<Option<PendingAcceptance>, IndexedSessionStoreError> {
    match reader.u8()? {
        0 => Ok(None),
        1 => {
            let pending = PendingAcceptance {
                session_id: reader.array()?,
                object_digest: reader.array()?,
                message_id: reader.array()?,
                sender_device: reader.array()?,
                sealed_local_inbox_row: reader.length_prefixed_u32(MAX_SEALED_LOCAL_ROW_BYTES)?,
                ack_status: reader.u8()?,
                created_at_ms: reader.u64()?,
                received_at_ms: reader.u64()?,
                public_generation: reader.u64()?,
            };
            if pending.session_id != binding.session_id
                || pending.sender_device != *remote_device_for_binding(binding)
                || pending.sealed_local_inbox_row.len() < 1 + 12 + 16
                || !matches!(pending.ack_status, 1 | 2)
                || pending.created_at_ms
                    > pending
                        .received_at_ms
                        .saturating_add(MAX_ENDPOINT_FUTURE_SKEW_MS)
            {
                return Err(IndexedSessionStoreError::CorruptProtectedState);
            }
            Ok(Some(pending))
        }
        _ => Err(IndexedSessionStoreError::CorruptProtectedState),
    }
}

fn encode_pending_ack_acceptance(
    writer: &mut BinaryWriter,
    pending: Option<&PendingAckAcceptance>,
) -> Result<(), IndexedSessionStoreError> {
    let Some(pending) = pending else {
        writer.u8(0);
        return Ok(());
    };
    if !matches!(pending.status, 1 | 2) {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    writer.u8(1);
    writer.bytes(&pending.session_id);
    writer.bytes(&pending.object_digest);
    writer.bytes(&pending.outer_message_id);
    writer.bytes(&pending.remote_device);
    writer.bytes(&pending.acked_message_id);
    writer.u8(pending.status);
    writer.bytes(&pending.ack_nonce);
    writer.u64(pending.created_at_ms);
    writer.u64(pending.public_generation);
    Ok(())
}

fn decode_pending_ack_acceptance(
    reader: &mut BinaryReader<'_>,
    binding: &IndexedSessionBinding,
) -> Result<Option<PendingAckAcceptance>, IndexedSessionStoreError> {
    match reader.u8()? {
        0 => Ok(None),
        1 => {
            let pending = PendingAckAcceptance {
                session_id: reader.array()?,
                object_digest: reader.array()?,
                outer_message_id: reader.array()?,
                remote_device: reader.array()?,
                acked_message_id: reader.array()?,
                status: reader.u8()?,
                ack_nonce: reader.array()?,
                created_at_ms: reader.u64()?,
                public_generation: reader.u64()?,
            };
            if pending.session_id != binding.session_id
                || pending.remote_device != *remote_device_for_binding(binding)
                || !matches!(pending.status, 1 | 2)
            {
                return Err(IndexedSessionStoreError::CorruptProtectedState);
            }
            Ok(Some(pending))
        }
        _ => Err(IndexedSessionStoreError::CorruptProtectedState),
    }
}

fn encode_pending_outbound(
    writer: &mut BinaryWriter,
    pending: Option<&PendingOutbound>,
) -> Result<(), IndexedSessionStoreError> {
    let Some(pending) = pending else {
        writer.u8(0);
        return Ok(());
    };
    validate_pending_outbound_shape(pending)?;
    writer.u8(1);
    writer.u8(pending.kind as u8);
    writer.bytes(&pending.session_id);
    writer.bytes(&pending.object_digest);
    writer.bytes(&pending.message_id);
    writer.bytes(&pending.recipient_device);
    writer.u32(pending.ratchet_index);
    match pending.source_ack_intent {
        Some(value) => {
            writer.u8(1);
            writer.bytes(&value);
        }
        None => writer.u8(0),
    }
    match pending.ack_nonce {
        Some(value) => {
            writer.u8(1);
            writer.bytes(&value);
        }
        None => writer.u8(0),
    }
    writer.bytes(&pending.seal_nonce);
    writer.bytes(&pending.anti_replay_nonce);
    writer.length_prefixed_u32(
        &pending.immutable_envelope_bytes,
        MAX_PENDING_OUTBOUND_BYTES,
    )?;
    writer.u64(pending.public_generation);
    Ok(())
}

fn decode_pending_outbound(
    reader: &mut BinaryReader<'_>,
    binding: &IndexedSessionBinding,
) -> Result<Option<PendingOutbound>, IndexedSessionStoreError> {
    match reader.u8()? {
        0 => Ok(None),
        1 => {
            let kind = EndpointOutboundKind::from_u8(reader.u8()?)?;
            let session_id = reader.array()?;
            let object_digest = reader.array()?;
            let message_id = reader.array()?;
            let recipient_device = reader.array()?;
            let ratchet_index = reader.u32()?;
            let source_ack_intent = match reader.u8()? {
                0 => None,
                1 => Some(reader.array()?),
                _ => return Err(IndexedSessionStoreError::CorruptProtectedState),
            };
            let ack_nonce = match reader.u8()? {
                0 => None,
                1 => Some(reader.array()?),
                _ => return Err(IndexedSessionStoreError::CorruptProtectedState),
            };
            let pending = PendingOutbound {
                kind,
                session_id,
                object_digest,
                message_id,
                recipient_device,
                ratchet_index,
                source_ack_intent,
                ack_nonce,
                seal_nonce: reader.array()?,
                anti_replay_nonce: reader.array()?,
                immutable_envelope_bytes: reader.length_prefixed_u32(MAX_PENDING_OUTBOUND_BYTES)?,
                public_generation: reader.u64()?,
            };
            validate_pending_outbound_shape(&pending)?;
            if pending.session_id != binding.session_id
                || pending.recipient_device != *remote_device_for_binding(binding)
            {
                return Err(IndexedSessionStoreError::CorruptProtectedState);
            }
            Ok(Some(pending))
        }
        _ => Err(IndexedSessionStoreError::CorruptProtectedState),
    }
}

fn validate_pending_outbound_shape(
    pending: &PendingOutbound,
) -> Result<(), IndexedSessionStoreError> {
    if pending.message_id == [0; 16]
        || pending.seal_nonce == [0; 12]
        || pending.anti_replay_nonce == [0; 12]
        || pending.immutable_envelope_bytes.len() < crate::envelope::PREFIX_LEN
        || pending.immutable_envelope_bytes.len() > MAX_PENDING_OUTBOUND_BYTES
        || match pending.kind {
            EndpointOutboundKind::Message => {
                pending.source_ack_intent.is_some() || pending.ack_nonce.is_some()
            }
            EndpointOutboundKind::Ack => {
                pending.source_ack_intent.is_none()
                    || pending.ack_nonce.is_none()
                    || pending.ack_nonce == Some([0; 12])
            }
        }
    {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let envelope = Envelope::unpack(&pending.immutable_envelope_bytes)
        .ok_or(IndexedSessionStoreError::CorruptProtectedState)?;
    let expected_type = match pending.kind {
        EndpointOutboundKind::Message => EnvType::Message,
        EndpointOutboundKind::Ack => EnvType::Ack,
    };
    let sealed_index = parse_indexed_message_header(&envelope.message_ciphertext)
        .map_err(|_| IndexedSessionStoreError::CorruptProtectedState)?;
    if envelope.env_type != expected_type as u8
        || envelope.flags != OUTBOUND_FLAGS
        || envelope.message_id != pending.message_id
        || envelope.message_ciphertext[crate::atsam_indexed_session::INDEXED_SEALED_HEADER_LEN - 12
            ..crate::atsam_indexed_session::INDEXED_SEALED_HEADER_LEN]
            != pending.seal_nonce
        || envelope.anti_replay_nonce != pending.anti_replay_nonce
        || envelope.hop_limit != OUTBOUND_HOP_LIMIT
        || envelope.replication_budget != OUTBOUND_REPLICATION_BUDGET
        || !envelope.ratchet_header_ciphertext.is_empty()
        || sealed_index != pending.ratchet_index
        || authenticated_object_digest(&envelope) != pending.object_digest
    {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    Ok(())
}

fn encode_binding(
    writer: &mut BinaryWriter,
    binding: &IndexedSessionBinding,
) -> Result<(), IndexedSessionStoreError> {
    writer.length_prefixed(&binding.key.profile_id, MAX_PROFILE_BYTES)?;
    writer.length_prefixed(binding.key.initiator_address.as_bytes(), MAX_ADDRESS_BYTES)?;
    writer.length_prefixed(binding.key.responder_address.as_bytes(), MAX_ADDRESS_BYTES)?;
    writer.bytes(&binding.key.initiator_device_ed25519);
    writer.bytes(&binding.key.responder_device_ed25519);
    writer.bytes(&binding.key.init_id);
    writer.bytes(&binding.session_id);
    writer.bytes(&binding.init_hash);
    writer.bytes(&binding.transcript_hash);
    writer.bytes(&binding.initiator_cert_digest);
    writer.bytes(&binding.responder_cert_digest);
    writer.bytes(&binding.responder_prekey_bundle_digest);
    writer.u32(binding.signed_prekey_id);
    writer.u32(binding.one_time_prekey_id);
    writer.u64(binding.created_at_ms);
    writer.u64(binding.expires_at_ms);
    writer.u8(binding.local_role as u8);
    writer.u8(binding.lifecycle as u8);
    match binding.response_hash {
        Some(hash) => {
            writer.u8(1);
            writer.bytes(&hash);
        }
        None => writer.u8(0),
    }
    Ok(())
}

fn decode_binding(
    reader: &mut BinaryReader<'_>,
) -> Result<IndexedSessionBinding, IndexedSessionStoreError> {
    let profile_id = reader.length_prefixed(MAX_PROFILE_BYTES)?;
    let initiator_address = String::from_utf8(reader.length_prefixed(MAX_ADDRESS_BYTES)?)
        .map_err(|_| IndexedSessionStoreError::CorruptProtectedState)?;
    let responder_address = String::from_utf8(reader.length_prefixed(MAX_ADDRESS_BYTES)?)
        .map_err(|_| IndexedSessionStoreError::CorruptProtectedState)?;
    let initiator_device_ed25519 = reader.array::<32>()?;
    let responder_device_ed25519 = reader.array::<32>()?;
    let init_id = reader.array::<16>()?;
    let session_id = reader.array::<32>()?;
    let init_hash = reader.array::<32>()?;
    let transcript_hash = reader.array::<32>()?;
    let initiator_cert_digest = reader.array::<32>()?;
    let responder_cert_digest = reader.array::<32>()?;
    let responder_prekey_bundle_digest = reader.array::<32>()?;
    let signed_prekey_id = reader.u32()?;
    let one_time_prekey_id = reader.u32()?;
    let created_at_ms = reader.u64()?;
    let expires_at_ms = reader.u64()?;
    let local_role = LocalRole::from_u8(reader.u8()?)?;
    let lifecycle = SessionLifecycle::from_u8(reader.u8()?)?;
    let response_hash = match reader.u8()? {
        0 => None,
        1 => Some(reader.array::<32>()?),
        _ => return Err(IndexedSessionStoreError::CorruptProtectedState),
    };
    Ok(IndexedSessionBinding {
        key: IndexedSessionRecordKey {
            profile_id,
            initiator_address,
            responder_address,
            initiator_device_ed25519,
            responder_device_ed25519,
            init_id,
        },
        session_id,
        init_hash,
        transcript_hash,
        initiator_cert_digest,
        responder_cert_digest,
        responder_prekey_bundle_digest,
        signed_prekey_id,
        one_time_prekey_id,
        created_at_ms,
        expires_at_ms,
        local_role,
        lifecycle,
        response_hash,
    })
}

fn encode_send_ratchet(writer: &mut BinaryWriter, ratchet: &SendRatchet) {
    writer.u64(ratchet.next_index);
    writer.bytes(&ratchet.chain_key);
}

fn decode_send_ratchet(
    reader: &mut BinaryReader<'_>,
) -> Result<SendRatchet, IndexedSessionStoreError> {
    let next_index = reader.u64()?;
    if next_index > u32::MAX as u64 + 1 {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    Ok(SendRatchet {
        next_index,
        chain_key: reader.array::<32>()?,
    })
}

fn encode_receive_ratchet(
    writer: &mut BinaryWriter,
    ratchet: &ReceiveRatchet,
) -> Result<(), IndexedSessionStoreError> {
    if ratchet.next_index > u32::MAX as u64 + 1 || ratchet.skipped_keys.len() > MAX_SKIPPED_KEYS {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    writer.u64(ratchet.next_index);
    writer.bytes(&ratchet.chain_key);
    writer.u16(ratchet.skipped_keys.len() as u16);
    for (index, key) in &ratchet.skipped_keys {
        if *index as u64 >= ratchet.next_index {
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
        writer.u32(*index);
        writer.bytes(key);
    }
    Ok(())
}

fn decode_receive_ratchet(
    reader: &mut BinaryReader<'_>,
) -> Result<ReceiveRatchet, IndexedSessionStoreError> {
    let next_index = reader.u64()?;
    if next_index > u32::MAX as u64 + 1 {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let chain_key = reader.array::<32>()?;
    let count = reader.u16()? as usize;
    if count > MAX_SKIPPED_KEYS {
        return Err(IndexedSessionStoreError::CorruptProtectedState);
    }
    let mut skipped_keys = BTreeMap::new();
    for _ in 0..count {
        let index = reader.u32()?;
        if index as u64 >= next_index || skipped_keys.insert(index, reader.array::<32>()?).is_some()
        {
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
    }
    Ok(ReceiveRatchet {
        next_index,
        chain_key,
        skipped_keys,
    })
}

struct BinaryWriter {
    value: Vec<u8>,
}

impl BinaryWriter {
    fn new() -> Self {
        Self {
            value: Vec::with_capacity(1024),
        }
    }

    fn bytes(&mut self, value: &[u8]) {
        self.value.extend_from_slice(value);
    }

    fn u8(&mut self, value: u8) {
        self.value.push(value);
    }

    fn u16(&mut self, value: u16) {
        self.bytes(&value.to_be_bytes());
    }

    fn u32(&mut self, value: u32) {
        self.bytes(&value.to_be_bytes());
    }

    fn u64(&mut self, value: u64) {
        self.bytes(&value.to_be_bytes());
    }

    fn length_prefixed(
        &mut self,
        value: &[u8],
        maximum: usize,
    ) -> Result<(), IndexedSessionStoreError> {
        if value.len() > maximum || value.len() > u16::MAX as usize {
            return Err(IndexedSessionStoreError::InvalidBinding);
        }
        self.u16(value.len() as u16);
        self.bytes(value);
        Ok(())
    }

    fn length_prefixed_u32(
        &mut self,
        value: &[u8],
        maximum: usize,
    ) -> Result<(), IndexedSessionStoreError> {
        if value.len() > maximum || value.len() > u32::MAX as usize {
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
        self.u32(value.len() as u32);
        self.bytes(value);
        Ok(())
    }
}

struct BinaryReader<'a> {
    value: &'a [u8],
    offset: usize,
}

impl<'a> BinaryReader<'a> {
    fn new(value: &'a [u8]) -> Self {
        Self { value, offset: 0 }
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], IndexedSessionStoreError> {
        let end = self
            .offset
            .checked_add(count)
            .ok_or(IndexedSessionStoreError::CorruptProtectedState)?;
        if end > self.value.len() {
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
        let result = &self.value[self.offset..end];
        self.offset = end;
        Ok(result)
    }

    fn array<const N: usize>(&mut self) -> Result<[u8; N], IndexedSessionStoreError> {
        self.take(N)?
            .try_into()
            .map_err(|_| IndexedSessionStoreError::CorruptProtectedState)
    }

    fn u8(&mut self) -> Result<u8, IndexedSessionStoreError> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, IndexedSessionStoreError> {
        Ok(u16::from_be_bytes(self.array()?))
    }

    fn u32(&mut self) -> Result<u32, IndexedSessionStoreError> {
        Ok(u32::from_be_bytes(self.array()?))
    }

    fn u64(&mut self) -> Result<u64, IndexedSessionStoreError> {
        Ok(u64::from_be_bytes(self.array()?))
    }

    fn length_prefixed(&mut self, maximum: usize) -> Result<Vec<u8>, IndexedSessionStoreError> {
        let length = self.u16()? as usize;
        if length > maximum {
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
        Ok(self.take(length)?.to_vec())
    }

    fn length_prefixed_u32(&mut self, maximum: usize) -> Result<Vec<u8>, IndexedSessionStoreError> {
        let length = usize::try_from(self.u32()?)
            .map_err(|_| IndexedSessionStoreError::CorruptProtectedState)?;
        if length > maximum {
            return Err(IndexedSessionStoreError::CorruptProtectedState);
        }
        Ok(self.take(length)?.to_vec())
    }

    fn is_empty(&self) -> bool {
        self.offset == self.value.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ack::Ack;
    use crate::atsam_indexed_session::{
        ack_key_at_index, encode_signed_ack, message_key_at_index, seal_indexed_message_with_key,
        SignedAck,
    };
    use crate::identity::Identity;
    use crate::pair_init::device_certificate_hash;
    use crate::pair_init::{
        decode_init as decode_pair_init, decode_response as decode_pair_response,
    };
    use rand::rngs::StdRng;
    use rand::Error as RandError;
    use rand::SeedableRng;
    use serde_json::Value;
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Barrier, Mutex};
    use std::thread;
    use tempfile::tempdir;

    struct ScriptedCryptoRng {
        bytes: Vec<u8>,
        offset: usize,
    }

    impl ScriptedCryptoRng {
        fn outbound(message_id: [u8; 16], seal_nonce: [u8; 12], anti_replay: [u8; 12]) -> Self {
            let mut bytes = Vec::with_capacity(40);
            bytes.extend_from_slice(&message_id);
            bytes.extend_from_slice(&seal_nonce);
            bytes.extend_from_slice(&anti_replay);
            Self { bytes, offset: 0 }
        }

        fn ack(
            message_id: [u8; 16],
            seal_nonce: [u8; 12],
            anti_replay: [u8; 12],
            ack_nonce: [u8; 12],
        ) -> Self {
            let mut value = Self::outbound(message_id, seal_nonce, anti_replay);
            value.bytes.extend_from_slice(&ack_nonce);
            value
        }
    }

    impl RngCore for ScriptedCryptoRng {
        fn next_u32(&mut self) -> u32 {
            let mut value = [0u8; 4];
            self.fill_bytes(&mut value);
            u32::from_le_bytes(value)
        }

        fn next_u64(&mut self) -> u64 {
            let mut value = [0u8; 8];
            self.fill_bytes(&mut value);
            u64::from_le_bytes(value)
        }

        fn fill_bytes(&mut self, destination: &mut [u8]) {
            self.try_fill_bytes(destination)
                .expect("scripted RNG has enough bytes");
        }

        fn try_fill_bytes(&mut self, destination: &mut [u8]) -> Result<(), RandError> {
            let end = self.offset.saturating_add(destination.len());
            if end > self.bytes.len() {
                return Err(RandError::new(std::io::Error::new(
                    std::io::ErrorKind::UnexpectedEof,
                    "scripted RNG exhausted",
                )));
            }
            destination.copy_from_slice(&self.bytes[self.offset..end]);
            self.offset = end;
            Ok(())
        }
    }

    impl CryptoRng for ScriptedCryptoRng {}

    #[cfg(not(any(
        target_os = "macos",
        windows,
        all(target_os = "linux", target_env = "gnu")
    )))]
    #[test]
    fn unsupported_platform_backend_fails_closed_without_creating_metadata() {
        let temp = tempdir().unwrap();
        let expected =
            format!("protected session store unavailable: {PROTECTED_STORE_UNAVAILABLE}");

        let open_error = match IndexedSessionStore::open(temp.path()) {
            Ok(_) => panic!("unsupported platform unexpectedly opened a session store"),
            Err(error) => error,
        };
        assert_eq!(open_error.redacted_display(), expected);
        assert!(!temp.path().join(INDEXED_SESSION_METADATA_FILE).exists());

        let backend = PlatformProtectedSessionBackend {};
        let get_error = backend.get("account").unwrap_err();
        let put_error = backend.put("account", b"secret").unwrap_err();
        assert_eq!(get_error.redacted_display(), expected);
        assert_eq!(put_error.redacted_display(), expected);
        assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 0);
    }

    #[derive(Default)]
    struct MemoryProtectedBackend {
        values: Mutex<HashMap<String, Vec<u8>>>,
        fail_next_put: AtomicBool,
        put_count: AtomicUsize,
        fail_on_put: Mutex<Option<usize>>,
    }

    impl MemoryProtectedBackend {
        fn fail_next_put(&self) {
            self.fail_next_put.store(true, Ordering::SeqCst);
        }

        fn fail_nth_future_put(&self, offset: usize) {
            assert!(offset > 0);
            let target = self.put_count.load(Ordering::SeqCst) + offset;
            *self.fail_on_put.lock().expect("failure lock") = Some(target);
        }

        fn corrupt(&self, account: &str) {
            let mut values = self.values.lock().expect("memory backend lock");
            let value = values.get_mut(account).expect("protected value");
            let offset = value.len() / 2;
            value[offset] ^= 0x80;
        }
    }

    impl ProtectedSessionBackend for MemoryProtectedBackend {
        fn get(&self, account: &str) -> Result<Option<Vec<u8>>, IndexedSessionStoreError> {
            Ok(self
                .values
                .lock()
                .map_err(|_| IndexedSessionStoreError::ProtectedStore("test lock poisoned".into()))?
                .get(account)
                .cloned())
        }

        fn put(&self, account: &str, value: &[u8]) -> Result<(), IndexedSessionStoreError> {
            let put_number = self.put_count.fetch_add(1, Ordering::SeqCst) + 1;
            let scheduled_failure = {
                let mut fail_on_put = self.fail_on_put.lock().expect("failure lock");
                if *fail_on_put == Some(put_number) {
                    *fail_on_put = None;
                    true
                } else {
                    false
                }
            };
            if scheduled_failure || self.fail_next_put.swap(false, Ordering::SeqCst) {
                return Err(IndexedSessionStoreError::ProtectedStore(
                    "injected write failure".into(),
                ));
            }
            self.values
                .lock()
                .map_err(|_| IndexedSessionStoreError::ProtectedStore("test lock poisoned".into()))?
                .insert(account.to_owned(), value.to_vec());
            Ok(())
        }
    }

    fn session_id(init_hash: &[u8; 32]) -> [u8; 32] {
        session_id_from_init_hash(init_hash)
    }

    fn fixture_binding() -> IndexedSessionBinding {
        let init_hash = [0x41; 32];
        IndexedSessionBinding {
            key: IndexedSessionRecordKey {
                profile_id: PROFILE_ID.to_vec(),
                initiator_address: "rvn1qysluvwl5922yctzd0u9gpr06gn3k7ldfvecule0".into(),
                responder_address: "rvn1qyulwy7s5ezz20cy222zrw04rwds39uapqakqskn".into(),
                initiator_device_ed25519: [0x11; 32],
                responder_device_ed25519: [0x22; 32],
                init_id: [0x33; 16],
            },
            session_id: session_id(&init_hash),
            init_hash,
            transcript_hash: [0x42; 32],
            initiator_cert_digest: [0x43; 32],
            responder_cert_digest: [0x44; 32],
            responder_prekey_bundle_digest: [0x45; 32],
            signed_prekey_id: 7,
            one_time_prekey_id: 9,
            created_at_ms: 1_700_000_000_000,
            expires_at_ms: 1_700_086_400_000,
            local_role: LocalRole::Initiator,
            lifecycle: SessionLifecycle::Provisional,
            response_hash: None,
        }
    }

    fn open_test_store(path: &Path, backend: Arc<MemoryProtectedBackend>) -> IndexedSessionStore {
        IndexedSessionStore::open_with_backend(path, backend).expect("open test store")
    }

    fn pair_init_vector() -> (PairInit, PairResponse, [u8; 32]) {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../../shared-vectors/rvn1/atsam/pair_init_v1_001.json");
        let vector: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let init = decode_pair_init(
            &hex::decode(vector["expected"]["pair_init_wire_hex"].as_str().unwrap()).unwrap(),
        )
        .unwrap();
        let response = decode_pair_response(
            &hex::decode(
                vector["expected"]["pair_response_wire_hex"]
                    .as_str()
                    .unwrap(),
            )
            .unwrap(),
        )
        .unwrap();
        let root: [u8; 32] = hex::decode(
            vector["expected"]["provisional_k_root_hex"]
                .as_str()
                .unwrap(),
        )
        .unwrap()
        .try_into()
        .unwrap();
        (init, response, root)
    }

    fn vector_binding(init: &PairInit) -> IndexedSessionBinding {
        IndexedSessionBinding {
            key: IndexedSessionRecordKey {
                profile_id: PROFILE_ID.to_vec(),
                initiator_address: init.initiator_address.clone(),
                responder_address: init.responder_address.clone(),
                initiator_device_ed25519: init.initiator_device_ed_pub,
                responder_device_ed25519: init.responder_device_ed_pub,
                init_id: init.init_id,
            },
            session_id: pair_session_id(init).unwrap(),
            init_hash: pair_init_hash(init).unwrap(),
            transcript_hash: pair_transcript_hash(init).unwrap(),
            initiator_cert_digest: init.initiator_device_cert_hash,
            responder_cert_digest: init.responder_device_cert_hash,
            responder_prekey_bundle_digest: init.responder_prekey_bundle_hash,
            signed_prekey_id: init.signed_prekey_id,
            one_time_prekey_id: init.one_time_prekey_id,
            created_at_ms: init.created_at_ms,
            expires_at_ms: init.expires_at_ms,
            local_role: LocalRole::Initiator,
            lifecycle: SessionLifecycle::Provisional,
            response_hash: None,
        }
    }

    struct EndpointFixture {
        binding: IndexedSessionBinding,
        key: IndexedSessionRecordKey,
        root: [u8; 32],
        local_identity: Identity,
        local_certificate: DeviceCertificate,
        local_registry: DeviceRegistry,
        remote_identity: Identity,
        remote_certificate: DeviceCertificate,
        now_ms: u64,
    }

    fn endpoint_fixture() -> EndpointFixture {
        let local_identity = Identity::from_seed(&[0x11; 32]);
        let remote_identity = Identity::from_seed(&[0x22; 32]);
        let remote_user = Identity::from_seed(&[0x23; 32]);
        let now_ms = 1_700_000_100_000;
        let remote_certificate = DeviceCertificate::issue(
            &remote_user,
            remote_identity.public_key_bytes(),
            [0x24; 32],
            "remote-device",
            1_699_999_000_000,
            1_700_200_000_000,
            1,
        )
        .unwrap();
        let local_certificate = DeviceCertificate::issue(
            &local_identity,
            local_identity.public_key_bytes(),
            [0x14; 32],
            "local-device",
            1_699_999_000_000,
            1_700_200_000_000,
            1,
        )
        .unwrap();
        let mut local_registry = DeviceRegistry::default();
        local_registry
            .add(local_certificate.clone(), now_ms)
            .unwrap();
        let init_hash = [0x41; 32];
        let binding = IndexedSessionBinding {
            key: IndexedSessionRecordKey {
                profile_id: PROFILE_ID.to_vec(),
                initiator_address: local_identity.address(),
                responder_address: remote_user.address(),
                initiator_device_ed25519: local_identity.public_key_bytes(),
                responder_device_ed25519: remote_identity.public_key_bytes(),
                init_id: [0x33; 16],
            },
            session_id: session_id(&init_hash),
            init_hash,
            transcript_hash: [0x42; 32],
            initiator_cert_digest: device_certificate_hash(&local_certificate).unwrap(),
            responder_cert_digest: device_certificate_hash(&remote_certificate).unwrap(),
            responder_prekey_bundle_digest: [0x45; 32],
            signed_prekey_id: 7,
            one_time_prekey_id: 9,
            created_at_ms: 1_699_999_000_000,
            expires_at_ms: 1_700_200_000_000,
            local_role: LocalRole::Initiator,
            lifecycle: SessionLifecycle::Confirmed,
            response_hash: Some([0x46; 32]),
        };
        EndpointFixture {
            key: binding.key.clone(),
            binding,
            root: [0xA7; 32],
            local_identity,
            local_certificate,
            local_registry,
            remote_identity,
            remote_certificate,
            now_ms,
        }
    }

    fn authorized_local_device(fixture: &EndpointFixture) -> AuthorizedEndpointDevice<'_> {
        AuthorizedEndpointDevice::authorize(
            &fixture.local_certificate,
            &fixture.local_identity,
            &fixture.local_registry,
            fixture.now_ms,
        )
        .unwrap()
    }

    fn inbound_message_envelope(
        fixture: &EndpointFixture,
        index: u32,
        message_id: [u8; 16],
        plaintext: &[u8],
    ) -> Envelope {
        let direction = Direction::ResponderToInitiator;
        let created_at = fixture.now_ms + MAX_ENDPOINT_FUTURE_SKEW_MS;
        let key = message_key_at_index(
            &fixture.root,
            &fixture.key.initiator_address,
            &fixture.key.responder_address,
            direction,
            index,
        )
        .unwrap();
        let sealed = seal_indexed_message_with_key(
            &key,
            &fixture.key.initiator_address,
            &fixture.key.responder_address,
            direction,
            index,
            &message_id,
            plaintext,
            &[0xA0; 12],
        )
        .unwrap();
        let mut envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id,
            routing_tag: derive_route_tag(
                &fixture.root,
                created_at,
                index,
                EnvType::Message as u8,
                direction,
            )
            .unwrap(),
            dest_device_hint: 0,
            created_at,
            expires_at: created_at + 60_000,
            hop_limit: 8,
            replication_budget: 2,
            anti_replay_nonce: [0xA1; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: sealed,
            sender_authentication: vec![0; 64],
        };
        envelope.sign_with(&fixture.remote_identity);
        envelope
    }

    fn inbound_ack_envelope(
        fixture: &EndpointFixture,
        index: u32,
        outer_message_id: [u8; 16],
        acked_message_id: [u8; 16],
        status: u8,
        ack_nonce: [u8; 12],
    ) -> Envelope {
        let direction = Direction::ResponderToInitiator;
        let created_at = fixture.now_ms;
        let record = Ack {
            acked_message_id,
            status,
            ack_nonce,
            created_at,
        };
        let signed = SignedAck {
            signature: record.sign(&fixture.remote_identity),
            record,
        };
        let plaintext = encode_signed_ack(&signed).unwrap();
        let key = ack_key_at_index(
            &fixture.root,
            &fixture.key.initiator_address,
            &fixture.key.responder_address,
            direction,
            index,
        )
        .unwrap();
        let sealed = seal_indexed_message_with_key(
            &key,
            &fixture.key.initiator_address,
            &fixture.key.responder_address,
            direction,
            index,
            &outer_message_id,
            &plaintext,
            &[0xB0; 12],
        )
        .unwrap();
        let mut envelope = Envelope {
            env_type: EnvType::Ack as u8,
            flags: 0,
            message_id: outer_message_id,
            routing_tag: derive_route_tag(
                &fixture.root,
                created_at,
                index,
                EnvType::Ack as u8,
                direction,
            )
            .unwrap(),
            dest_device_hint: endpoint_device_hint(&fixture.key.initiator_device_ed25519),
            created_at,
            expires_at: created_at + 60_000,
            hop_limit: 8,
            replication_budget: 2,
            anti_replay_nonce: [0xB1; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: sealed,
            sender_authentication: vec![0; 64],
        };
        envelope.sign_with(&fixture.remote_identity);
        envelope
    }

    #[allow(clippy::too_many_arguments)]
    fn custom_inbound_ack_envelope(
        fixture: &EndpointFixture,
        index: u32,
        outer_message_id: [u8; 16],
        acked_message_id: [u8; 16],
        status: u8,
        ack_nonce: [u8; 12],
        inner_created_at: u64,
        inner_signer: Option<&Identity>,
    ) -> Envelope {
        let direction = Direction::ResponderToInitiator;
        let record = Ack {
            acked_message_id,
            status,
            ack_nonce,
            created_at: inner_created_at,
        };
        let mut plaintext = [0u8; crate::atsam_indexed_session::ACK_PLAINTEXT_LEN];
        plaintext[..16].copy_from_slice(&record.acked_message_id);
        plaintext[16] = status;
        plaintext[17..29].copy_from_slice(&record.ack_nonce);
        plaintext[29..37].copy_from_slice(&record.created_at.to_be_bytes());
        if let Some(signer) = inner_signer {
            plaintext[37..].copy_from_slice(&record.sign(signer));
        }
        let key = ack_key_at_index(
            &fixture.root,
            &fixture.key.initiator_address,
            &fixture.key.responder_address,
            direction,
            index,
        )
        .unwrap();
        let sealed = seal_indexed_message_with_key(
            &key,
            &fixture.key.initiator_address,
            &fixture.key.responder_address,
            direction,
            index,
            &outer_message_id,
            &plaintext,
            &[0xB0; 12],
        )
        .unwrap();
        let mut envelope = Envelope {
            env_type: EnvType::Ack as u8,
            flags: 0,
            message_id: outer_message_id,
            routing_tag: derive_route_tag(
                &fixture.root,
                fixture.now_ms,
                index,
                EnvType::Ack as u8,
                direction,
            )
            .unwrap(),
            dest_device_hint: endpoint_device_hint(&fixture.key.initiator_device_ed25519),
            created_at: fixture.now_ms,
            expires_at: fixture.now_ms + 60_000,
            hop_limit: 8,
            replication_budget: 2,
            anti_replay_nonce: [0xB1; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: sealed,
            sender_authentication: vec![0; 64],
        };
        envelope.sign_with(&fixture.remote_identity);
        envelope
    }

    #[test]
    fn crash_relaunch_preserves_send_and_authenticated_receive_state() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let key = binding.key.clone();
        let root = [0xA7; 32];
        {
            let mut store = open_test_store(&path, Arc::clone(&backend));
            store.create_session(binding.clone(), root).unwrap();
            let reservation = store.reserve_send_key(&key, RatchetLane::Message).unwrap();
            assert_eq!(reservation.index, 0);
            assert_eq!(
                reservation.key,
                message_key_at_index(
                    &root,
                    &key.initiator_address,
                    &key.responder_address,
                    Direction::InitiatorToResponder,
                    0,
                )
                .unwrap()
            );
        }
        {
            let mut reopened = open_test_store(&path, Arc::clone(&backend));
            assert_eq!(
                reopened
                    .reserve_send_key(&key, RatchetLane::Message)
                    .unwrap()
                    .index,
                1
            );
            let expected = message_key_at_index(
                &root,
                &key.initiator_address,
                &key.responder_address,
                Direction::ResponderToInitiator,
                2,
            )
            .unwrap();
            let authenticated = reopened
                .authenticate_receive(&key, RatchetLane::Message, 2, |candidate| {
                    (candidate == &expected).then_some("plaintext committed separately")
                })
                .unwrap();
            assert_eq!(authenticated, "plaintext committed separately");
        }
        let mut reopened = open_test_store(&path, backend);
        let expected_zero = message_key_at_index(
            &root,
            &key.initiator_address,
            &key.responder_address,
            Direction::ResponderToInitiator,
            0,
        )
        .unwrap();
        reopened
            .authenticate_receive(&key, RatchetLane::Message, 0, |candidate| {
                (candidate == &expected_zero).then_some(())
            })
            .unwrap();
        assert!(matches!(
            reopened.authenticate_receive(&key, RatchetLane::Message, 2, |_| Some(())),
            Err(IndexedSessionStoreError::Replay)
        ));
    }

    #[test]
    fn concurrent_reservations_are_unique_and_monotonic() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let key = binding.key.clone();
        let root = [0x91; 32];
        let mut creator = open_test_store(&path, Arc::clone(&backend));
        creator.create_session(binding, root).unwrap();
        drop(creator);

        const WORKERS: usize = 24;
        let barrier = Arc::new(Barrier::new(WORKERS));
        let mut stores = Vec::new();
        for _ in 0..WORKERS {
            stores.push(open_test_store(&path, Arc::clone(&backend)));
        }
        let mut handles = Vec::new();
        for mut store in stores {
            let barrier = Arc::clone(&barrier);
            let key = key.clone();
            handles.push(thread::spawn(move || {
                barrier.wait();
                let reservation = store.reserve_send_key(&key, RatchetLane::Message).unwrap();
                (reservation.index, reservation.key)
            }));
        }
        let mut reservations: Vec<_> = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect();
        reservations.sort_by_key(|(index, _)| *index);
        assert_eq!(
            reservations
                .iter()
                .map(|(index, _)| *index)
                .collect::<Vec<_>>(),
            (0..WORKERS as u32).collect::<Vec<_>>()
        );
        for (index, reserved) in reservations {
            assert_eq!(
                reserved,
                message_key_at_index(
                    &root,
                    &key.initiator_address,
                    &key.responder_address,
                    Direction::InitiatorToResponder,
                    index,
                )
                .unwrap()
            );
        }
    }

    #[test]
    fn forward_jump_over_256_and_failed_auth_do_not_advance() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let key = binding.key.clone();
        let root = [0x81; 32];
        let mut store = open_test_store(&path, backend);
        store.create_session(binding, root).unwrap();
        assert!(matches!(
            store.authenticate_receive(&key, RatchetLane::Message, 257, |_| Some(())),
            Err(IndexedSessionStoreError::ForwardJumpTooLarge)
        ));
        assert!(matches!(
            store.authenticate_receive::<(), _>(&key, RatchetLane::Message, 0, |_| None),
            Err(IndexedSessionStoreError::AuthenticationFailed)
        ));
        let expected = message_key_at_index(
            &root,
            &key.initiator_address,
            &key.responder_address,
            Direction::ResponderToInitiator,
            0,
        )
        .unwrap();
        store
            .authenticate_receive(&key, RatchetLane::Message, 0, |candidate| {
                (candidate == &expected).then_some(())
            })
            .unwrap();
    }

    #[test]
    fn skipped_key_cache_is_bounded_and_ack_lane_is_independent() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let key = binding.key.clone();
        let root = [0x71; 32];
        let mut store = open_test_store(&path, Arc::clone(&backend));
        store.create_session(binding, root).unwrap();
        let expected = message_key_at_index(
            &root,
            &key.initiator_address,
            &key.responder_address,
            Direction::ResponderToInitiator,
            256,
        )
        .unwrap();
        store
            .authenticate_receive(&key, RatchetLane::Message, 256, |candidate| {
                (candidate == &expected).then_some(())
            })
            .unwrap();
        let account = hex::encode(record_key_digest(&key).unwrap());
        let encoded = backend.get(&account).unwrap().unwrap();
        let state = decode_protected_state(&encoded).unwrap();
        assert_eq!(state.ratchets.message_receive.skipped_keys.len(), 256);
        assert_eq!(state.ratchets.ack_receive.skipped_keys.len(), 0);
        drop(state);

        let ack = store.reserve_send_key(&key, RatchetLane::Ack).unwrap();
        assert_eq!(ack.index, 0);
        assert_eq!(
            ack.key,
            ack_key_at_index(
                &root,
                &key.initiator_address,
                &key.responder_address,
                Direction::InitiatorToResponder,
                0,
            )
            .unwrap()
        );
    }

    #[test]
    fn corrupt_protected_blob_fails_closed_without_metadata_advance() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let key = binding.key.clone();
        let mut store = open_test_store(&path, Arc::clone(&backend));
        store.create_session(binding, [0x61; 32]).unwrap();
        let account = hex::encode(record_key_digest(&key).unwrap());
        backend.corrupt(&account);
        assert!(matches!(
            store.reserve_send_key(&key, RatchetLane::Message),
            Err(IndexedSessionStoreError::CorruptProtectedState)
        ));
        let generation: i64 = Connection::open(&path)
            .unwrap()
            .query_row("SELECT generation FROM indexed_session_heads", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(generation, 0);
    }

    #[test]
    fn protected_write_failure_rolls_back_without_consuming_index() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let key = binding.key.clone();
        let mut store = open_test_store(&path, Arc::clone(&backend));
        store.create_session(binding, [0x51; 32]).unwrap();
        backend.fail_next_put();
        assert!(matches!(
            store.reserve_send_key(&key, RatchetLane::Message),
            Err(IndexedSessionStoreError::ProtectedStore(_))
        ));
        assert_eq!(
            store
                .reserve_send_key(&key, RatchetLane::Message)
                .unwrap()
                .index,
            0
        );
    }

    #[test]
    fn crash_after_protected_write_fast_forwards_and_never_reuses_key() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let key = binding.key.clone();
        let mut store = open_test_store(&path, Arc::clone(&backend));
        store.create_session(binding, [0x31; 32]).unwrap();
        store.inject_crash_after_next_protected_write();
        assert!(matches!(
            store.reserve_send_key(&key, RatchetLane::Message),
            Err(IndexedSessionStoreError::InjectedCrashAfterProtectedWrite)
        ));
        drop(store);

        let mut reopened = open_test_store(&path, backend);
        let reservation = reopened
            .reserve_send_key(&key, RatchetLane::Message)
            .unwrap();
        assert_eq!(reservation.index, 1, "index zero was burned, never reused");
    }

    #[test]
    fn exact_pairinit_is_idempotent_but_init_id_hash_conflict_is_rejected() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let mut store = open_test_store(&path, backend);
        store.create_session(binding.clone(), [0x21; 32]).unwrap();
        store.create_session(binding.clone(), [0x21; 32]).unwrap();

        let mut conflict = binding;
        conflict.init_hash[0] ^= 1;
        conflict.session_id = session_id(&conflict.init_hash);
        assert!(matches!(
            store.create_session(conflict.clone(), [0x21; 32]),
            Err(IndexedSessionStoreError::InitIdConflict)
        ));

        // The init ID is replay protection for this local identity, not merely
        // for one address/device tuple. Changing a device key must not evade
        // the signed-PairInit conflict check.
        conflict.key.responder_device_ed25519[0] ^= 1;
        assert!(matches!(
            store.create_session(conflict, [0x21; 32]),
            Err(IndexedSessionStoreError::InitIdConflict)
        ));
    }

    #[test]
    fn confirmation_is_monotonic_and_idempotent() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let key = binding.key.clone();
        let mut store = open_test_store(&path, backend);
        store.create_session(binding.clone(), [0x12; 32]).unwrap();
        store.confirm_session(&key, [0x99; 32]).unwrap();
        store.confirm_session(&key, [0x99; 32]).unwrap();
        store
            .create_session(binding, [0x12; 32])
            .expect("exact PairInit replay remains idempotent after confirmation");
        assert!(matches!(
            store.confirm_session(&key, [0x98; 32]),
            Err(IndexedSessionStoreError::ConfirmationConflict)
        ));
    }

    #[test]
    fn verified_pairresponse_confirmation_rejects_forgery_mismatch_and_staleness() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let (init, response, root) = pair_init_vector();
        let binding = vector_binding(&init);
        let key = binding.key.clone();
        let mut store = open_test_store(&path, backend);
        store.create_session(binding, root).unwrap();
        let now = response.created_at_ms + 1;

        let mut bad_tag = response.clone();
        bad_tag.confirmation_tag[0] ^= 1;
        assert!(matches!(
            store.confirm_verified_pair_response(&key, &init, &bad_tag, now),
            Err(IndexedSessionStoreError::PairInit(
                PairInitError::ConfirmationMismatch
            ))
        ));
        let mut bad_signature = response.clone();
        bad_signature.signature[0] ^= 1;
        assert!(matches!(
            store.confirm_verified_pair_response(&key, &init, &bad_signature, now),
            Err(IndexedSessionStoreError::PairInit(
                PairInitError::BadSignature
            ))
        ));
        let mut wrong_init = init.clone();
        wrong_init.init_id[0] ^= 1;
        assert!(matches!(
            store.confirm_verified_pair_response(&key, &wrong_init, &response, now),
            Err(IndexedSessionStoreError::BindingConflict)
        ));
        assert!(matches!(
            store.confirm_verified_pair_response(&key, &init, &response, response.expires_at_ms,),
            Err(IndexedSessionStoreError::PairInit(
                PairInitError::ConfirmationMismatch
            ))
        ));

        store
            .confirm_verified_pair_response(&key, &init, &response, now)
            .unwrap();
        store
            .confirm_verified_pair_response(&key, &init, &response, now)
            .unwrap();
        let mut different = response.clone();
        different.expires_at_ms -= 1;
        assert!(store
            .confirm_verified_pair_response(&key, &init, &different, now)
            .is_err());
    }

    #[test]
    fn endpoint_message_flags_zero_skew_hint_replay_and_local_sealing() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let mut store = open_test_store(&path, Arc::clone(&backend));
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let envelope =
            inbound_message_envelope(&fixture, 0, [0xC0; 16], b"future-skew\taccepted\n");
        assert_eq!(envelope.flags, 0);
        assert_eq!(envelope.dest_device_hint, 0);
        let packed = envelope.pack();
        let accepted = store
            .accept_message_envelope(
                &fixture.key,
                &packed,
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
        let digest = match accepted {
            EndpointAcceptance::Committed {
                object_digest,
                plaintext,
                ..
            } => {
                assert_eq!(plaintext, b"future-skew\taccepted\n");
                object_digest
            }
            _ => panic!("first acceptance must commit"),
        };
        assert!(matches!(
            store
                .accept_message_envelope(
                    &fixture.key,
                    &packed,
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                )
                .unwrap(),
            EndpointAcceptance::Duplicate { .. }
        ));
        let inbox = store
            .load_endpoint_inbox(&fixture.key, &digest)
            .unwrap()
            .unwrap();
        assert_eq!(inbox.plaintext, b"future-skew\taccepted\n");
        assert_eq!(store.pending_endpoint_ack_intents().unwrap().len(), 1);

        store
            .conn
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
            .unwrap();
        let sqlite = std::fs::read(&path).unwrap();
        assert!(!sqlite
            .windows(inbox.plaintext.len())
            .any(|window| window == inbox.plaintext));
        for protected in backend.values.lock().unwrap().values() {
            assert!(!protected
                .windows(inbox.plaintext.len())
                .any(|window| window == inbox.plaintext));
        }
    }

    #[test]
    fn endpoint_message_negatives_do_not_advance_or_create_ack() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();

        let mut wrong_route = inbound_message_envelope(&fixture, 0, [0xD0; 16], b"valid");
        wrong_route.routing_tag[0] ^= 1;
        wrong_route.sign_with(&fixture.remote_identity);
        assert!(matches!(
            store.accept_message_envelope(
                &fixture.key,
                &wrong_route.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::RouteTagMismatch)
        ));

        let mut wrong_hint = inbound_message_envelope(&fixture, 0, [0xD1; 16], b"valid");
        wrong_hint.dest_device_hint =
            endpoint_device_hint(&fixture.key.initiator_device_ed25519) ^ 1;
        assert!(matches!(
            store.accept_message_envelope(
                &fixture.key,
                &wrong_hint.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::DeviceHintMismatch)
        ));

        let mut tampered = inbound_message_envelope(&fixture, 0, [0xD2; 16], b"valid");
        let last = tampered.message_ciphertext.len() - 1;
        tampered.message_ciphertext[last] ^= 1;
        tampered.sign_with(&fixture.remote_identity);
        assert!(matches!(
            store.accept_message_envelope(
                &fixture.key,
                &tampered.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::AuthenticationFailed)
        ));

        let invalid_text = inbound_message_envelope(&fixture, 0, [0xD3; 16], b"bad\0text");
        assert!(matches!(
            store.accept_message_envelope(
                &fixture.key,
                &invalid_text.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::InvalidEndpointPayload)
        ));
        assert!(store.pending_endpoint_ack_intents().unwrap().is_empty());

        let valid = inbound_message_envelope(&fixture, 0, [0xD4; 16], b"ratchet-not-advanced");
        store
            .accept_message_envelope(
                &fixture.key,
                &valid.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
    }

    #[test]
    fn endpoint_time_text_and_receive_window_boundaries_are_exact() {
        let now = 1_700_000_000_000;
        assert!(endpoint_time_window_valid(
            now + MAX_ENDPOINT_FUTURE_SKEW_MS,
            now + MAX_ENDPOINT_FUTURE_SKEW_MS + 1,
            now,
        ));
        assert!(!endpoint_time_window_valid(
            now + MAX_ENDPOINT_FUTURE_SKEW_MS + 1,
            now + MAX_ENDPOINT_FUTURE_SKEW_MS + 2,
            now,
        ));
        assert!(endpoint_time_window_valid(
            now,
            now + MAX_ENDPOINT_ENVELOPE_LIFETIME_MS,
            now,
        ));
        assert!(!endpoint_time_window_valid(
            now,
            now + MAX_ENDPOINT_ENVELOPE_LIFETIME_MS + 1,
            now,
        ));
        assert!(valid_endpoint_text(b"space tab\tline\nreturn\r"));
        assert!(!valid_endpoint_text(b"nul\0"));
        assert!(!valid_endpoint_text(b"escape\x1b"));
        assert!(!valid_endpoint_text(b"delete\x7f"));
        assert!(!valid_endpoint_text(&[0xFF]));
    }

    #[test]
    fn endpoint_rejects_provisional_session_until_pairresponse_confirmation() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let mut provisional = fixture.binding.clone();
        provisional.lifecycle = SessionLifecycle::Provisional;
        provisional.response_hash = None;
        let mut store = open_test_store(&path, backend);
        store.create_session(provisional, fixture.root).unwrap();
        let envelope = inbound_message_envelope(&fixture, 0, [0x70; 16], b"confirmed-only");
        assert!(matches!(
            store.accept_message_envelope(
                &fixture.key,
                &envelope.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::SessionNotConfirmed)
        ));
        store.confirm_session(&fixture.key, [0x46; 32]).unwrap();
        store
            .accept_message_envelope(
                &fixture.key,
                &envelope.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
    }

    #[test]
    fn endpoint_out_of_order_collision_jump_revocation_and_wrong_session_fail_closed() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();

        let index_two = inbound_message_envelope(&fixture, 2, [0x71; 16], b"index-two");
        store
            .accept_message_envelope(
                &fixture.key,
                &index_two.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
        let index_zero = inbound_message_envelope(&fixture, 0, [0x72; 16], b"index-zero");
        store
            .accept_message_envelope(
                &fixture.key,
                &index_zero.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();

        let logical_first = inbound_message_envelope(&fixture, 1, [0x73; 16], b"first");
        store
            .accept_message_envelope(
                &fixture.key,
                &logical_first.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
        let logical_conflict = inbound_message_envelope(&fixture, 3, [0x73; 16], b"second");
        assert!(matches!(
            store.accept_message_envelope(
                &fixture.key,
                &logical_conflict.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::LogicalMessageConflict)
        ));

        let jump = inbound_message_envelope(&fixture, 260, [0x74; 16], b"too-far");
        assert!(matches!(
            store.accept_message_envelope(
                &fixture.key,
                &jump.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::ForwardJumpTooLarge)
        ));
        let revoked = inbound_message_envelope(&fixture, 3, [0x75; 16], b"revoked");
        assert!(matches!(
            store.accept_message_envelope(
                &fixture.key,
                &revoked.pack(),
                &fixture.remote_certificate,
                true,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::RevokedDevice)
        ));
        let mut wrong_session_key = fixture.key.clone();
        wrong_session_key.init_id[0] ^= 1;
        assert!(matches!(
            store.accept_message_envelope(
                &wrong_session_key,
                &revoked.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::NotFound)
        ));
        assert_eq!(store.pending_endpoint_ack_intents().unwrap().len(), 3);
    }

    #[test]
    fn endpoint_message_crash_journal_recovers_before_ack_visibility() {
        {
            let temp = tempdir().unwrap();
            let path = temp.path().join("sessions.sqlite");
            let backend = Arc::new(MemoryProtectedBackend::default());
            let fixture = endpoint_fixture();
            let mut store = open_test_store(&path, Arc::clone(&backend));
            store
                .create_session(fixture.binding.clone(), fixture.root)
                .unwrap();
            let envelope = inbound_message_envelope(&fixture, 0, [0x59; 16], b"not-yet-durable");
            store.inject_endpoint_fault(EndpointFaultPoint::BeforeProtectedReplacement);
            assert!(matches!(
                store.accept_message_envelope(
                    &fixture.key,
                    &envelope.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                ),
                Err(IndexedSessionStoreError::InjectedEndpointFailure(_))
            ));
            drop(store);
            let mut reopened = open_test_store(&path, backend);
            assert!(reopened.pending_endpoint_ack_intents().unwrap().is_empty());
            reopened
                .accept_message_envelope(
                    &fixture.key,
                    &envelope.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                )
                .unwrap();
        }
        for point in [
            EndpointFaultPoint::AfterProtectedReplacement,
            EndpointFaultPoint::BeforeDatabaseCommit,
            EndpointFaultPoint::AfterDatabaseCommit,
            EndpointFaultPoint::BeforeJournalClear,
        ] {
            let temp = tempdir().unwrap();
            let path = temp.path().join("sessions.sqlite");
            let backend = Arc::new(MemoryProtectedBackend::default());
            let fixture = endpoint_fixture();
            let mut store = open_test_store(&path, Arc::clone(&backend));
            store
                .create_session(fixture.binding.clone(), fixture.root)
                .unwrap();
            let envelope = inbound_message_envelope(&fixture, 0, [point as u8; 16], b"recover-me");
            store.inject_endpoint_fault(point);
            assert!(matches!(
                store.accept_message_envelope(
                    &fixture.key,
                    &envelope.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                ),
                Err(IndexedSessionStoreError::InjectedEndpointFailure(_))
            ));
            drop(store);
            let reopened = open_test_store(&path, backend);
            assert_eq!(reopened.pending_endpoint_ack_intents().unwrap().len(), 1);
            let receipts: i64 = reopened
                .conn
                .query_row("SELECT COUNT(*) FROM endpoint_receipts", [], |row| {
                    row.get(0)
                })
                .unwrap();
            assert_eq!(receipts, 1);
        }

        {
            let temp = tempdir().unwrap();
            let path = temp.path().join("sessions.sqlite");
            let backend = Arc::new(MemoryProtectedBackend::default());
            let fixture = endpoint_fixture();
            let mut store = open_test_store(&path, Arc::clone(&backend));
            store
                .create_session(fixture.binding.clone(), fixture.root)
                .unwrap();
            let envelope = inbound_message_envelope(&fixture, 0, [0x5A; 16], b"protected-fail");
            backend.fail_next_put();
            assert!(matches!(
                store.accept_message_envelope(
                    &fixture.key,
                    &envelope.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                ),
                Err(IndexedSessionStoreError::ProtectedStore(_))
            ));
            assert!(store.pending_endpoint_ack_intents().unwrap().is_empty());
            store
                .accept_message_envelope(
                    &fixture.key,
                    &envelope.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                )
                .unwrap();
        }
    }

    #[test]
    fn ack_acceptance_binds_outstanding_row_and_is_monotonic() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let mut store = open_test_store(&path, Arc::clone(&backend));
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let outbound_id = [0xE0; 16];
        store
            .register_outstanding_message(&fixture.key, &outbound_id)
            .unwrap();
        let delivered = inbound_ack_envelope(&fixture, 0, [0xE1; 16], outbound_id, 1, [0xE2; 12]);
        assert_eq!(delivered.flags, 0);
        assert!(matches!(
            store
                .accept_ack_envelope(
                    &fixture.key,
                    &delivered.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                )
                .unwrap(),
            EndpointAckAcceptance::Committed {
                delivery_state: EndpointDeliveryState::Delivered,
                ..
            }
        ));
        assert!(matches!(
            store
                .accept_ack_envelope(
                    &fixture.key,
                    &delivered.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                )
                .unwrap(),
            EndpointAckAcceptance::Duplicate { .. }
        ));
        let read = inbound_ack_envelope(&fixture, 1, [0xE3; 16], outbound_id, 2, [0xE4; 12]);
        store
            .accept_ack_envelope(
                &fixture.key,
                &read.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
        assert_eq!(
            store
                .outstanding_delivery_state(
                    &fixture.binding.session_id,
                    &outbound_id,
                    &fixture.key.responder_device_ed25519,
                )
                .unwrap(),
            Some(EndpointDeliveryState::Read)
        );
    }

    #[test]
    fn ack_acceptance_journal_recovers_and_nonce_conflict_does_not_advance() {
        {
            let temp = tempdir().unwrap();
            let path = temp.path().join("sessions.sqlite");
            let backend = Arc::new(MemoryProtectedBackend::default());
            let fixture = endpoint_fixture();
            let mut store = open_test_store(&path, Arc::clone(&backend));
            store
                .create_session(fixture.binding.clone(), fixture.root)
                .unwrap();
            let outbound = [0x5B; 16];
            store
                .register_outstanding_message(&fixture.key, &outbound)
                .unwrap();
            let ack = inbound_ack_envelope(&fixture, 0, [0x5C; 16], outbound, 1, [0x5D; 12]);
            store.inject_endpoint_fault(EndpointFaultPoint::BeforeProtectedReplacement);
            assert!(matches!(
                store.accept_ack_envelope(
                    &fixture.key,
                    &ack.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                ),
                Err(IndexedSessionStoreError::InjectedEndpointFailure(_))
            ));
            drop(store);
            let mut reopened = open_test_store(&path, backend);
            assert_eq!(
                reopened
                    .outstanding_delivery_state(
                        &fixture.binding.session_id,
                        &outbound,
                        &fixture.key.responder_device_ed25519,
                    )
                    .unwrap(),
                Some(EndpointDeliveryState::Sent)
            );
            reopened
                .accept_ack_envelope(
                    &fixture.key,
                    &ack.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                )
                .unwrap();
        }
        for point in [
            EndpointFaultPoint::AfterProtectedReplacement,
            EndpointFaultPoint::BeforeDatabaseCommit,
            EndpointFaultPoint::AfterDatabaseCommit,
            EndpointFaultPoint::BeforeJournalClear,
            EndpointFaultPoint::AfterJournalClear,
        ] {
            let temp = tempdir().unwrap();
            let path = temp.path().join("sessions.sqlite");
            let backend = Arc::new(MemoryProtectedBackend::default());
            let fixture = endpoint_fixture();
            let mut store = open_test_store(&path, Arc::clone(&backend));
            store
                .create_session(fixture.binding.clone(), fixture.root)
                .unwrap();
            let outbound = [point as u8; 16];
            store
                .register_outstanding_message(&fixture.key, &outbound)
                .unwrap();
            let ack = inbound_ack_envelope(&fixture, 0, [0x61; 16], outbound, 1, [0x62; 12]);
            store.inject_endpoint_fault(point);
            assert!(matches!(
                store.accept_ack_envelope(
                    &fixture.key,
                    &ack.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                ),
                Err(IndexedSessionStoreError::InjectedEndpointFailure(_))
            ));
            drop(store);
            let reopened = open_test_store(&path, backend);
            assert_eq!(
                reopened
                    .outstanding_delivery_state(
                        &fixture.binding.session_id,
                        &outbound,
                        &fixture.key.responder_device_ed25519,
                    )
                    .unwrap(),
                Some(EndpointDeliveryState::Delivered)
            );
        }

        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let outbound = [0x63; 16];
        store
            .register_outstanding_message(&fixture.key, &outbound)
            .unwrap();
        let first = inbound_ack_envelope(&fixture, 0, [0x64; 16], outbound, 1, [0x65; 12]);
        store
            .accept_ack_envelope(
                &fixture.key,
                &first.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
        let conflict = inbound_ack_envelope(&fixture, 1, [0x66; 16], outbound, 2, [0x65; 12]);
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &conflict.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::AckNonceConflict)
        ));
        let valid = inbound_ack_envelope(&fixture, 1, [0x67; 16], outbound, 2, [0x68; 12]);
        store
            .accept_ack_envelope(
                &fixture.key,
                &valid.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
    }

    #[test]
    fn ack_negatives_do_not_advance_and_enqueue_reuses_immutable_bytes() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let outbound_id = [0xF0; 16];
        let unknown = inbound_ack_envelope(&fixture, 0, [0xF1; 16], outbound_id, 1, [0xF2; 12]);
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &unknown.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::AckOutstandingMismatch)
        ));
        store
            .register_outstanding_message(&fixture.key, &outbound_id)
            .unwrap();
        store
            .accept_ack_envelope(
                &fixture.key,
                &unknown.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();

        let message = inbound_message_envelope(&fixture, 0, [0xF3; 16], b"ack-intent");
        let accepted = store
            .accept_message_envelope(
                &fixture.key,
                &message.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
        let digest = match accepted {
            EndpointAcceptance::Committed { object_digest, .. } => object_digest,
            _ => unreachable!(),
        };
        store.inject_endpoint_fault(EndpointFaultPoint::AfterAckEnqueue);
        let mut enqueued = Vec::new();
        assert!(matches!(
            store.enqueue_endpoint_ack(
                &fixture.binding.session_id,
                &digest,
                b"immutable-ack-envelope",
                |bytes| {
                    enqueued.push(bytes.to_vec());
                    Ok(())
                },
            ),
            Err(IndexedSessionStoreError::InjectedEndpointFailure(_))
        ));
        assert!(matches!(
            store.enqueue_endpoint_ack(
                &fixture.binding.session_id,
                &digest,
                b"immutable-ack-envelope",
                |_| Err("injected queue failure".into()),
            ),
            Err(IndexedSessionStoreError::AckEnqueue)
        ));
        store
            .enqueue_endpoint_ack(
                &fixture.binding.session_id,
                &digest,
                b"immutable-ack-envelope",
                |bytes| {
                    enqueued.push(bytes.to_vec());
                    Ok(())
                },
            )
            .unwrap();
        assert_eq!(enqueued.len(), 2);
        assert_eq!(enqueued[0], enqueued[1]);
    }

    #[test]
    fn ack_authentication_negatives_never_advance_the_ratchet_or_delivery_row() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let outbound = [0x31; 16];
        store
            .register_outstanding_message(&fixture.key, &outbound)
            .unwrap();

        let mut bad_outer = inbound_ack_envelope(&fixture, 0, [0x32; 16], outbound, 1, [0x33; 12]);
        bad_outer.sender_authentication[0] ^= 1;
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &bad_outer.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::OuterSignatureInvalid)
        ));

        let valid = inbound_ack_envelope(&fixture, 0, [0x34; 16], outbound, 1, [0x35; 12]);
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &valid.pack(),
                &fixture.remote_certificate,
                true,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::RevokedDevice)
        ));
        let wrong_identity = Identity::from_seed(&[0x36; 32]);
        let wrong_user = Identity::from_seed(&[0x37; 32]);
        let wrong_certificate = DeviceCertificate::issue(
            &wrong_user,
            wrong_identity.public_key_bytes(),
            [0x38; 32],
            "wrong-device",
            fixture.now_ms - 1,
            fixture.now_ms + 60_000,
            1,
        )
        .unwrap();
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &valid.pack(),
                &wrong_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::DeviceBindingMismatch)
        ));

        let mut wrong_route = valid.clone();
        wrong_route.routing_tag[0] ^= 1;
        wrong_route.sign_with(&fixture.remote_identity);
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &wrong_route.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::RouteTagMismatch)
        ));
        let mut wrong_hint = valid.clone();
        wrong_hint.dest_device_hint ^= 1;
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &wrong_hint.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::DeviceHintMismatch)
        ));
        let mut tampered_aead = valid.clone();
        let last = tampered_aead.message_ciphertext.len() - 1;
        tampered_aead.message_ciphertext[last] ^= 1;
        tampered_aead.sign_with(&fixture.remote_identity);
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &tampered_aead.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::AuthenticationFailed)
        ));
        let mut wrong_aad = valid.clone();
        wrong_aad.message_id[0] ^= 1;
        wrong_aad.sign_with(&fixture.remote_identity);
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &wrong_aad.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::AuthenticationFailed)
        ));

        let zero_inner = custom_inbound_ack_envelope(
            &fixture,
            0,
            [0x38; 16],
            outbound,
            1,
            [0x39; 12],
            fixture.now_ms,
            None,
        );
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &zero_inner.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::AckInnerSignatureInvalid)
        ));

        let wrong_inner = custom_inbound_ack_envelope(
            &fixture,
            0,
            [0x39; 16],
            outbound,
            1,
            [0x3A; 12],
            fixture.now_ms,
            Some(&wrong_identity),
        );
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &wrong_inner.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::AckInnerSignatureInvalid)
        ));
        let wrong_timestamp = custom_inbound_ack_envelope(
            &fixture,
            0,
            [0x3B; 16],
            outbound,
            1,
            [0x3C; 12],
            fixture.now_ms - 1,
            Some(&fixture.remote_identity),
        );
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &wrong_timestamp.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::AckTimestampMismatch)
        ));
        let invalid_status = custom_inbound_ack_envelope(
            &fixture,
            0,
            [0x3D; 16],
            outbound,
            3,
            [0x3E; 12],
            fixture.now_ms,
            Some(&fixture.remote_identity),
        );
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &invalid_status.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::InvalidIndexedMessage)
        ));
        let jump = inbound_ack_envelope(&fixture, 257, [0x3F; 16], outbound, 1, [0x40; 12]);
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &jump.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::ForwardJumpTooLarge)
        ));
        let mut stale = valid.clone();
        stale.created_at = fixture.now_ms - 120_000;
        stale.expires_at = fixture.now_ms - 60_000;
        stale.routing_tag = derive_route_tag(
            &fixture.root,
            stale.created_at,
            0,
            EnvType::Ack as u8,
            Direction::ResponderToInitiator,
        )
        .unwrap();
        stale.sign_with(&fixture.remote_identity);
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &stale.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::EndpointNotCurrentlyValid)
        ));
        assert_eq!(
            store
                .outstanding_delivery_state(
                    &fixture.binding.session_id,
                    &outbound,
                    &fixture.key.responder_device_ed25519,
                )
                .unwrap(),
            Some(EndpointDeliveryState::Sent)
        );
        store
            .accept_ack_envelope(
                &fixture.key,
                &valid.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
        assert!(matches!(
            store.accept_ack_envelope(
                &fixture.key,
                &inbound_ack_envelope(&fixture, 0, [0x41; 16], outbound, 1, [0x42; 12],).pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::Replay)
        ));
    }

    #[test]
    fn outbound_message_commits_exact_ciphertext_and_outstanding_binding() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend.clone());
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let mut rng = StdRng::from_seed([0x61; 32]);
        let mut queued = Vec::new();
        let outbound = {
            let mut queue = |digest: &[u8; 32], bytes: &[u8]| {
                queued.push((*digest, bytes.to_vec()));
                Ok(*digest)
            };
            store
                .send_message_envelope(
                    &fixture.key,
                    "outbound exact text",
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut rng,
                    &mut queue,
                )
                .unwrap()
        };

        assert_eq!(outbound.kind, EndpointOutboundKind::Message);
        assert_eq!(outbound.state, EndpointOutboxState::Queued);
        assert_eq!(outbound.ratchet_index, 0);
        assert_eq!(
            queued,
            vec![(
                outbound.object_digest,
                outbound.immutable_envelope_bytes.clone()
            )]
        );
        let envelope = Envelope::unpack(&outbound.immutable_envelope_bytes).unwrap();
        assert_eq!(envelope.env_type, EnvType::Message as u8);
        assert_eq!(envelope.flags, OUTBOUND_FLAGS);
        assert_eq!(
            envelope.dest_device_hint,
            endpoint_device_hint(&fixture.key.responder_device_ed25519)
        );
        assert!(envelope.verify(&fixture.local_identity.public_key_bytes()));
        let key = message_key_at_index(
            &fixture.root,
            &fixture.key.initiator_address,
            &fixture.key.responder_address,
            Direction::InitiatorToResponder,
            0,
        )
        .unwrap();
        assert_eq!(
            open_indexed_message_with_key(
                &key,
                &fixture.key.initiator_address,
                &fixture.key.responder_address,
                Direction::InitiatorToResponder,
                &envelope.message_id,
                &envelope.message_ciphertext,
            )
            .unwrap(),
            b"outbound exact text"
        );
        assert_eq!(
            store
                .outstanding_delivery_state(
                    &fixture.binding.session_id,
                    &outbound.message_id,
                    &fixture.key.responder_device_ed25519,
                )
                .unwrap(),
            Some(EndpointDeliveryState::Sent)
        );
        assert!(store.pending_endpoint_outbound().unwrap().is_empty());
        let protected = backend
            .get(&hex::encode(record_key_digest(&fixture.key).unwrap()))
            .unwrap()
            .unwrap();
        assert!(!protected
            .windows(b"outbound exact text".len())
            .any(|window| window == b"outbound exact text"));
    }

    #[test]
    fn ack_worker_uses_only_committed_intent_and_independent_lane() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let inbound_id = [0x71; 16];
        let inbound = inbound_message_envelope(&fixture, 0, inbound_id, b"please acknowledge");
        let accepted = store
            .accept_message_envelope(
                &fixture.key,
                &inbound.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap();
        let intent_digest = match accepted {
            EndpointAcceptance::Committed { object_digest, .. } => object_digest,
            _ => unreachable!(),
        };

        let mut message_rng = StdRng::from_seed([0x72; 32]);
        let mut discard_queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
        let message = store
            .send_message_envelope(
                &fixture.key,
                "message lane zero",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut message_rng,
                &mut discard_queue,
            )
            .unwrap();
        assert_eq!(message.ratchet_index, 0);

        let mut ack_rng = StdRng::from_seed([0x73; 32]);
        let mut ack_queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
        let ack = store
            .enqueue_committed_ack(
                &fixture.key,
                &intent_digest,
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut ack_rng,
                &mut ack_queue,
            )
            .unwrap();
        assert_eq!(ack.kind, EndpointOutboundKind::Ack);
        assert_eq!(
            ack.ratchet_index, 0,
            "ACK lane must not consume message lane"
        );
        let envelope = Envelope::unpack(&ack.immutable_envelope_bytes).unwrap();
        assert_eq!(envelope.env_type, EnvType::Ack as u8);
        assert_eq!(
            envelope.message_ciphertext.len(),
            crate::atsam_indexed_session::ACK_SEALED_WIRE_LEN
        );
        assert!(envelope.verify(&fixture.local_identity.public_key_bytes()));
        let ack_key = ack_key_at_index(
            &fixture.root,
            &fixture.key.initiator_address,
            &fixture.key.responder_address,
            Direction::InitiatorToResponder,
            0,
        )
        .unwrap();
        let plaintext = open_indexed_message_with_key(
            &ack_key,
            &fixture.key.initiator_address,
            &fixture.key.responder_address,
            Direction::InitiatorToResponder,
            &envelope.message_id,
            &envelope.message_ciphertext,
        )
        .unwrap();
        assert_eq!(
            plaintext.len(),
            crate::atsam_indexed_session::ACK_PLAINTEXT_LEN
        );
        let signed = decode_signed_ack(&plaintext).unwrap();
        assert_eq!(signed.record.acked_message_id, inbound_id);
        assert_eq!(signed.record.status, 1);
        assert_eq!(signed.record.created_at, fixture.now_ms);
        assert!(signed.record.verify(
            &signed.signature,
            &fixture.local_identity.public_key_bytes()
        ));
        assert!(store.pending_endpoint_ack_intents().unwrap().is_empty());

        let mut unused_rng = StdRng::from_seed([0x74; 32]);
        let mut unexpected_callback = |_digest: &[u8; 32], _bytes: &[u8]| -> Result<[u8; 32], ()> {
            panic!("queued ACK replay must not call the queue")
        };
        assert_eq!(
            store
                .enqueue_committed_ack(
                    &fixture.key,
                    &intent_digest,
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut unused_rng,
                    &mut unexpected_callback,
                )
                .unwrap()
                .immutable_envelope_bytes,
            ack.immutable_envelope_bytes
        );
    }

    #[test]
    fn ack_worker_retries_exact_bytes_after_queue_boundary_and_rejects_arbitrary_intent() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let inbound = inbound_message_envelope(&fixture, 0, [0x75; 16], b"ack retry");
        let intent_digest = match store
            .accept_message_envelope(
                &fixture.key,
                &inbound.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap()
        {
            EndpointAcceptance::Committed { object_digest, .. } => object_digest,
            _ => unreachable!(),
        };

        let mut arbitrary_rng = StdRng::from_seed([0x76; 32]);
        let mut no_queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
        assert!(matches!(
            store.enqueue_committed_ack(
                &fixture.key,
                &[0xFF; 32],
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut arbitrary_rng,
                &mut no_queue,
            ),
            Err(IndexedSessionStoreError::NotFound)
        ));

        store.inject_endpoint_fault(EndpointFaultPoint::AfterOutboundQueueHandoff);
        let mut rng = StdRng::from_seed([0x77; 32]);
        let mut first = Vec::new();
        {
            let mut queue = |digest: &[u8; 32], bytes: &[u8]| {
                first.push((*digest, bytes.to_vec()));
                Ok(*digest)
            };
            assert!(matches!(
                store.enqueue_committed_ack(
                    &fixture.key,
                    &intent_digest,
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut rng,
                    &mut queue,
                ),
                Err(IndexedSessionStoreError::InjectedEndpointFailure(_))
            ));
        }
        let pending = store.pending_endpoint_outbound().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].kind, EndpointOutboundKind::Ack);
        assert_eq!(pending[0].ratchet_index, 0);
        assert_eq!(pending[0].immutable_envelope_bytes, first[0].1);

        let mut retried = Vec::new();
        let mut retry_queue = |digest: &[u8; 32], bytes: &[u8]| {
            retried.push((*digest, bytes.to_vec()));
            Ok(*digest)
        };
        let queued = store
            .retry_endpoint_outbound(
                &fixture.key,
                &pending[0].object_digest,
                &local_device,
                fixture.now_ms,
                &mut retry_queue,
            )
            .unwrap();
        assert_eq!(queued.state, EndpointOutboxState::Queued);
        assert_eq!(retried, first);
        assert!(store.pending_endpoint_ack_intents().unwrap().is_empty());
    }

    #[test]
    fn ack_worker_rejects_intent_not_exactly_bound_to_its_committed_receipt() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let inbound_id = [0x78; 16];
        let inbound = inbound_message_envelope(&fixture, 0, inbound_id, b"bound ACK intent");
        let intent_digest = match store
            .accept_message_envelope(
                &fixture.key,
                &inbound.pack(),
                &fixture.remote_certificate,
                false,
                fixture.now_ms,
            )
            .unwrap()
        {
            EndpointAcceptance::Committed { object_digest, .. } => object_digest,
            _ => unreachable!(),
        };
        store
            .conn
            .execute(
                "UPDATE endpoint_ack_intents SET message_id = ?1
                 WHERE session_id = ?2 AND object_digest = ?3",
                params![
                    [0x79u8; 16].as_slice(),
                    fixture.binding.session_id.as_slice(),
                    intent_digest.as_slice()
                ],
            )
            .unwrap();
        let mut rejected_rng = StdRng::from_seed([0x7A; 32]);
        let mut queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
        assert!(matches!(
            store.enqueue_committed_ack(
                &fixture.key,
                &intent_digest,
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut rejected_rng,
                &mut queue,
            ),
            Err(IndexedSessionStoreError::OutboundBindingMismatch)
        ));
        assert!(store.pending_endpoint_outbound().unwrap().is_empty());

        store
            .conn
            .execute(
                "UPDATE endpoint_ack_intents SET message_id = ?1
                 WHERE session_id = ?2 AND object_digest = ?3",
                params![
                    inbound_id.as_slice(),
                    fixture.binding.session_id.as_slice(),
                    intent_digest.as_slice()
                ],
            )
            .unwrap();
        let mut valid_rng = StdRng::from_seed([0x7B; 32]);
        let ack = store
            .enqueue_committed_ack(
                &fixture.key,
                &intent_digest,
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut valid_rng,
                &mut queue,
            )
            .unwrap();
        assert_eq!(
            ack.ratchet_index, 0,
            "rejection must not reserve an ACK key"
        );
    }

    #[test]
    fn ack_nonce_collision_does_not_advance_the_independent_ack_lane() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let mut intent_digests = Vec::new();
        for (index, message_id) in [(0, [0x7C; 16]), (1, [0x7D; 16])] {
            let inbound = inbound_message_envelope(&fixture, index, message_id, b"ACK collision");
            let accepted = store
                .accept_message_envelope(
                    &fixture.key,
                    &inbound.pack(),
                    &fixture.remote_certificate,
                    false,
                    fixture.now_ms,
                )
                .unwrap();
            let EndpointAcceptance::Committed { object_digest, .. } = accepted else {
                unreachable!()
            };
            intent_digests.push(object_digest);
        }
        let reused_ack_nonce = [0x7E; 12];
        let mut queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
        let mut first_rng =
            ScriptedCryptoRng::ack([0x7F; 16], [0x80; 12], [0x81; 12], reused_ack_nonce);
        let first = store
            .enqueue_committed_ack(
                &fixture.key,
                &intent_digests[0],
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut first_rng,
                &mut queue,
            )
            .unwrap();
        assert_eq!(first.ratchet_index, 0);

        let mut collision_rng =
            ScriptedCryptoRng::ack([0x82; 16], [0x83; 12], [0x84; 12], reused_ack_nonce);
        assert!(matches!(
            store.enqueue_committed_ack(
                &fixture.key,
                &intent_digests[1],
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut collision_rng,
                &mut queue,
            ),
            Err(IndexedSessionStoreError::OutboundCollision)
        ));

        let mut fresh_rng = ScriptedCryptoRng::ack([0x85; 16], [0x86; 12], [0x87; 12], [0x88; 12]);
        let second = store
            .enqueue_committed_ack(
                &fixture.key,
                &intent_digests[1],
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut fresh_rng,
                &mut queue,
            )
            .unwrap();
        assert_eq!(second.ratchet_index, 1);
    }

    #[test]
    fn outbound_queue_failure_and_collision_retry_exact_bytes_without_key_reuse() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let seed = [0x81; 32];
        let mut rng = StdRng::from_seed(seed);
        let mut first_attempt = Vec::new();
        {
            let mut failing_queue = |digest: &[u8; 32], bytes: &[u8]| {
                first_attempt.push((*digest, bytes.to_vec()));
                Err(())
            };
            assert!(matches!(
                store.send_message_envelope(
                    &fixture.key,
                    "retry exact",
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut rng,
                    &mut failing_queue,
                ),
                Err(IndexedSessionStoreError::OutboundQueueHandoff)
            ));
        }
        let pending = store.pending_endpoint_outbound().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].immutable_envelope_bytes, first_attempt[0].1);

        let mut forbidden_rng = StdRng::from_seed([0x82; 32]);
        let mut no_queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "must retry first",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut forbidden_rng,
                &mut no_queue,
            ),
            Err(IndexedSessionStoreError::OutboundPending)
        ));

        let mut wrong_receipt = |_digest: &[u8; 32], _bytes: &[u8]| Ok([0xFF; 32]);
        assert!(matches!(
            store.retry_endpoint_outbound(
                &fixture.key,
                &pending[0].object_digest,
                &local_device,
                fixture.now_ms,
                &mut wrong_receipt,
            ),
            Err(IndexedSessionStoreError::OutboundQueueHandoff)
        ));
        let mut retried = Vec::new();
        let queued = {
            let mut success = |digest: &[u8; 32], bytes: &[u8]| {
                retried.push((*digest, bytes.to_vec()));
                Ok(*digest)
            };
            store
                .retry_endpoint_outbound(
                    &fixture.key,
                    &pending[0].object_digest,
                    &local_device,
                    fixture.now_ms,
                    &mut success,
                )
                .unwrap()
        };
        assert_eq!(retried, first_attempt);
        assert_eq!(queued.state, EndpointOutboxState::Queued);

        let mut collision_rng = StdRng::from_seed(seed);
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "collision is rejected",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut collision_rng,
                &mut no_queue,
            ),
            Err(IndexedSessionStoreError::OutboundCollision)
        ));
        let mut fresh_rng = StdRng::from_seed([0x83; 32]);
        let next = store
            .send_message_envelope(
                &fixture.key,
                "next valid key",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut fresh_rng,
                &mut no_queue,
            )
            .unwrap();
        assert_eq!(next.ratchet_index, 1, "collision must not burn another key");
    }

    #[test]
    fn outbound_crash_boundaries_recover_or_leave_index_unconsumed() {
        for point in [
            EndpointFaultPoint::BeforeProtectedReplacement,
            EndpointFaultPoint::AfterProtectedReplacement,
            EndpointFaultPoint::BeforeDatabaseCommit,
            EndpointFaultPoint::AfterDatabaseCommit,
            EndpointFaultPoint::BeforeJournalClear,
            EndpointFaultPoint::AfterJournalClear,
            EndpointFaultPoint::BeforeOutboundQueueHandoff,
            EndpointFaultPoint::AfterOutboundQueueHandoff,
        ] {
            let temp = tempdir().unwrap();
            let path = temp.path().join("sessions.sqlite");
            let backend = Arc::new(MemoryProtectedBackend::default());
            let fixture = endpoint_fixture();
            let local_device = authorized_local_device(&fixture);
            let mut store = open_test_store(&path, backend.clone());
            store
                .create_session(fixture.binding.clone(), fixture.root)
                .unwrap();
            store.inject_endpoint_fault(point);
            let mut rng = StdRng::from_seed([point as u8 + 0x91; 32]);
            let mut handed_off = Vec::new();
            let mut queue = |digest: &[u8; 32], bytes: &[u8]| {
                handed_off.push((*digest, bytes.to_vec()));
                Ok(*digest)
            };
            assert!(matches!(
                store.send_message_envelope(
                    &fixture.key,
                    "crash recovery",
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut rng,
                    &mut queue,
                ),
                Err(IndexedSessionStoreError::InjectedEndpointFailure(_))
            ));
            if point == EndpointFaultPoint::AfterOutboundQueueHandoff {
                assert_eq!(handed_off.len(), 1);
            } else {
                assert!(handed_off.is_empty(), "fault {point:?}");
            }
            drop(store);

            let mut reopened = open_test_store(&path, backend);
            let pending = reopened.pending_endpoint_outbound().unwrap();
            if point == EndpointFaultPoint::BeforeProtectedReplacement {
                assert!(pending.is_empty());
                let mut retry_rng = StdRng::from_seed([0xA1; 32]);
                let mut queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
                let sent = reopened
                    .send_message_envelope(
                        &fixture.key,
                        "index remains zero",
                        &local_device,
                        fixture.now_ms,
                        fixture.now_ms + 60_000,
                        fixture.now_ms,
                        &mut retry_rng,
                        &mut queue,
                    )
                    .unwrap();
                assert_eq!(sent.ratchet_index, 0);
            } else {
                assert_eq!(pending.len(), 1, "fault {point:?}");
                assert_eq!(pending[0].ratchet_index, 0);
                let expected = pending[0].immutable_envelope_bytes.clone();
                let mut replayed = Vec::new();
                let mut queue = |digest: &[u8; 32], bytes: &[u8]| {
                    replayed.push((*digest, bytes.to_vec()));
                    Ok(*digest)
                };
                reopened
                    .retry_endpoint_outbound(
                        &fixture.key,
                        &pending[0].object_digest,
                        &local_device,
                        fixture.now_ms,
                        &mut queue,
                    )
                    .unwrap();
                assert_eq!(replayed[0].1, expected);
                if point == EndpointFaultPoint::AfterOutboundQueueHandoff {
                    assert_eq!(replayed, handed_off);
                }
            }
        }
    }

    #[test]
    fn outbound_protected_and_database_failures_recover_without_resealing() {
        // A protected replacement that definitely did not occur leaves the
        // ratchet index reusable because no bytes could have reached a queue.
        {
            let temp = tempdir().unwrap();
            let path = temp.path().join("sessions.sqlite");
            let backend = Arc::new(MemoryProtectedBackend::default());
            let fixture = endpoint_fixture();
            let local_device = authorized_local_device(&fixture);
            let mut store = open_test_store(&path, backend.clone());
            store
                .create_session(fixture.binding.clone(), fixture.root)
                .unwrap();
            backend.fail_next_put();
            let seed = [0xC1; 32];
            let mut rng = StdRng::from_seed(seed);
            let mut queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
            assert!(matches!(
                store.send_message_envelope(
                    &fixture.key,
                    "protected failure",
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut rng,
                    &mut queue,
                ),
                Err(IndexedSessionStoreError::ProtectedStore(_))
            ));
            assert!(store.pending_endpoint_outbound().unwrap().is_empty());
            let mut retry_rng = StdRng::from_seed(seed);
            let sent = store
                .send_message_envelope(
                    &fixture.key,
                    "protected failure",
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut retry_rng,
                    &mut queue,
                )
                .unwrap();
            assert_eq!(sent.ratchet_index, 0);
        }

        // If the journal replacement succeeded but the database table is
        // unavailable, reopening recreates schema and materializes the exact
        // protected bytes.
        {
            let temp = tempdir().unwrap();
            let path = temp.path().join("sessions.sqlite");
            let backend = Arc::new(MemoryProtectedBackend::default());
            let fixture = endpoint_fixture();
            let local_device = authorized_local_device(&fixture);
            let mut store = open_test_store(&path, backend.clone());
            store
                .create_session(fixture.binding.clone(), fixture.root)
                .unwrap();
            store
                .conn
                .execute_batch(
                    "CREATE TRIGGER fail_endpoint_outbox_insert
                     BEFORE INSERT ON endpoint_outbox
                     BEGIN SELECT RAISE(ABORT, 'injected outbox failure'); END;",
                )
                .unwrap();
            let mut rng = StdRng::from_seed([0xC2; 32]);
            let mut no_queue = |_digest: &[u8; 32], _bytes: &[u8]| -> Result<[u8; 32], ()> {
                panic!("database failure must not queue")
            };
            assert!(matches!(
                store.send_message_envelope(
                    &fixture.key,
                    "database failure",
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut rng,
                    &mut no_queue,
                ),
                Err(IndexedSessionStoreError::Sqlite(_))
            ));
            store
                .conn
                .execute("DROP TRIGGER fail_endpoint_outbox_insert", [])
                .unwrap();
            drop(store);
            let mut reopened = open_test_store(&path, backend);
            let pending = reopened.pending_endpoint_outbound().unwrap();
            assert_eq!(pending.len(), 1);
            let exact = pending[0].immutable_envelope_bytes.clone();
            let mut queued = Vec::new();
            let mut queue = |digest: &[u8; 32], bytes: &[u8]| {
                queued.push((*digest, bytes.to_vec()));
                Ok(*digest)
            };
            reopened
                .retry_endpoint_outbound(
                    &fixture.key,
                    &pending[0].object_digest,
                    &local_device,
                    fixture.now_ms,
                    &mut queue,
                )
                .unwrap();
            assert_eq!(queued[0].1, exact);
        }

        // A failure while clearing the protected journal occurs only after the
        // exact outbox/outstanding commit. Reopen repeats that commit and then
        // clears the same journal.
        {
            let temp = tempdir().unwrap();
            let path = temp.path().join("sessions.sqlite");
            let backend = Arc::new(MemoryProtectedBackend::default());
            let fixture = endpoint_fixture();
            let local_device = authorized_local_device(&fixture);
            let mut store = open_test_store(&path, backend.clone());
            store
                .create_session(fixture.binding.clone(), fixture.root)
                .unwrap();
            backend.fail_nth_future_put(2);
            let mut rng = StdRng::from_seed([0xC3; 32]);
            let mut no_queue = |_digest: &[u8; 32], _bytes: &[u8]| -> Result<[u8; 32], ()> {
                panic!("journal-clear failure must not queue")
            };
            assert!(matches!(
                store.send_message_envelope(
                    &fixture.key,
                    "journal clear failure",
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut rng,
                    &mut no_queue,
                ),
                Err(IndexedSessionStoreError::ProtectedStore(_))
            ));
            drop(store);
            let reopened = open_test_store(&path, backend);
            let pending = reopened.pending_endpoint_outbound().unwrap();
            assert_eq!(pending.len(), 1);
            assert_eq!(pending[0].ratchet_index, 0);
        }
    }

    #[test]
    fn outbound_allows_only_initial_provisional_initiator_message_then_requires_confirmation() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut provisional = fixture.binding.clone();
        provisional.lifecycle = SessionLifecycle::Provisional;
        provisional.response_hash = None;
        let mut store = open_test_store(&path, backend);
        store.create_session(provisional, fixture.root).unwrap();
        let mut rng = StdRng::from_seed([0xB1; 32]);
        let mut queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
        let initial = store
            .send_message_envelope(
                &fixture.key,
                "provisional message zero",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut rng,
                &mut queue,
            )
            .unwrap();
        assert_eq!(initial.ratchet_index, 0);
        let mut second_rng = StdRng::from_seed([0xB8; 32]);
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "provisional message one is forbidden",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut second_rng,
                &mut queue,
            ),
            Err(IndexedSessionStoreError::SessionNotConfirmed)
        ));
        let mut ack_rng = StdRng::from_seed([0xB9; 32]);
        assert!(matches!(
            store.enqueue_committed_ack(
                &fixture.key,
                &[0xBA; 32],
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut ack_rng,
                &mut queue,
            ),
            Err(IndexedSessionStoreError::SessionNotConfirmed)
        ));

        store.confirm_session(&fixture.key, [0x46; 32]).unwrap();
        let mut confirmed_rng = StdRng::from_seed([0xBB; 32]);
        let confirmed = store
            .send_message_envelope(
                &fixture.key,
                "confirmed message one",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut confirmed_rng,
                &mut queue,
            )
            .unwrap();
        assert_eq!(confirmed.ratchet_index, 1);
        for invalid in ["", "bad\u{0001}text", "\u{007f}"] {
            let mut rng = StdRng::from_seed([0xB2; 32]);
            assert!(matches!(
                store.send_message_envelope(
                    &fixture.key,
                    invalid,
                    &local_device,
                    fixture.now_ms,
                    fixture.now_ms + 60_000,
                    fixture.now_ms,
                    &mut rng,
                    &mut queue,
                ),
                Err(IndexedSessionStoreError::InvalidEndpointPayload)
            ));
        }
        let oversized = "x".repeat(MAX_ENDPOINT_TEXT_BYTES + 1);
        let mut oversized_rng = StdRng::from_seed([0xB2; 32]);
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                &oversized,
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut oversized_rng,
                &mut queue,
            ),
            Err(IndexedSessionStoreError::InvalidEndpointPayload)
        ));
        let mut rng = StdRng::from_seed([0xB3; 32]);
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "bad time",
                &local_device,
                fixture.now_ms + MAX_ENDPOINT_FUTURE_SKEW_MS + 1,
                fixture.now_ms + MAX_ENDPOINT_FUTURE_SKEW_MS + 60_000,
                fixture.now_ms,
                &mut rng,
                &mut queue,
            ),
            Err(IndexedSessionStoreError::EndpointNotCurrentlyValid)
        ));

        let wrong_identity = Identity::from_seed(&[0xB4; 32]);
        assert!(matches!(
            AuthorizedEndpointDevice::authorize(
                &fixture.local_certificate,
                &wrong_identity,
                &fixture.local_registry,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::LocalDeviceUnauthorized)
        ));
        let mut revoked_registry = fixture.local_registry.clone();
        revoked_registry.revoke(&fixture.local_certificate.device_id);
        assert!(matches!(
            AuthorizedEndpointDevice::authorize(
                &fixture.local_certificate,
                &fixture.local_identity,
                &revoked_registry,
                fixture.now_ms,
            ),
            Err(IndexedSessionStoreError::LocalDeviceUnauthorized)
        ));
        let wrong_user = Identity::from_seed(&[0xB5; 32]);
        let wrong_certificate = DeviceCertificate::issue(
            &wrong_user,
            wrong_identity.public_key_bytes(),
            [0xB6; 32],
            "wrong-local",
            fixture.now_ms - 1,
            fixture.now_ms + 120_000,
            1,
        )
        .unwrap();
        let mut wrong_registry = DeviceRegistry::default();
        wrong_registry
            .add(wrong_certificate.clone(), fixture.now_ms)
            .unwrap();
        let wrong_device = AuthorizedEndpointDevice::authorize(
            &wrong_certificate,
            &wrong_identity,
            &wrong_registry,
            fixture.now_ms,
        )
        .unwrap();
        let mut rng = StdRng::from_seed([0xB7; 32]);
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "wrong device",
                &wrong_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut rng,
                &mut queue,
            ),
            Err(IndexedSessionStoreError::LocalDeviceBindingMismatch)
        ));
        let mut final_rng = StdRng::from_seed([0xBD; 32]);
        let after_negatives = store
            .send_message_envelope(
                &fixture.key,
                "all negative checks preserved the next key",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut final_rng,
                &mut queue,
            )
            .unwrap();
        assert_eq!(after_negatives.ratchet_index, 2);
    }

    #[test]
    fn provisional_responder_cannot_send() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let mut binding = fixture.binding.clone();
        binding.local_role = LocalRole::Responder;
        binding.lifecycle = SessionLifecycle::Provisional;
        binding.response_hash = None;
        let mut registry = DeviceRegistry::default();
        registry
            .add(fixture.remote_certificate.clone(), fixture.now_ms)
            .unwrap();
        let local_device = AuthorizedEndpointDevice::authorize(
            &fixture.remote_certificate,
            &fixture.remote_identity,
            &registry,
            fixture.now_ms,
        )
        .unwrap();
        let mut store = open_test_store(&path, backend);
        store.create_session(binding, fixture.root).unwrap();
        let mut rng = StdRng::from_seed([0xBC; 32]);
        let mut queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "responder must confirm first",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut rng,
                &mut queue,
            ),
            Err(IndexedSessionStoreError::SessionNotConfirmed)
        ));
        assert!(store.pending_endpoint_outbound().unwrap().is_empty());
    }

    #[test]
    fn retry_rejects_expired_object_before_queue_callback() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let mut rng = StdRng::from_seed([0xBD; 32]);
        let mut fail_queue = |_digest: &[u8; 32], _bytes: &[u8]| Err(());
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "short lived",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 1,
                fixture.now_ms,
                &mut rng,
                &mut fail_queue,
            ),
            Err(IndexedSessionStoreError::OutboundQueueHandoff)
        ));
        let pending = store.pending_endpoint_outbound().unwrap();
        assert_eq!(pending.len(), 1);
        let callback_invoked = AtomicBool::new(false);
        let mut forbidden_queue = |digest: &[u8; 32], _bytes: &[u8]| {
            callback_invoked.store(true, Ordering::SeqCst);
            Ok(*digest)
        };
        assert!(matches!(
            store.retry_endpoint_outbound(
                &fixture.key,
                &pending[0].object_digest,
                &local_device,
                fixture.now_ms + 2,
                &mut forbidden_queue,
            ),
            Err(IndexedSessionStoreError::EndpointNotCurrentlyValid)
        ));
        assert!(!callback_invoked.load(Ordering::SeqCst));
        assert_eq!(store.pending_endpoint_outbound().unwrap(), pending);
    }

    #[test]
    fn seal_nonce_collision_with_distinct_coordinates_does_not_advance_ratchet() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let reused_seal_nonce = [0xC1; 12];
        let mut first_rng = ScriptedCryptoRng::outbound([0xC2; 16], reused_seal_nonce, [0xC3; 12]);
        let mut queue = |digest: &[u8; 32], _bytes: &[u8]| Ok(*digest);
        let first = store
            .send_message_envelope(
                &fixture.key,
                "first nonce owner",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut first_rng,
                &mut queue,
            )
            .unwrap();
        assert_eq!(first.ratchet_index, 0);

        let mut collision_rng =
            ScriptedCryptoRng::outbound([0xC4; 16], reused_seal_nonce, [0xC5; 12]);
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "different coordinates same seal nonce",
                &local_device,
                fixture.now_ms + 1,
                fixture.now_ms + 60_001,
                fixture.now_ms,
                &mut collision_rng,
                &mut queue,
            ),
            Err(IndexedSessionStoreError::OutboundCollision)
        ));

        let mut fresh_rng = ScriptedCryptoRng::outbound([0xC6; 16], [0xC7; 12], [0xC8; 12]);
        let next = store
            .send_message_envelope(
                &fixture.key,
                "fresh nonce keeps index one",
                &local_device,
                fixture.now_ms + 1,
                fixture.now_ms + 60_001,
                fixture.now_ms,
                &mut fresh_rng,
                &mut queue,
            )
            .unwrap();
        assert_eq!(next.ratchet_index, 1);
    }

    #[test]
    fn concurrent_retries_converge_on_one_queued_exact_object() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend.clone());
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let mut rng = StdRng::from_seed([0xC9; 32]);
        let mut fail_queue = |_digest: &[u8; 32], _bytes: &[u8]| Err(());
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "concurrent retry",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut rng,
                &mut fail_queue,
            ),
            Err(IndexedSessionStoreError::OutboundQueueHandoff)
        ));
        let pending = store.pending_endpoint_outbound().unwrap().remove(0);
        drop(store);

        let barrier = Arc::new(Barrier::new(2));
        let observations = Arc::new(Mutex::new(Vec::new()));
        let mut handles = Vec::new();
        for _ in 0..2 {
            let path = path.clone();
            let backend = backend.clone();
            let barrier = barrier.clone();
            let observations = observations.clone();
            let object_digest = pending.object_digest;
            handles.push(thread::spawn(move || {
                let fixture = endpoint_fixture();
                let local_device = authorized_local_device(&fixture);
                let mut store = open_test_store(&path, backend);
                let mut queue = |digest: &[u8; 32], bytes: &[u8]| {
                    observations
                        .lock()
                        .expect("observation lock")
                        .push((*digest, bytes.to_vec()));
                    barrier.wait();
                    Ok(*digest)
                };
                store
                    .retry_endpoint_outbound(
                        &fixture.key,
                        &object_digest,
                        &local_device,
                        fixture.now_ms,
                        &mut queue,
                    )
                    .unwrap()
            }));
        }
        let results: Vec<_> = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect();
        assert!(results
            .iter()
            .all(|row| row.state == EndpointOutboxState::Queued));
        assert_eq!(
            results[0].immutable_envelope_bytes,
            pending.immutable_envelope_bytes
        );
        assert_eq!(
            results[1].immutable_envelope_bytes,
            pending.immutable_envelope_bytes
        );
        let observations = observations.lock().expect("observation lock");
        assert_eq!(observations.len(), 2);
        assert!(observations.iter().all(|(digest, bytes)| {
            *digest == pending.object_digest && *bytes == pending.immutable_envelope_bytes
        }));
        drop(observations);
        let reopened = open_test_store(&path, backend);
        assert!(reopened.pending_endpoint_outbound().unwrap().is_empty());
    }

    #[test]
    fn malicious_queue_callback_cannot_commit_mutated_outbox_bindings() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let fixture = endpoint_fixture();
        let local_device = authorized_local_device(&fixture);
        let mut store = open_test_store(&path, backend);
        store
            .create_session(fixture.binding.clone(), fixture.root)
            .unwrap();
        let mut rng = StdRng::from_seed([0xCA; 32]);
        let mut fail_queue = |_digest: &[u8; 32], _bytes: &[u8]| Err(());
        assert!(matches!(
            store.send_message_envelope(
                &fixture.key,
                "callback mutation",
                &local_device,
                fixture.now_ms,
                fixture.now_ms + 60_000,
                fixture.now_ms,
                &mut rng,
                &mut fail_queue,
            ),
            Err(IndexedSessionStoreError::OutboundQueueHandoff)
        ));
        let pending = store.pending_endpoint_outbound().unwrap().remove(0);
        let callback_path = path.clone();
        let mut malicious_queue = |digest: &[u8; 32], _bytes: &[u8]| {
            let conn = Connection::open(&callback_path).map_err(|_| ())?;
            conn.execute(
                "UPDATE endpoint_outbox SET recipient_device = ?1
                 WHERE object_digest = ?2",
                params![[0xDDu8; 32].as_slice(), digest.as_slice()],
            )
            .map_err(|_| ())?;
            Ok(*digest)
        };
        assert!(matches!(
            store.retry_endpoint_outbound(
                &fixture.key,
                &pending.object_digest,
                &local_device,
                fixture.now_ms,
                &mut malicious_queue,
            ),
            Err(IndexedSessionStoreError::OutboundBindingMismatch)
        ));
        let conn = Connection::open(&path).unwrap();
        let state: i64 = conn
            .query_row(
                "SELECT state FROM endpoint_outbox WHERE object_digest = ?1",
                params![pending.object_digest.as_slice()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(state, EndpointOutboxState::Prepared as i64);
    }

    #[test]
    fn pending_outbound_rejects_short_sealed_body_without_panicking() {
        let message_id = [0xCB; 16];
        let envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: OUTBOUND_FLAGS,
            message_id,
            routing_tag: [0xCC; 16],
            dest_device_hint: 1,
            created_at: 1,
            expires_at: 2,
            hop_limit: OUTBOUND_HOP_LIMIT,
            replication_budget: OUTBOUND_REPLICATION_BUDGET,
            anti_replay_nonce: [0xCD; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: Vec::new(),
            sender_authentication: vec![0; 64],
        };
        let pending = PendingOutbound {
            kind: EndpointOutboundKind::Message,
            session_id: [0xCE; 32],
            object_digest: authenticated_object_digest(&envelope),
            message_id,
            recipient_device: [0xCF; 32],
            ratchet_index: 0,
            source_ack_intent: None,
            ack_nonce: None,
            seal_nonce: [0xD0; 12],
            anti_replay_nonce: envelope.anti_replay_nonce,
            immutable_envelope_bytes: envelope.pack(),
            public_generation: 1,
        };
        assert!(matches!(
            validate_pending_outbound_shape(&pending),
            Err(IndexedSessionStoreError::CorruptProtectedState)
        ));
    }

    #[test]
    fn endpoint_plaintext_debug_output_is_redacted() {
        let acceptance = EndpointAcceptance::Committed {
            session_id: [1; 32],
            object_digest: [2; 32],
            message_id: [3; 16],
            plaintext: b"debug must not leak this plaintext".to_vec(),
        };
        let inbox = EndpointInboxRow {
            session_id: [1; 32],
            object_digest: [2; 32],
            message_id: [3; 16],
            sender_device: [4; 32],
            created_at_ms: 5,
            received_at_ms: 6,
            plaintext: b"or this inbox plaintext".to_vec(),
        };
        let acceptance_debug = format!("{acceptance:?}");
        let inbox_debug = format!("{inbox:?}");
        assert!(acceptance_debug.contains("<redacted>"));
        assert!(inbox_debug.contains("<redacted>"));
        assert!(!acceptance_debug.contains("debug must not leak"));
        assert!(!inbox_debug.contains("inbox plaintext"));
    }

    #[test]
    fn sqlite_and_json_never_contain_root_or_chain_material() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("sessions.sqlite");
        let backend = Arc::new(MemoryProtectedBackend::default());
        let binding = fixture_binding();
        let root = [0xA7; 32];
        let mut store = open_test_store(&path, backend);
        store.create_session(binding, root).unwrap();
        store
            .conn
            .execute_batch("PRAGMA wal_checkpoint(TRUNCATE);")
            .unwrap();
        drop(store);

        for candidate in [
            path.clone(),
            PathBuf::from(format!("{}-wal", path.display())),
            PathBuf::from(format!("{}-shm", path.display())),
        ] {
            if let Ok(bytes) = std::fs::read(candidate) {
                assert!(!bytes.windows(root.len()).any(|window| window == root));
                assert!(!String::from_utf8_lossy(&bytes).contains(&hex::encode(root)));
            }
        }
        assert!(std::fs::read_dir(temp.path())
            .unwrap()
            .filter_map(Result::ok)
            .all(|entry| entry.path().extension().and_then(|v| v.to_str()) != Some("json")));
    }
}
