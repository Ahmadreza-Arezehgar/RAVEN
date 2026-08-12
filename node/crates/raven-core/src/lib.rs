//! RAVEN protocol core (`rvn1`).
//!
//! Wire formats match `protocol/` + `shared-vectors/rvn1/`.
//! Content sealing: authenticated ChaCha20-Poly1305 interim path with clear hooks for
//! full ATSAM hybrid+ratchet (see `protocol/ATSAM_PRIMITIVE_MAPPING_V1.md`).

pub mod ack;
pub mod address;
pub mod alias_record;
pub mod atsam_aead;
pub mod atsam_kdf;
pub mod atsam_mlkem;
pub mod atsam_root;
pub mod bech32m;
pub mod chat_history;
pub mod ble_adapter;
pub mod bootstrap;
pub mod bridge;
pub mod canon;
pub mod contact_request;
pub mod device_cert;
pub mod device_sync;
pub mod discovery;
pub mod discovery_resolver;
pub mod envelope;
pub mod introduction;
pub mod nearby;
pub mod profile_record;
pub mod fingerprint;
pub mod forward_queue;
pub mod identity;
pub mod internet;
pub mod ipc;
pub mod message_router;
pub mod messaging_path;
pub mod node_policy;
pub mod prekey_bundle;
pub mod queue;
pub mod records;
pub mod routing_tag;
pub mod sanitize;
pub mod seal;
pub mod store_object;
pub mod transport;
pub mod vectors;

pub use address::{decode_address, encode_address, from_display, to_display};
pub use atsam_aead::{build_aad_v1, build_aad_v2, seal_rvna1_v2, unseal_rvna1_v2};
pub use atsam_mlkem::{initiate_hybrid_root, respond_hybrid_root, HybridKeypair};
pub use atsam_root::{derive_root, transcript_hash, x25519_shared};
pub use bootstrap::{
    bootstrap_path, load_bootstrap, save_bootstrap, BootstrapConfig, BootstrapError,
};
pub use device_cert::{
    device_registry_path, load_device_registry, save_device_registry, DeviceCertificate,
    DeviceRegistry,
};
pub use device_sync::{
    derive_device_sync_key, import_contact_sync, partition_lag_allows_stale_auth,
    revocation_store_path, seal_contact_sync, unseal_contact_sync, ContactSyncPlaintext,
    RevocationRecord, RevocationStore, SyncContact,
};
pub use messaging_path::{
    assert_no_silent_fastapi, path_from_raven_envelope_flag, resolve_terminal_messaging_path,
    MessagingPath, ENV_FORCE_LEGACY_LABEL, ENV_SERVERLESS_RVN1,
};
pub use alias_record::{normalize_alias, AliasClaimStore, AliasPublishQuota, AliasRecord};
pub use contact_request::{ContactAcceptV1, ContactRequestInner, RavenContactRequestV1};
pub use discovery::{alias_hint_key, DiscoveryStore, PeerRecord, NAT_STATUS};
pub use discovery_resolver::{
    result_model_schema_keys, DiscoveryContext, DiscoveryResolver, DiscoveryResult, DiscoveryScope,
    DiscoverySource, LocalContactRow, VerificationState,
};
pub use introduction::{IntroductionInbox, RavenIntroductionV1};
pub use nearby::{NearbyAdvertisement, NearbyRegistry};
pub use profile_record::{ProfileStore, RavenProfileRecordV1};
pub use internet::{
    bits_to_caps, caps_to_bits, deframe_prefix, frame, opaque_store_tag, pack_hello,
    unpack_verify_hello, CAP_BLE, CAP_BRIDGE, CAP_INTERNET, CAP_RELAY, CAP_STORE,
    INTERNET_PROTO_ID, MAX_FRAME_BYTES,
};
pub use ipc::{
    decode_request, decode_response, default_socket_path, encode_request, encode_response,
    IpcRequest, IpcResponse, IPC_VERSION, MAX_IPC_FRAME,
};
pub use ble_adapter::{
    ble_frame_decode, ble_frame_encode, select_ble_adapter, select_ble_adapter_from_env,
    validate_opaque_rvn1, BleAdapterKind,
};
pub use chat_history::{
    blocked_path, history_path, BlockList, ChatHistory, ChatHistoryEntry,
};
pub use bridge::{
    classify_multi_role, decide as bridge_decide, opaque_acked_message_id, prepare_forward,
    split_replication, BridgeAction, BridgeRole, DropReason, EnvelopeIdentity, MultiRoleDisposition,
};
pub use envelope::{Envelope, EnvType};
pub use forward_queue::{
    ForwardItem, ForwardQueue, ForwardState, PeerRateDecision, MAX_FORWARD_QUEUE,
    MAX_PER_PEER_ENQUEUES_PER_WINDOW, MAX_PER_PEER_PENDING,
};
pub use identity::Identity;
pub use message_router::{InboundEnvelope, MessageRouter, RouterOutcome};
pub use node_policy::{
    load_policy, policy_path, save_policy, BridgeStatusSnapshot, NodePolicy,
};
pub use prekey_bundle::{PrekeyBundle, PrekeyBundleJson, PrekeyStore, MLKEM768_EK_LEN};
pub use queue::{DeliveryState, OutgoingQueue, QueueItem};
pub use sanitize::{had_dangerous_controls, sanitize_terminal_text, strip_ansi, strip_bidi};
pub use seal::{
    classify_sealed_body, derive_pairwise_key, parse_rvna1_header, rvna1_wire_plausible,
    seal_message, unseal_message, Rvna1Header, SealClass, ATSAM_PROTO_V1, ATSAM_PROTO_V2,
    SEAL_MAGIC_RVNA1, SEAL_MAGIC_RVNA1_STUB, STUB_PROTO,
};
pub use store_object::{
    mailbox_tag, mailbox_tags_with_overlap, store_tag_from_mailbox, StoreMailbox, StoreObject,
};
pub use transport::{
    prefer_transport, select_path, NodeCapability, PathChoice, PathContext, TransportKind,
    TransportPreference,
};
