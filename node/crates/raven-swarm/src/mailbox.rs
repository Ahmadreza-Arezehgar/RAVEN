//! Versioned, bounded libp2p transport for opaque Raven Store Object V1 rows.
//!
//! This module is compiled only with `experimental-offline-mailbox`. It has no
//! delete operation and accepts only endpoint-supplied 16-byte `store_tag`
//! capabilities; it never derives an index from an envelope routing tag.

use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use futures::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use libp2p::request_response::{self, ProtocolSupport};
use libp2p::StreamProtocol;
use raven_core::store_object::{
    StoreMailbox, StoreObject, MAX_ENVELOPE_LEN, MAX_STORE_BYTES, MAX_STORE_OBJECTS,
};
use sha2::{Digest, Sha256};

/// Multistream-select identifier. Any incompatible wire change gets a new path.
pub const MAILBOX_PROTOCOL_V1: StreamProtocol = StreamProtocol::new("/raven/offline-mailbox/1.0.0");
pub const MAILBOX_DB_FILENAME: &str = "offline_mailbox_v1.json";

pub const MAX_OBJECTS_PER_TAG: usize = 64;
pub const MAX_PAGE_OBJECTS: u16 = 16;
pub const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_REQUEST_SECONDS: u64 = 8;
pub const MAX_CONCURRENT_STREAMS: usize = 32;
pub const MAX_MAILBOX_TTL_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
pub const MAX_FUTURE_SKEW_MS: u64 = 5 * 60 * 1_000;

// RSO1 fixed prefix (59 B) plus the optional 64-byte custody signature.
pub const MAX_STORE_OBJECT_WIRE_BYTES: usize = MAX_ENVELOPE_LEN + 59 + 64;
// PUT opcode + u32 object length + the largest StoreObjectV1.
pub const MAX_REQUEST_BYTES: usize = MAX_STORE_OBJECT_WIRE_BYTES + 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MailboxRequest {
    Put(Vec<u8>),
    Get {
        store_tag: [u8; 16],
        after: Option<[u8; 32]>,
        limit: u16,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MailboxReject {
    Malformed = 1,
    StoreFull = 2,
    Expired = 3,
    Ttl = 4,
    Persistence = 5,
}

impl MailboxReject {
    fn from_u8(value: u8) -> io::Result<Self> {
        match value {
            1 => Ok(Self::Malformed),
            2 => Ok(Self::StoreFull),
            3 => Ok(Self::Expired),
            4 => Ok(Self::Ttl),
            5 => Ok(Self::Persistence),
            _ => Err(invalid_data("unknown mailbox rejection code")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MailboxResponse {
    Stored,
    Objects {
        /// Stable digest token for the next bounded page. It remains valid if
        /// an earlier row expires between requests.
        next_cursor: Option<[u8; 32]>,
        objects: Vec<Vec<u8>>,
    },
    Rejected(MailboxReject),
}

#[derive(Clone, Default)]
pub struct MailboxCodec;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MailboxRole {
    Server,
    Client,
    Full,
}

pub type MailboxBehaviour = request_response::Behaviour<MailboxCodec>;

pub fn mailbox_behaviour(role: MailboxRole) -> MailboxBehaviour {
    let support = match role {
        MailboxRole::Server => ProtocolSupport::Inbound,
        MailboxRole::Client => ProtocolSupport::Outbound,
        MailboxRole::Full => ProtocolSupport::Full,
    };
    let config = request_response::Config::default()
        .with_request_timeout(Duration::from_secs(MAX_REQUEST_SECONDS))
        .with_max_concurrent_streams(MAX_CONCURRENT_STREAMS);
    MailboxBehaviour::with_codec(MailboxCodec, [(MAILBOX_PROTOCOL_V1, support)], config)
}

fn invalid_data(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn invalid_input(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

fn take_u16(raw: &[u8], offset: &mut usize) -> io::Result<u16> {
    let end = offset
        .checked_add(2)
        .ok_or_else(|| invalid_data("mailbox integer overflow"))?;
    let bytes: [u8; 2] = raw
        .get(*offset..end)
        .ok_or_else(|| invalid_data("truncated mailbox frame"))?
        .try_into()
        .expect("checked fixed length");
    *offset = end;
    Ok(u16::from_be_bytes(bytes))
}

fn take_u32(raw: &[u8], offset: &mut usize) -> io::Result<u32> {
    let end = offset
        .checked_add(4)
        .ok_or_else(|| invalid_data("mailbox integer overflow"))?;
    let bytes: [u8; 4] = raw
        .get(*offset..end)
        .ok_or_else(|| invalid_data("truncated mailbox frame"))?
        .try_into()
        .expect("checked fixed length");
    *offset = end;
    Ok(u32::from_be_bytes(bytes))
}

async fn read_bounded<T>(io: &mut T, maximum: usize) -> io::Result<Vec<u8>>
where
    T: AsyncRead + Unpin + Send,
{
    let read_maximum = maximum
        .checked_add(1)
        .ok_or_else(|| invalid_input("mailbox frame limit overflow"))?;
    let mut raw = Vec::with_capacity(read_maximum.min(16 * 1024));
    io.take(read_maximum as u64).read_to_end(&mut raw).await?;
    if raw.len() > maximum {
        return Err(invalid_data("mailbox frame exceeds hard limit"));
    }
    Ok(raw)
}

fn encode_request(request: MailboxRequest) -> io::Result<Vec<u8>> {
    let mut raw = Vec::new();
    match request {
        MailboxRequest::Put(object) => {
            if object.len() > MAX_STORE_OBJECT_WIRE_BYTES {
                return Err(invalid_input("store object exceeds hard limit"));
            }
            let len = u32::try_from(object.len())
                .map_err(|_| invalid_input("store object length overflow"))?;
            raw.push(1);
            raw.extend_from_slice(&len.to_be_bytes());
            raw.extend_from_slice(&object);
        }
        MailboxRequest::Get {
            store_tag,
            after,
            limit,
        } => {
            if limit == 0 || limit > MAX_PAGE_OBJECTS {
                return Err(invalid_input("invalid mailbox page limit"));
            }
            raw.push(2);
            raw.extend_from_slice(&store_tag);
            match after {
                Some(token) => {
                    raw.push(1);
                    raw.extend_from_slice(&token);
                }
                None => {
                    raw.push(0);
                    raw.extend_from_slice(&[0u8; 32]);
                }
            }
            raw.extend_from_slice(&limit.to_be_bytes());
        }
    }
    if raw.len() > MAX_REQUEST_BYTES {
        return Err(invalid_input("mailbox request exceeds hard limit"));
    }
    Ok(raw)
}

fn decode_request(raw: &[u8]) -> io::Result<MailboxRequest> {
    let Some(opcode) = raw.first().copied() else {
        return Err(invalid_data("empty mailbox request"));
    };
    match opcode {
        1 => {
            let mut offset = 1;
            let length = take_u32(raw, &mut offset)? as usize;
            if length > MAX_STORE_OBJECT_WIRE_BYTES {
                return Err(invalid_data("store object exceeds hard limit"));
            }
            let end = offset
                .checked_add(length)
                .ok_or_else(|| invalid_data("store object length overflow"))?;
            if end != raw.len() {
                return Err(invalid_data("store object length mismatch"));
            }
            Ok(MailboxRequest::Put(raw[offset..end].to_vec()))
        }
        2 => {
            if raw.len() != 1 + 16 + 1 + 32 + 2 {
                return Err(invalid_data("invalid mailbox get length"));
            }
            let mut store_tag = [0u8; 16];
            store_tag.copy_from_slice(&raw[1..17]);
            let has_after = raw[17];
            if has_after > 1 {
                return Err(invalid_data("invalid mailbox continuation flag"));
            }
            let mut token = [0u8; 32];
            token.copy_from_slice(&raw[18..50]);
            if has_after == 0 && token != [0u8; 32] {
                return Err(invalid_data("noncanonical empty continuation"));
            }
            let mut offset = 50;
            let limit = take_u16(raw, &mut offset)?;
            if limit == 0 || limit > MAX_PAGE_OBJECTS {
                return Err(invalid_data("invalid mailbox page limit"));
            }
            Ok(MailboxRequest::Get {
                store_tag,
                after: (has_after == 1).then_some(token),
                limit,
            })
        }
        _ => Err(invalid_data("unknown mailbox request opcode")),
    }
}

fn encode_response(response: MailboxResponse) -> io::Result<Vec<u8>> {
    let mut raw = Vec::new();
    match response {
        MailboxResponse::Stored => raw.push(0),
        MailboxResponse::Objects {
            next_cursor,
            objects,
        } => {
            if objects.len() > MAX_PAGE_OBJECTS as usize {
                return Err(invalid_input("too many mailbox response objects"));
            }
            canonical_page(next_cursor, &objects).map_err(invalid_input)?;
            raw.push(1);
            match next_cursor {
                Some(token) => {
                    raw.push(1);
                    raw.extend_from_slice(&token);
                }
                None => {
                    raw.push(0);
                    raw.extend_from_slice(&[0u8; 32]);
                }
            }
            raw.extend_from_slice(&(objects.len() as u16).to_be_bytes());
            for object in objects {
                if object.len() > MAX_STORE_OBJECT_WIRE_BYTES {
                    return Err(invalid_input("response store object exceeds hard limit"));
                }
                let length = u32::try_from(object.len())
                    .map_err(|_| invalid_input("response object length overflow"))?;
                raw.extend_from_slice(&length.to_be_bytes());
                raw.extend_from_slice(&object);
            }
        }
        MailboxResponse::Rejected(code) => {
            raw.push(2);
            raw.push(code as u8);
        }
    }
    if raw.len() > MAX_RESPONSE_BYTES {
        return Err(invalid_input("mailbox response exceeds hard limit"));
    }
    Ok(raw)
}

fn decode_response(raw: &[u8]) -> io::Result<MailboxResponse> {
    let Some(opcode) = raw.first().copied() else {
        return Err(invalid_data("empty mailbox response"));
    };
    match opcode {
        0 if raw.len() == 1 => Ok(MailboxResponse::Stored),
        1 => {
            if raw.len() < 1 + 1 + 32 + 2 {
                return Err(invalid_data("truncated mailbox objects response"));
            }
            let has_cursor = raw[1];
            if has_cursor > 1 {
                return Err(invalid_data("invalid mailbox cursor flag"));
            }
            let mut cursor = [0u8; 32];
            cursor.copy_from_slice(&raw[2..34]);
            if has_cursor == 0 && cursor != [0u8; 32] {
                return Err(invalid_data("noncanonical empty cursor"));
            }
            let mut offset = 34;
            let count = take_u16(raw, &mut offset)?;
            if count > MAX_PAGE_OBJECTS {
                return Err(invalid_data("too many mailbox response objects"));
            }
            let mut objects = Vec::with_capacity(count as usize);
            for _ in 0..count {
                let length = take_u32(raw, &mut offset)? as usize;
                if length > MAX_STORE_OBJECT_WIRE_BYTES {
                    return Err(invalid_data("response store object exceeds hard limit"));
                }
                let end = offset
                    .checked_add(length)
                    .ok_or_else(|| invalid_data("response object length overflow"))?;
                let object = raw
                    .get(offset..end)
                    .ok_or_else(|| invalid_data("truncated response object"))?;
                objects.push(object.to_vec());
                offset = end;
            }
            if offset != raw.len() {
                return Err(invalid_data("trailing mailbox response bytes"));
            }
            let next_cursor = (has_cursor == 1).then_some(cursor);
            canonical_page(next_cursor, &objects).map_err(invalid_data)?;
            Ok(MailboxResponse::Objects {
                next_cursor,
                objects,
            })
        }
        2 if raw.len() == 2 => Ok(MailboxResponse::Rejected(MailboxReject::from_u8(raw[1])?)),
        _ => Err(invalid_data("invalid mailbox response opcode")),
    }
}

fn canonical_page(next_cursor: Option<[u8; 32]>, objects: &[Vec<u8>]) -> Result<(), &'static str> {
    let mut previous = None;
    for object in objects {
        StoreObject::unpack(object).map_err(|_| "invalid response StoreObjectV1")?;
        let token = page_token(object);
        if previous.is_some_and(|value| value >= token) {
            return Err("noncanonical mailbox object order");
        }
        previous = Some(token);
    }
    if let Some(cursor) = next_cursor {
        if previous != Some(cursor) {
            return Err("mailbox cursor is not bound to the last object");
        }
    }
    Ok(())
}

#[async_trait]
impl request_response::Codec for MailboxCodec {
    type Protocol = StreamProtocol;
    type Request = MailboxRequest;
    type Response = MailboxResponse;

    async fn read_request<T>(&mut self, _: &Self::Protocol, io: &mut T) -> io::Result<Self::Request>
    where
        T: AsyncRead + Unpin + Send,
    {
        decode_request(&read_bounded(io, MAX_REQUEST_BYTES).await?)
    }

    async fn read_response<T>(
        &mut self,
        _: &Self::Protocol,
        io: &mut T,
    ) -> io::Result<Self::Response>
    where
        T: AsyncRead + Unpin + Send,
    {
        decode_response(&read_bounded(io, MAX_RESPONSE_BYTES).await?)
    }

    async fn write_request<T>(
        &mut self,
        _: &Self::Protocol,
        io: &mut T,
        request: Self::Request,
    ) -> io::Result<()>
    where
        T: AsyncWrite + Unpin + Send,
    {
        io.write_all(&encode_request(request)?).await
    }

    async fn write_response<T>(
        &mut self,
        _: &Self::Protocol,
        io: &mut T,
        response: Self::Response,
    ) -> io::Result<()>
    where
        T: AsyncWrite + Unpin + Send,
    {
        io.write_all(&encode_response(response)?).await
    }
}

pub struct MailboxService {
    mailbox: StoreMailbox,
    path: PathBuf,
    available: bool,
}

impl MailboxService {
    pub fn open(data_dir: &Path) -> Result<Self, String> {
        let path = data_dir.join(MAILBOX_DB_FILENAME);
        let mailbox = StoreMailbox::load_disk(&path, MAX_OBJECTS_PER_TAG)?;
        Ok(Self {
            mailbox,
            path,
            available: true,
        })
    }

    pub fn handle(&mut self, request: MailboxRequest, now_ms: u64) -> MailboxResponse {
        if !self.available {
            return MailboxResponse::Rejected(MailboxReject::Persistence);
        }
        match request {
            MailboxRequest::Put(raw) => self.put(raw, now_ms),
            MailboxRequest::Get {
                store_tag,
                after,
                limit,
            } => self.get(store_tag, after, limit, now_ms),
        }
    }

    fn persist(&mut self) -> Result<(), MailboxReject> {
        if self.mailbox.save_disk(&self.path).is_ok() {
            return Ok(());
        }
        // Never acknowledge a row that was not durably committed. Reloading
        // the last atomic snapshot also removes the uncommitted in-memory row.
        match StoreMailbox::load_disk(&self.path, MAX_OBJECTS_PER_TAG) {
            Ok(previous) => self.mailbox = previous,
            Err(_) => self.available = false,
        }
        Err(MailboxReject::Persistence)
    }

    fn put(&mut self, raw: Vec<u8>, now_ms: u64) -> MailboxResponse {
        if raw.len() > MAX_STORE_OBJECT_WIRE_BYTES {
            return MailboxResponse::Rejected(MailboxReject::Malformed);
        }
        let object = match StoreObject::unpack(&raw) {
            Ok(object) => object,
            Err(_) => return MailboxResponse::Rejected(MailboxReject::Malformed),
        };
        if object.expired(now_ms) {
            return MailboxResponse::Rejected(MailboxReject::Expired);
        }
        let latest_allowed = match now_ms.checked_add(MAX_MAILBOX_TTL_MS) {
            Some(value) => value,
            None => return MailboxResponse::Rejected(MailboxReject::Ttl),
        };
        let future_creation = match now_ms.checked_add(MAX_FUTURE_SKEW_MS) {
            Some(value) => value,
            None => return MailboxResponse::Rejected(MailboxReject::Ttl),
        };
        if object.expires_at_ms > latest_allowed || object.created_at_ms > future_creation {
            return MailboxResponse::Rejected(MailboxReject::Ttl);
        }
        self.mailbox.purge_expired(now_ms);
        match self.mailbox.put(object) {
            Ok(()) => match self.persist() {
                Ok(()) => MailboxResponse::Stored,
                Err(code) => MailboxResponse::Rejected(code),
            },
            Err(error) if error == "STORE_FULL" => {
                MailboxResponse::Rejected(MailboxReject::StoreFull)
            }
            Err(error) if error == "STORE_EXPIRED" => {
                MailboxResponse::Rejected(MailboxReject::Expired)
            }
            Err(_) => MailboxResponse::Rejected(MailboxReject::Malformed),
        }
    }

    fn get(
        &mut self,
        store_tag: [u8; 16],
        after: Option<[u8; 32]>,
        limit: u16,
        now_ms: u64,
    ) -> MailboxResponse {
        if limit == 0 || limit > MAX_PAGE_OBJECTS {
            return MailboxResponse::Rejected(MailboxReject::Malformed);
        }
        if self.mailbox.purge_expired(now_ms) > 0 && self.persist().is_err() {
            return MailboxResponse::Rejected(MailboxReject::Persistence);
        }
        let mut matches: Vec<([u8; 32], Vec<u8>)> = match self
            .mailbox
            .get(&store_tag, now_ms)
            .into_iter()
            .map(|object| object.pack().map(|packed| (page_token(&packed), packed)))
            .collect::<Result<Vec<_>, _>>()
        {
            Ok(values) => values,
            Err(_) => return MailboxResponse::Rejected(MailboxReject::Persistence),
        };
        matches.sort_unstable_by_key(|(token, _)| *token);
        if let Some(after) = after {
            matches.retain(|(token, _)| *token > after);
        }
        if matches.is_empty() {
            return MailboxResponse::Objects {
                next_cursor: None,
                objects: Vec::new(),
            };
        }

        let mut objects = Vec::new();
        let mut last_token = None;
        let mut encoded_bytes: usize = 1 + 1 + 32 + 2;
        for (token, packed) in matches.iter().take(limit as usize) {
            let next_size = match encoded_bytes.checked_add(4 + packed.len()) {
                Some(value) => value,
                None => break,
            };
            if next_size > MAX_RESPONSE_BYTES {
                break;
            }
            encoded_bytes = next_size;
            objects.push(packed.clone());
            last_token = Some(*token);
        }
        let next_cursor = if objects.len() < matches.len() {
            last_token
        } else {
            None
        };
        MailboxResponse::Objects {
            next_cursor,
            objects,
        }
    }

    pub fn resource_limits() -> (usize, usize, usize) {
        (MAX_OBJECTS_PER_TAG, MAX_STORE_OBJECTS, MAX_STORE_BYTES)
    }
}

fn page_token(packed_object: &[u8]) -> [u8; 32] {
    let mut hash = Sha256::new();
    hash.update(b"raven/offline-mailbox/page-token/v1");
    hash.update(packed_object);
    hash.finalize().into()
}

pub fn unix_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use futures::{io::Cursor, StreamExt};
    use libp2p::identity::Keypair;
    use libp2p::multiaddr::Protocol;
    use libp2p::request_response::{Event, Message};
    use libp2p::swarm::SwarmEvent;
    use libp2p::{noise, tcp, yamux, Multiaddr, Swarm, SwarmBuilder};
    use raven_core::envelope::{EnvType, Envelope};
    use raven_core::identity::Identity;

    use super::*;

    fn valid_store_object(now: u64, body: &[u8]) -> Vec<u8> {
        let signer = Identity::from_seed(&[0x31; 32]);
        let mut envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id: [0x42; 16],
            routing_tag: [0x99; 16],
            dest_device_hint: 7,
            created_at: now,
            expires_at: now + 60_000,
            hop_limit: 4,
            replication_budget: 2,
            anti_replay_nonce: [0x18; 12],
            ratchet_header_ciphertext: Vec::new(),
            message_ciphertext: body.to_vec(),
            sender_authentication: Vec::new(),
        };
        envelope.sign_with(&signer);
        StoreObject {
            store_tag: [0x77; 16],
            message_id: envelope.message_id,
            created_at_ms: now,
            expires_at_ms: now + 60_000,
            flags: 0,
            packed_envelope: envelope.pack(),
            custody_sig: None,
        }
        .pack()
        .unwrap()
    }

    fn test_swarm(role: MailboxRole, seed: [u8; 32]) -> Swarm<MailboxBehaviour> {
        let keypair = Keypair::ed25519_from_bytes(seed).unwrap();
        SwarmBuilder::with_existing_identity(keypair)
            .with_tokio()
            .with_tcp(
                tcp::Config::default().nodelay(true),
                noise::Config::new,
                yamux::Config::default,
            )
            .unwrap()
            .with_behaviour(|_| mailbox_behaviour(role))
            .unwrap()
            .with_swarm_config(|config| {
                config.with_idle_connection_timeout(Duration::from_secs(10))
            })
            .build()
    }

    async fn listen_address(server: &mut Swarm<MailboxBehaviour>) -> Multiaddr {
        server
            .listen_on("/ip4/127.0.0.1/tcp/0".parse().unwrap())
            .unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let SwarmEvent::NewListenAddr { address, .. } = server.select_next_some().await {
                    return address;
                }
            }
        })
        .await
        .expect("server listen timeout")
    }

    async fn network_round_trip(
        server: &mut Swarm<MailboxBehaviour>,
        client: &mut Swarm<MailboxBehaviour>,
        service: &mut MailboxService,
        request: MailboxRequest,
    ) -> MailboxResponse {
        let server_peer = *server.local_peer_id();
        if !client.is_connected(&server_peer) {
            let existing_address = server.listeners().next().cloned();
            let address = match existing_address {
                Some(address) => address,
                None => listen_address(server).await,
            };
            client
                .dial(address.with(Protocol::P2p(server_peer)))
                .unwrap();
        }
        let request_id = client.behaviour_mut().send_request(&server_peer, request);

        tokio::time::timeout(Duration::from_secs(8), async {
            loop {
                tokio::select! {
                    event = server.select_next_some() => {
                        if let SwarmEvent::Behaviour(Event::Message {
                            message: Message::Request { request, channel, .. },
                            ..
                        }) = event {
                            let response = service.handle(request, unix_time_ms());
                            server.behaviour_mut().send_response(channel, response).unwrap();
                        }
                    }
                    event = client.select_next_some() => {
                        match event {
                            SwarmEvent::Behaviour(Event::Message {
                                message: Message::Response {
                                    request_id: got_id,
                                    response,
                                },
                                ..
                            }) if got_id == request_id => return response,
                            SwarmEvent::Behaviour(Event::OutboundFailure {
                                request_id: got_id,
                                error,
                                ..
                            }) if got_id == request_id => panic!("mailbox request failed: {error}"),
                            _ => {}
                        }
                    }
                }
            }
        })
        .await
        .expect("mailbox round trip timeout")
    }

    #[tokio::test]
    async fn codec_rejects_oversize_and_noncanonical_frames() {
        use libp2p::request_response::Codec as _;

        let mut codec = MailboxCodec;
        let mut output = Cursor::new(Vec::new());
        let error = codec
            .write_request(
                &MAILBOX_PROTOCOL_V1,
                &mut output,
                MailboxRequest::Put(vec![0; MAX_STORE_OBJECT_WIRE_BYTES + 1]),
            )
            .await
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);

        let mut oversized_wire = Cursor::new(vec![0; MAX_REQUEST_BYTES + 1]);
        let error = codec
            .read_request(&MAILBOX_PROTOCOL_V1, &mut oversized_wire)
            .await
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);

        assert!(decode_request(&[2; 24]).is_err());
        assert!(decode_response(&[0, 0]).is_err());
    }

    #[test]
    fn request_and_response_wire_roundtrip_is_canonical() {
        let request = MailboxRequest::Get {
            store_tag: [7; 16],
            after: Some([8; 32]),
            limit: 3,
        };
        assert_eq!(
            decode_request(&encode_request(request.clone()).unwrap()).unwrap(),
            request
        );

        let object = valid_store_object(unix_time_ms(), b"wire-roundtrip");
        let response = MailboxResponse::Objects {
            next_cursor: Some(page_token(&object)),
            objects: vec![object],
        };
        assert_eq!(
            decode_response(&encode_response(response.clone()).unwrap()).unwrap(),
            response
        );

        assert!(encode_response(MailboxResponse::Objects {
            next_cursor: Some([0; 32]),
            objects: Vec::new(),
        })
        .is_err());
        assert!(encode_response(MailboxResponse::Objects {
            next_cursor: None,
            objects: vec![b"not-rso1".to_vec()],
        })
        .is_err());
    }

    #[tokio::test]
    async fn localhost_put_survives_sender_disconnect_and_store_restart() {
        let directory = tempfile::tempdir().unwrap();
        let now = unix_time_ms();
        let opaque_object = valid_store_object(now, b"opaque-network-ciphertext");

        let mut first_server = test_swarm(MailboxRole::Server, [1; 32]);
        let mut sender = test_swarm(MailboxRole::Client, [2; 32]);
        let mut first_service = MailboxService::open(directory.path()).unwrap();

        let malformed = network_round_trip(
            &mut first_server,
            &mut sender,
            &mut first_service,
            MailboxRequest::Put(b"not-rso1".to_vec()),
        )
        .await;
        assert_eq!(
            malformed,
            MailboxResponse::Rejected(MailboxReject::Malformed)
        );

        // The request crosses the libp2p stream, but strict StoreObject parsing
        // rejects its attacker-controlled envelope length before allocation.
        let mut declared_oversize = vec![0u8; 59];
        declared_oversize[..4].copy_from_slice(b"RSO1");
        declared_oversize[4] = 1;
        declared_oversize[55..59].copy_from_slice(&((MAX_ENVELOPE_LEN as u32) + 1).to_be_bytes());
        let oversize = network_round_trip(
            &mut first_server,
            &mut sender,
            &mut first_service,
            MailboxRequest::Put(declared_oversize),
        )
        .await;
        assert_eq!(
            oversize,
            MailboxResponse::Rejected(MailboxReject::Malformed)
        );

        let stored = network_round_trip(
            &mut first_server,
            &mut sender,
            &mut first_service,
            MailboxRequest::Put(opaque_object.clone()),
        )
        .await;
        assert_eq!(stored, MailboxResponse::Stored);

        // Sender is gone before retrieval. Reopening both the service and its
        // libp2p listener proves retrieval comes from the crash-safe snapshot.
        drop(sender);
        drop(first_server);
        drop(first_service);

        let mut restarted_server = test_swarm(MailboxRole::Server, [1; 32]);
        let mut recipient = test_swarm(MailboxRole::Client, [3; 32]);
        let mut restarted_service = MailboxService::open(directory.path()).unwrap();
        let response = network_round_trip(
            &mut restarted_server,
            &mut recipient,
            &mut restarted_service,
            MailboxRequest::Get {
                store_tag: [0x77; 16],
                after: None,
                limit: MAX_PAGE_OBJECTS,
            },
        )
        .await;
        assert_eq!(
            response,
            MailboxResponse::Objects {
                next_cursor: None,
                objects: vec![opaque_object],
            }
        );
    }

    #[test]
    fn service_rejects_declared_oversize_and_excess_ttl() {
        let directory = tempfile::tempdir().unwrap();
        let now = unix_time_ms();
        let mut service = MailboxService::open(directory.path()).unwrap();

        let mut declared_oversize = vec![0u8; 59];
        declared_oversize[..4].copy_from_slice(b"RSO1");
        declared_oversize[4] = 1;
        declared_oversize[55..59].copy_from_slice(&((MAX_ENVELOPE_LEN as u32) + 1).to_be_bytes());
        assert_eq!(
            service.handle(MailboxRequest::Put(declared_oversize), now),
            MailboxResponse::Rejected(MailboxReject::Malformed)
        );

        let object = StoreObject::unpack(&valid_store_object(now, b"ttl")).unwrap();
        let mut long_lived = StoreObject {
            expires_at_ms: now + MAX_MAILBOX_TTL_MS + 1,
            ..object
        };
        let mut envelope =
            raven_core::envelope::Envelope::unpack(&long_lived.packed_envelope).unwrap();
        envelope.expires_at = long_lived.expires_at_ms;
        envelope.sign_with(&Identity::from_seed(&[0x31; 32]));
        long_lived.packed_envelope = envelope.pack();
        assert_eq!(
            service.handle(MailboxRequest::Put(long_lived.pack().unwrap()), now),
            MailboxResponse::Rejected(MailboxReject::Ttl)
        );
    }

    #[test]
    fn bounded_pages_resume_with_stable_digest_token() {
        let directory = tempfile::tempdir().unwrap();
        let now = unix_time_ms();
        let mut service = MailboxService::open(directory.path()).unwrap();
        let mut expected = Vec::new();
        for value in 0..17u8 {
            let object = valid_store_object(now, &[value]);
            assert_eq!(
                service.handle(MailboxRequest::Put(object.clone()), now),
                MailboxResponse::Stored
            );
            expected.push(object);
        }

        let (cursor, mut received) = match service.handle(
            MailboxRequest::Get {
                store_tag: [0x77; 16],
                after: None,
                limit: MAX_PAGE_OBJECTS,
            },
            now,
        ) {
            MailboxResponse::Objects {
                next_cursor: Some(cursor),
                objects,
            } => (cursor, objects),
            other => panic!("unexpected first page: {other:?}"),
        };
        match service.handle(
            MailboxRequest::Get {
                store_tag: [0x77; 16],
                after: Some(cursor),
                limit: MAX_PAGE_OBJECTS,
            },
            now,
        ) {
            MailboxResponse::Objects {
                next_cursor: None,
                mut objects,
            } => received.append(&mut objects),
            other => panic!("unexpected second page: {other:?}"),
        }

        expected.sort();
        received.sort();
        assert_eq!(received, expected);
    }
}
