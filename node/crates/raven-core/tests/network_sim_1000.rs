//! Deterministic 1,000-node delay-tolerant transport simulation.
//!
//! This is bounded model evidence, not a live libp2p, NAT, BLE, storage, or
//! cryptographic-session test. Relays handle exact opaque RVN1 bytes and dedup
//! exclusively by SHA-256(object bytes). The endpoint oracle below stands in
//! for ATSAM decrypt/authenticate/durable-commit while still requiring strict
//! RavenEnvelopeV1 decoding and a valid outer Ed25519 signature.

#![allow(clippy::too_many_lines)]

use raven_core::envelope::{EnvType, Envelope, MAX_WIRE_ENVELOPE_BYTES, PREFIX_LEN};
use raven_core::identity::Identity;
use sha2::{Digest as _, Sha256};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, BinaryHeap, VecDeque};
use std::sync::Arc;

const NODE_COUNT: usize = 1_000;
const NODE_QUEUE_CAP: usize = 8;
const NODE_SEEN_CAP: usize = 32;
const MAX_OBJECTS_PER_CONTACT: usize = 4;
const MAX_EVENT_QUEUE: usize = 10_000;
const MAX_EVENTS_PROCESSED: u64 = 50_000;
const MAX_SIM_OBJECT_BYTES: usize = 4_096;
const DEFAULT_EXPIRY_TICK: u64 = 20_000;
const INITIAL_HOPS: u8 = 32;
const INITIAL_REPLICAS: u8 = 16;
const MAX_BACKOFF_TICKS: u64 = 64;
const ADVERSARIAL_DUPLICATION_FACTOR: usize = 4;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct ObjectDigest([u8; 32]);

impl ObjectDigest {
    fn of(bytes: &[u8]) -> Self {
        Self(Sha256::digest(bytes).into())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TransportClass {
    Internet,
    LocalRadio,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum RelayBehavior {
    #[default]
    Honest,
    Drop,
    Replay,
    Delay,
    Duplicate,
    Mutate,
}

#[derive(Clone, Debug)]
struct Replica {
    bytes: Arc<[u8]>,
    digest: ObjectDigest,
    expires_at: u64,
    hops_left: u8,
    copies_left: u8,
    attempts: u8,
    next_attempt: u64,
    sent_to: BTreeSet<usize>,
}

impl Replica {
    fn new(bytes: Arc<[u8]>, expires_at: u64) -> Self {
        assert!(bytes.len() <= MAX_WIRE_ENVELOPE_BYTES);
        assert!(bytes.len() <= MAX_SIM_OBJECT_BYTES);
        Self {
            digest: ObjectDigest::of(&bytes),
            bytes,
            expires_at,
            hops_left: INITIAL_HOPS,
            copies_left: INITIAL_REPLICAS,
            attempts: 0,
            next_attempt: 0,
            sent_to: BTreeSet::new(),
        }
    }

    fn forwarded(&self) -> Self {
        Self {
            bytes: Arc::clone(&self.bytes),
            digest: self.digest,
            expires_at: self.expires_at,
            hops_left: self.hops_left.saturating_sub(1),
            copies_left: (self.copies_left / 2).max(1),
            attempts: 0,
            next_attempt: 0,
            sent_to: BTreeSet::new(),
        }
    }
}

#[derive(Clone, Debug)]
struct PersistedReplica {
    bytes: Vec<u8>,
    expires_at: u64,
    hops_left: u8,
    copies_left: u8,
    attempts: u8,
    next_attempt: u64,
    sent_to: BTreeSet<usize>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AdmissionOutcome {
    Accepted,
    Duplicate,
    Full,
}

#[derive(Debug)]
struct Node {
    online: bool,
    partition_group: u8,
    behavior: RelayBehavior,
    queue: VecDeque<Replica>,
    seen: BTreeMap<ObjectDigest, u64>,
}

impl Node {
    fn new(id: usize) -> Self {
        Self {
            online: true,
            partition_group: u8::from(id >= NODE_COUNT / 2),
            behavior: RelayBehavior::Honest,
            queue: VecDeque::new(),
            seen: BTreeMap::new(),
        }
    }

    fn purge_expired(&mut self, now: u64) {
        self.queue.retain(|item| item.expires_at > now);
        self.seen.retain(|_, expires_at| *expires_at > now);
    }
}

#[derive(Clone, Copy, Debug)]
struct Contact {
    a: usize,
    b: usize,
    transport: TransportClass,
    latency: u64,
    jitter: u64,
    contact_loss_per_10k: u16,
    packet_loss_per_10k: u16,
}

#[derive(Clone, Copy, Debug)]
struct ContactProfile {
    transport_override: Option<TransportClass>,
    latency: u64,
    jitter: u64,
    contact_loss_per_10k: u16,
    packet_loss_per_10k: u16,
}

impl ContactProfile {
    const fn reliable(latency: u64) -> Self {
        Self {
            transport_override: None,
            latency,
            jitter: 0,
            contact_loss_per_10k: 0,
            packet_loss_per_10k: 0,
        }
    }

    const fn jittered(latency: u64, jitter: u64) -> Self {
        Self {
            jitter,
            ..Self::reliable(latency)
        }
    }

    const fn lossy(
        latency: u64,
        jitter: u64,
        contact_loss_per_10k: u16,
        packet_loss_per_10k: u16,
    ) -> Self {
        Self {
            transport_override: None,
            latency,
            jitter,
            contact_loss_per_10k,
            packet_loss_per_10k,
        }
    }

    const fn bridged(transport: TransportClass, latency: u64) -> Self {
        Self {
            transport_override: Some(transport),
            ..Self::reliable(latency)
        }
    }
}

#[derive(Clone, Debug)]
enum EventKind {
    SetOnline {
        node: usize,
        online: bool,
    },
    SetPartitioned(bool),
    Contact(Contact),
    Transfer {
        from: usize,
        to: usize,
        transport: TransportClass,
        replica: Replica,
    },
    Restart(usize),
    SweepAll,
}

#[derive(Clone, Debug)]
struct ScheduledEvent {
    at: u64,
    sequence: u64,
    kind: EventKind,
}

impl PartialEq for ScheduledEvent {
    fn eq(&self, other: &Self) -> bool {
        self.at == other.at && self.sequence == other.sequence
    }
}

impl Eq for ScheduledEvent {}

impl PartialOrd for ScheduledEvent {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ScheduledEvent {
    fn cmp(&self, other: &Self) -> Ordering {
        // BinaryHeap is a max-heap; reverse time and sequence for stable FIFO.
        other
            .at
            .cmp(&self.at)
            .then_with(|| other.sequence.cmp(&self.sequence))
    }
}

#[derive(Clone, Copy, Debug)]
struct DeterministicRng(u64);

impl DeterministicRng {
    fn new(seed: u64) -> Self {
        Self(seed)
    }

    fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn index(&mut self, upper_exclusive: usize) -> usize {
        assert!(upper_exclusive > 0);
        (self.next_u64() % upper_exclusive as u64) as usize
    }

    fn draw_per_10k(&mut self, rate: u16) -> bool {
        rate != 0 && self.next_u64() % 10_000 < u64::from(rate)
    }
}

#[derive(Debug)]
struct Topology {
    adjacency: Vec<Vec<usize>>,
    transports: BTreeMap<(usize, usize), TransportClass>,
}

impl Topology {
    fn seeded(seed: u64) -> Self {
        let mut edges = BTreeSet::new();
        for node in 0..NODE_COUNT {
            Self::insert_edge(&mut edges, node, (node + 1) % NODE_COUNT);
            Self::insert_edge(&mut edges, node, (node + 37) % NODE_COUNT);
            Self::insert_edge(&mut edges, node, (node + 211) % NODE_COUNT);
        }

        let mut rng = DeterministicRng::new(seed ^ 0x746f_706f_6c6f_6779);
        for node in 0..NODE_COUNT {
            for _ in 0..3 {
                let mut peer = rng.index(NODE_COUNT);
                if peer == node {
                    peer = (peer + 1) % NODE_COUNT;
                }
                Self::insert_edge(&mut edges, node, peer);
            }
        }

        let mut adjacency = vec![Vec::new(); NODE_COUNT];
        let mut transports = BTreeMap::new();
        for &(a, b) in &edges {
            adjacency[a].push(b);
            adjacency[b].push(a);
            let selector = seeded_word(seed, a as u64, b as u64, 0);
            let transport = if selector & 1 == 0 {
                TransportClass::Internet
            } else {
                TransportClass::LocalRadio
            };
            transports.insert((a, b), transport);
        }
        for peers in &mut adjacency {
            peers.sort_unstable();
            peers.dedup();
        }

        let topology = Self {
            adjacency,
            transports,
        };
        assert_eq!(topology.adjacency.len(), NODE_COUNT);
        topology
    }

    fn insert_edge(edges: &mut BTreeSet<(usize, usize)>, a: usize, b: usize) {
        if a != b {
            edges.insert(ordered_pair(a, b));
        }
    }

    fn has_edge(&self, a: usize, b: usize) -> bool {
        self.transports.contains_key(&ordered_pair(a, b))
    }

    fn transport(&self, a: usize, b: usize) -> TransportClass {
        self.transports[&ordered_pair(a, b)]
    }

    fn shortest_path(
        &self,
        source: usize,
        destination: usize,
        excluded: &BTreeSet<usize>,
    ) -> Vec<usize> {
        assert!(!excluded.contains(&source));
        assert!(!excluded.contains(&destination));
        let mut parent = vec![usize::MAX; NODE_COUNT];
        let mut pending = VecDeque::from([source]);
        parent[source] = source;
        while let Some(node) = pending.pop_front() {
            if node == destination {
                break;
            }
            for &peer in &self.adjacency[node] {
                if parent[peer] == usize::MAX && !excluded.contains(&peer) {
                    parent[peer] = node;
                    pending.push_back(peer);
                }
            }
        }
        assert_ne!(
            parent[destination],
            usize::MAX,
            "seeded graph has no permitted path"
        );
        let mut path = vec![destination];
        while *path.last().expect("path is non-empty") != source {
            path.push(parent[*path.last().expect("path is non-empty")]);
        }
        path.reverse();
        path
    }
}

#[derive(Clone, Debug)]
struct Fixture {
    message_bytes: Arc<[u8]>,
    message_digest: ObjectDigest,
    message_id: [u8; 16],
    routing_tag: [u8; 16],
    sender_public: [u8; 32],
    recipient_seed: [u8; 32],
    recipient_public: [u8; 32],
    expires_at: u64,
}

impl Fixture {
    fn signed(seed: u64, expires_at: u64) -> Self {
        assert!(expires_at > 1);
        let sender_seed = deterministic_seed(seed, 0x7365_6e64_6572);
        let recipient_seed = deterministic_seed(seed, 0x7265_6369_7069_656e);
        let sender = Identity::from_seed(&sender_seed);
        let recipient = Identity::from_seed(&recipient_seed);
        let mut rng = DeterministicRng::new(seed ^ 0x0066_6978_7475_7265);
        let mut message_id = [0u8; 16];
        let mut routing_tag = [0u8; 16];
        fill_deterministic(&mut rng, &mut message_id);
        fill_deterministic(&mut rng, &mut routing_tag);
        let mut header = vec![0u8; 48];
        let mut ciphertext = vec![0u8; 512];
        fill_deterministic(&mut rng, &mut header);
        fill_deterministic(&mut rng, &mut ciphertext);
        let mut envelope = Envelope {
            env_type: EnvType::Message as u8,
            flags: 0,
            message_id,
            routing_tag,
            dest_device_hint: 0,
            created_at: 1,
            expires_at,
            hop_limit: INITIAL_HOPS,
            replication_budget: INITIAL_REPLICAS,
            anti_replay_nonce: deterministic_nonce(&mut rng),
            ratchet_header_ciphertext: header,
            message_ciphertext: ciphertext,
            sender_authentication: Vec::new(),
        };
        envelope.sign_with(&sender);
        let bytes: Arc<[u8]> = envelope.pack().into();
        let decoded = Envelope::unpack(&bytes).expect("fixture is strict RVN1");
        assert!(decoded.verify(&sender.public_key_bytes()));
        assert_eq!(decoded.pack().as_slice(), bytes.as_ref());
        Self {
            message_digest: ObjectDigest::of(&bytes),
            message_bytes: bytes,
            message_id,
            routing_tag,
            sender_public: sender.public_key_bytes(),
            recipient_seed,
            recipient_public: recipient.public_key_bytes(),
            expires_at,
        }
    }

    fn materialize_ack(&self, committed_at: u64) -> Arc<[u8]> {
        assert!(committed_at < self.expires_at);
        let recipient = Identity::from_seed(&self.recipient_seed);
        let mut opaque_ack_body = vec![0u8; 96];
        opaque_ack_body[..32].copy_from_slice(&self.message_digest.0);
        let binding: [u8; 32] = Sha256::digest(b"raven-network-sim-ack-oracle-v1").into();
        opaque_ack_body[32..64].copy_from_slice(&binding);
        opaque_ack_body[64..].copy_from_slice(&Sha256::digest(&self.message_bytes));
        let mut ack = Envelope {
            env_type: EnvType::Ack as u8,
            flags: 0,
            message_id: self.message_id,
            routing_tag: [0xa5; 16],
            dest_device_hint: 0,
            created_at: committed_at,
            expires_at: self.expires_at,
            hop_limit: INITIAL_HOPS,
            replication_budget: INITIAL_REPLICAS,
            anti_replay_nonce: [0x5a; 12],
            ratchet_header_ciphertext: vec![0x93; 48],
            message_ciphertext: opaque_ack_body,
            sender_authentication: Vec::new(),
        };
        ack.sign_with(&recipient);
        ack.pack().into()
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct Stats {
    scheduled_events: u64,
    processed_events: u64,
    processed_transfer_events: u64,
    contact_events: u64,
    contact_losses: u64,
    unavailable_contacts: u64,
    partition_blocked_contacts: u64,
    transfer_attempts: u64,
    scheduled_transfers: u64,
    packet_losses: u64,
    accepted_replicas: u64,
    duplicate_receipts: u64,
    admission_rejections: u64,
    local_admission_rejections: u64,
    expired_on_arrival: u64,
    in_flight_unavailable: u64,
    retry_backoffs: u64,
    late_path_selections: u64,
    immutable_message_checks: u64,
    immutable_ack_checks: u64,
    endpoint_auth_rejections: u64,
    mutation_rejections: u64,
    endpoint_commits: u64,
    ui_deliveries: u64,
    ack_materializations: u64,
    ack_transitions: u64,
    idempotent_ack_receipts: u64,
    incorrect_ack_transitions: u64,
    rejected_ack_candidates: u64,
    commits_while_source_offline: u64,
    acks_while_recipient_offline: u64,
    availability_changes: u64,
    adversarial_drops: u64,
    adversarial_replays: u64,
    adversarial_delays: u64,
    adversarial_duplicates: u64,
    adversarial_mutations: u64,
    reordered_arrivals: u64,
    restarts: u64,
    reconstructed_replicas: u64,
    queue_expirations: u64,
    seen_expirations: u64,
    internet_transfers: u64,
    local_radio_transfers: u64,
    peak_event_queue: usize,
    peak_node_queue: usize,
    peak_node_seen: usize,
    peak_total_queued: usize,
    peak_logical_buffered_bytes: usize,
    peak_in_flight_bytes: usize,
    peak_offline_nodes: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Report {
    seed: u64,
    stats: Stats,
    final_queued: usize,
    final_seen: usize,
    commit_tick: Option<u64>,
    ack_tick: Option<u64>,
    sender_delivered: bool,
}

#[derive(Debug)]
struct Simulation {
    seed: u64,
    now: u64,
    next_sequence: u64,
    last_transfer_sequence: u64,
    nodes: Vec<Node>,
    topology: Topology,
    events: BinaryHeap<ScheduledEvent>,
    in_flight_bytes: usize,
    rng: DeterministicRng,
    fixture: Fixture,
    source: usize,
    recipient: usize,
    partitioned: bool,
    expected_ack: Option<Arc<[u8]>>,
    expected_ack_digest: Option<ObjectDigest>,
    commit_tick: Option<u64>,
    ack_tick: Option<u64>,
    sender_delivered: bool,
    stats: Stats,
}

impl Simulation {
    fn new(seed: u64, source: usize, recipient: usize) -> Self {
        Self::with_expiry(seed, source, recipient, DEFAULT_EXPIRY_TICK)
    }

    fn with_expiry(seed: u64, source: usize, recipient: usize, expires_at: u64) -> Self {
        assert!(source < NODE_COUNT && recipient < NODE_COUNT && source != recipient);
        let fixture = Fixture::signed(seed, expires_at);
        let nodes = (0..NODE_COUNT).map(Node::new).collect();
        let mut sim = Self {
            seed,
            now: 0,
            next_sequence: 0,
            last_transfer_sequence: 0,
            nodes,
            topology: Topology::seeded(seed),
            events: BinaryHeap::new(),
            in_flight_bytes: 0,
            rng: DeterministicRng::new(seed ^ 0x6576_656e_7473),
            fixture,
            source,
            recipient,
            partitioned: false,
            expected_ack: None,
            expected_ack_digest: None,
            commit_tick: None,
            ack_tick: None,
            sender_delivered: false,
            stats: Stats::default(),
        };
        let source_replica = Replica::new(
            Arc::clone(&sim.fixture.message_bytes),
            sim.fixture.expires_at,
        );
        assert_eq!(
            sim.admit_without_endpoint(source, source_replica),
            AdmissionOutcome::Accepted
        );
        sim.update_resource_peaks();
        sim
    }

    fn schedule(&mut self, at: u64, kind: EventKind) {
        assert!(
            self.events.len() < MAX_EVENT_QUEUE,
            "bounded event queue exceeded"
        );
        if let EventKind::Transfer { replica, .. } = &kind {
            self.in_flight_bytes = self
                .in_flight_bytes
                .checked_add(replica.bytes.len())
                .expect("bounded in-flight byte counter");
            assert!(self.in_flight_bytes <= MAX_EVENT_QUEUE * MAX_SIM_OBJECT_BYTES);
            self.stats.peak_in_flight_bytes =
                self.stats.peak_in_flight_bytes.max(self.in_flight_bytes);
        }
        let sequence = self.next_sequence;
        self.next_sequence = self
            .next_sequence
            .checked_add(1)
            .expect("event sequence bound");
        self.events.push(ScheduledEvent { at, sequence, kind });
        self.stats.scheduled_events += 1;
        self.stats.peak_event_queue = self.stats.peak_event_queue.max(self.events.len());
    }

    fn schedule_contact(&mut self, at: u64, a: usize, b: usize, profile: ContactProfile) {
        assert!(
            self.topology.has_edge(a, b),
            "contact is outside seeded topology"
        );
        assert!(profile.contact_loss_per_10k <= 10_000 && profile.packet_loss_per_10k <= 10_000);
        let transport = profile
            .transport_override
            .unwrap_or_else(|| self.topology.transport(a, b));
        self.schedule(
            at,
            EventKind::Contact(Contact {
                a,
                b,
                transport,
                latency: profile.latency,
                jitter: profile.jitter,
                contact_loss_per_10k: profile.contact_loss_per_10k,
                packet_loss_per_10k: profile.packet_loss_per_10k,
            }),
        );
    }

    fn set_online_now(&mut self, node: usize, online: bool) {
        if self.nodes[node].online != online {
            self.stats.availability_changes += 1;
        }
        self.nodes[node].online = online;
        self.update_resource_peaks();
    }

    fn inject_mutated_spam(&mut self, node: usize, count: usize) {
        for index in 0..count {
            let bytes = mutate_fixture(&self.fixture.message_bytes, index);
            let replica = Replica::new(bytes, self.fixture.expires_at);
            match self.admit_without_endpoint(node, replica) {
                AdmissionOutcome::Accepted => {}
                AdmissionOutcome::Duplicate | AdmissionOutcome::Full => {
                    self.stats.local_admission_rejections += 1;
                }
            }
        }
        self.update_resource_peaks();
    }

    fn inject_opaque_test_object(&mut self, node: usize, bytes: Arc<[u8]>) {
        let replica = Replica::new(bytes, self.fixture.expires_at);
        assert_eq!(
            self.admit_without_endpoint(node, replica),
            AdmissionOutcome::Accepted
        );
        self.update_resource_peaks();
    }

    fn run(&mut self) {
        while let Some(event) = self.events.pop() {
            self.stats.processed_events += 1;
            assert!(self.stats.processed_events <= MAX_EVENTS_PROCESSED);
            self.now = event.at;
            match event.kind {
                EventKind::SetOnline { node, online } => {
                    if self.nodes[node].online != online {
                        self.stats.availability_changes += 1;
                    }
                    self.nodes[node].online = online;
                }
                EventKind::SetPartitioned(partitioned) => self.partitioned = partitioned,
                EventKind::Contact(contact) => self.process_contact(contact),
                EventKind::Transfer {
                    from,
                    to,
                    transport,
                    replica,
                } => {
                    self.in_flight_bytes = self
                        .in_flight_bytes
                        .checked_sub(replica.bytes.len())
                        .expect("in-flight byte accounting");
                    self.stats.processed_transfer_events += 1;
                    if event.sequence < self.last_transfer_sequence {
                        self.stats.reordered_arrivals += 1;
                    }
                    self.last_transfer_sequence = self.last_transfer_sequence.max(event.sequence);
                    self.process_transfer(from, to, transport, replica);
                }
                EventKind::Restart(node) => self.restart_node(node),
                EventKind::SweepAll => self.sweep_all(),
            }
            self.update_resource_peaks();
        }
        self.assert_hard_bounds();
        assert_eq!(self.stats.scheduled_events, self.stats.processed_events);
        assert_eq!(self.in_flight_bytes, 0);
        assert_eq!(
            self.stats.scheduled_transfers,
            self.stats.processed_transfer_events
        );
        assert_eq!(
            self.stats.processed_transfer_events,
            self.stats.accepted_replicas
                + self.stats.duplicate_receipts
                + self.stats.admission_rejections
                + self.stats.expired_on_arrival
                + self.stats.in_flight_unavailable
        );
    }

    fn process_contact(&mut self, contact: Contact) {
        self.stats.contact_events += 1;
        if !self.nodes[contact.a].online || !self.nodes[contact.b].online {
            self.stats.unavailable_contacts += 1;
            return;
        }
        if self.partitioned
            && self.nodes[contact.a].partition_group != self.nodes[contact.b].partition_group
        {
            self.stats.partition_blocked_contacts += 1;
            return;
        }
        if self.rng.draw_per_10k(contact.contact_loss_per_10k) {
            self.stats.contact_losses += 1;
            return;
        }
        self.nodes[contact.a].purge_expired(self.now);
        self.nodes[contact.b].purge_expired(self.now);
        self.forward_direction(contact.a, contact.b, contact);
        self.forward_direction(contact.b, contact.a, contact);
    }

    fn forward_direction(&mut self, from: usize, to: usize, contact: Contact) {
        let behavior = self.nodes[from].behavior;
        let candidates: Vec<Replica> = self.nodes[from]
            .queue
            .iter()
            .filter(|replica| {
                replica.expires_at > self.now
                    && replica.hops_left > 0
                    && replica.copies_left > 0
                    && replica.next_attempt <= self.now
                    && (behavior == RelayBehavior::Replay || !replica.sent_to.contains(&to))
            })
            .take(MAX_OBJECTS_PER_CONTACT)
            .cloned()
            .collect();
        self.stats.late_path_selections += candidates.len() as u64;

        for candidate in candidates {
            if behavior == RelayBehavior::Drop {
                self.stats.adversarial_drops += 1;
                self.apply_backoff(from, to, candidate.digest, false);
                continue;
            }

            let repeat = match behavior {
                RelayBehavior::Replay => {
                    self.stats.adversarial_replays += 1;
                    3
                }
                RelayBehavior::Duplicate => {
                    self.stats.adversarial_duplicates += 1;
                    ADVERSARIAL_DUPLICATION_FACTOR
                }
                _ => 1,
            };
            let mut any_scheduled = false;
            for copy_index in 0..repeat {
                self.stats.transfer_attempts += 1;
                if self.rng.draw_per_10k(contact.packet_loss_per_10k) {
                    self.stats.packet_losses += 1;
                    continue;
                }
                let mut forwarded = candidate.forwarded();
                if behavior == RelayBehavior::Mutate {
                    forwarded.bytes = mutate_fixture(&forwarded.bytes, copy_index);
                    forwarded.digest = ObjectDigest::of(&forwarded.bytes);
                    self.stats.adversarial_mutations += 1;
                }
                let jitter = if contact.jitter == 0 {
                    0
                } else {
                    self.rng.next_u64() % (contact.jitter + 1)
                };
                let adversarial_delay = if behavior == RelayBehavior::Delay {
                    self.stats.adversarial_delays += 1;
                    40
                } else {
                    0
                };
                let at = self
                    .now
                    .saturating_add(contact.latency)
                    .saturating_add(jitter)
                    .saturating_add(adversarial_delay);
                self.schedule(
                    at,
                    EventKind::Transfer {
                        from,
                        to,
                        transport: contact.transport,
                        replica: forwarded,
                    },
                );
                self.stats.scheduled_transfers += 1;
                any_scheduled = true;
            }
            self.apply_backoff(from, to, candidate.digest, any_scheduled);
        }
    }

    fn apply_backoff(
        &mut self,
        node: usize,
        peer: usize,
        digest: ObjectDigest,
        consume_copy: bool,
    ) {
        let behavior = self.nodes[node].behavior;
        let Some(replica) = self.nodes[node]
            .queue
            .iter_mut()
            .find(|replica| replica.digest == digest)
        else {
            return;
        };
        replica.attempts = replica.attempts.saturating_add(1);
        let shift = u32::from(replica.attempts.min(6));
        let delay = (1u64 << shift).min(MAX_BACKOFF_TICKS);
        replica.next_attempt = self.now.saturating_add(delay);
        if consume_copy {
            replica.copies_left = replica.copies_left.saturating_sub(1);
            if behavior != RelayBehavior::Replay {
                assert!(replica.sent_to.len() < usize::from(INITIAL_REPLICAS));
                replica.sent_to.insert(peer);
            }
        }
        self.stats.retry_backoffs += 1;
    }

    fn process_transfer(
        &mut self,
        from: usize,
        to: usize,
        transport: TransportClass,
        replica: Replica,
    ) {
        if !self.nodes[from].online
            || !self.nodes[to].online
            || (self.partitioned
                && self.nodes[from].partition_group != self.nodes[to].partition_group)
        {
            self.stats.in_flight_unavailable += 1;
            return;
        }
        if replica.expires_at <= self.now {
            self.stats.expired_on_arrival += 1;
            return;
        }
        if replica.digest == self.fixture.message_digest {
            assert_eq!(replica.bytes.as_ref(), self.fixture.message_bytes.as_ref());
            self.stats.immutable_message_checks += 1;
        }
        if self.expected_ack_digest == Some(replica.digest) {
            assert_eq!(
                replica.bytes.as_ref(),
                self.expected_ack.as_deref().expect("ACK digest has bytes")
            );
            self.stats.immutable_ack_checks += 1;
        }

        let ack_to_admit = self.endpoint_oracle(to, &replica);
        match self.admit_without_endpoint(to, replica) {
            AdmissionOutcome::Accepted => {
                self.stats.accepted_replicas += 1;
                match transport {
                    TransportClass::Internet => self.stats.internet_transfers += 1,
                    TransportClass::LocalRadio => self.stats.local_radio_transfers += 1,
                }
            }
            AdmissionOutcome::Duplicate => self.stats.duplicate_receipts += 1,
            AdmissionOutcome::Full => self.stats.admission_rejections += 1,
        }
        if let Some(ack) = ack_to_admit {
            let ack_replica = Replica::new(ack, self.fixture.expires_at);
            assert_eq!(
                self.admit_without_endpoint(to, ack_replica),
                AdmissionOutcome::Accepted,
                "endpoint ACK must fit the modeled bounded queue"
            );
        }
    }

    /// Model boundary: strict outer RVN1 verification plus exact-fixture checks
    /// stand in for ATSAM decrypt/authenticate and durable endpoint commit.
    fn endpoint_oracle(&mut self, node: usize, replica: &Replica) -> Option<Arc<[u8]>> {
        if node == self.recipient {
            let decoded = Envelope::unpack(&replica.bytes);
            let same_public_message_id = decoded
                .as_ref()
                .is_some_and(|env| env.message_id == self.fixture.message_id);
            let authenticated_message = replica.digest == self.fixture.message_digest
                && replica.bytes.as_ref() == self.fixture.message_bytes.as_ref()
                && decoded.as_ref().is_some_and(|env| {
                    env.env_type == EnvType::Message as u8
                        && env.routing_tag == self.fixture.routing_tag
                        && env.verify(&self.fixture.sender_public)
                });
            if authenticated_message {
                if self.commit_tick.is_none() {
                    self.commit_tick = Some(self.now);
                    self.stats.endpoint_commits += 1;
                    self.stats.ui_deliveries += 1;
                    if !self.nodes[self.source].online {
                        self.stats.commits_while_source_offline += 1;
                    }
                    let ack = self.fixture.materialize_ack(self.now);
                    self.expected_ack_digest = Some(ObjectDigest::of(&ack));
                    self.expected_ack = Some(Arc::clone(&ack));
                    self.stats.ack_materializations += 1;
                    return Some(ack);
                }
                return None;
            }
            if same_public_message_id
                && decoded
                    .as_ref()
                    .is_some_and(|env| env.env_type == EnvType::Message as u8)
            {
                self.stats.endpoint_auth_rejections += 1;
                self.stats.mutation_rejections += 1;
            }
        }

        if node == self.source {
            let decoded_ack =
                Envelope::unpack(&replica.bytes).filter(|env| env.env_type == EnvType::Ack as u8);
            if self.expected_ack_digest != Some(replica.digest) {
                if decoded_ack.is_some() {
                    self.stats.rejected_ack_candidates += 1;
                }
                return None;
            }
            let expected = self.expected_ack.as_deref().expect("ACK bytes exist");
            let valid_ack = replica.bytes.as_ref() == expected
                && decoded_ack.is_some_and(|env| {
                    env.env_type == EnvType::Ack as u8
                        && env.message_id == self.fixture.message_id
                        && env.verify(&self.fixture.recipient_public)
                });
            if valid_ack && !self.sender_delivered {
                assert!(
                    self.commit_tick.is_some(),
                    "ACK cannot precede endpoint commit"
                );
                self.sender_delivered = true;
                self.ack_tick = Some(self.now);
                self.stats.ack_transitions += 1;
                if !self.nodes[self.recipient].online {
                    self.stats.acks_while_recipient_offline += 1;
                }
            } else if valid_ack {
                self.stats.idempotent_ack_receipts += 1;
            } else {
                self.stats.incorrect_ack_transitions += 1;
            }
        }
        None
    }

    fn admit_without_endpoint(&mut self, node: usize, replica: Replica) -> AdmissionOutcome {
        let target = &mut self.nodes[node];
        target.purge_expired(self.now);
        if target.seen.contains_key(&replica.digest) {
            return AdmissionOutcome::Duplicate;
        }
        if target.queue.len() >= NODE_QUEUE_CAP || target.seen.len() >= NODE_SEEN_CAP {
            return AdmissionOutcome::Full;
        }
        assert_eq!(replica.digest, ObjectDigest::of(&replica.bytes));
        target.seen.insert(replica.digest, replica.expires_at);
        target.queue.push_back(replica);
        AdmissionOutcome::Accepted
    }

    fn restart_node(&mut self, node: usize) {
        let before = &self.nodes[node];
        let persisted: Vec<PersistedReplica> = before
            .queue
            .iter()
            .map(|item| PersistedReplica {
                bytes: item.bytes.to_vec(),
                expires_at: item.expires_at,
                hops_left: item.hops_left,
                copies_left: item.copies_left,
                attempts: item.attempts,
                next_attempt: item.next_attempt,
                sent_to: item.sent_to.clone(),
            })
            .collect();
        let persisted_seen = before.seen.clone();
        let online = before.online;
        let partition_group = before.partition_group;
        let behavior = before.behavior;
        let mut reconstructed = Node {
            online,
            partition_group,
            behavior,
            queue: VecDeque::new(),
            seen: persisted_seen,
        };
        for item in persisted {
            let bytes: Arc<[u8]> = item.bytes.into();
            let digest = ObjectDigest::of(&bytes);
            assert!(reconstructed.seen.contains_key(&digest));
            if digest == self.fixture.message_digest {
                assert_eq!(bytes.as_ref(), self.fixture.message_bytes.as_ref());
            }
            if self.expected_ack_digest == Some(digest) {
                assert_eq!(bytes.as_ref(), self.expected_ack.as_deref().unwrap());
            }
            reconstructed.queue.push_back(Replica {
                bytes,
                digest,
                expires_at: item.expires_at,
                hops_left: item.hops_left,
                copies_left: item.copies_left,
                attempts: item.attempts,
                next_attempt: item.next_attempt,
                sent_to: item.sent_to,
            });
            self.stats.reconstructed_replicas += 1;
        }
        self.nodes[node] = reconstructed;
        self.stats.restarts += 1;
    }

    fn sweep_all(&mut self) {
        for node in &mut self.nodes {
            let queue_before = node.queue.len();
            let seen_before = node.seen.len();
            node.purge_expired(self.now);
            self.stats.queue_expirations += (queue_before - node.queue.len()) as u64;
            self.stats.seen_expirations += (seen_before - node.seen.len()) as u64;
        }
    }

    fn update_resource_peaks(&mut self) {
        let mut total_queued = 0usize;
        let mut logical_bytes = 0usize;
        let mut offline = 0usize;
        for node in &self.nodes {
            self.stats.peak_node_queue = self.stats.peak_node_queue.max(node.queue.len());
            self.stats.peak_node_seen = self.stats.peak_node_seen.max(node.seen.len());
            total_queued += node.queue.len();
            logical_bytes += node
                .queue
                .iter()
                .map(|item| item.bytes.len())
                .sum::<usize>();
            offline += usize::from(!node.online);
        }
        self.stats.peak_total_queued = self.stats.peak_total_queued.max(total_queued);
        self.stats.peak_logical_buffered_bytes =
            self.stats.peak_logical_buffered_bytes.max(logical_bytes);
        self.stats.peak_offline_nodes = self.stats.peak_offline_nodes.max(offline);
        self.assert_hard_bounds();
    }

    fn assert_hard_bounds(&self) {
        assert_eq!(self.nodes.len(), NODE_COUNT);
        assert!(self.events.len() <= MAX_EVENT_QUEUE);
        assert!(self.stats.peak_event_queue <= MAX_EVENT_QUEUE);
        assert!(self.stats.peak_node_queue <= NODE_QUEUE_CAP);
        assert!(self.stats.peak_node_seen <= NODE_SEEN_CAP);
        assert!(self.stats.peak_total_queued <= NODE_COUNT * NODE_QUEUE_CAP);
        assert!(
            self.stats.peak_logical_buffered_bytes
                <= NODE_COUNT * NODE_QUEUE_CAP * MAX_SIM_OBJECT_BYTES
        );
        assert!(self.stats.peak_in_flight_bytes <= MAX_EVENT_QUEUE * MAX_SIM_OBJECT_BYTES);
        for node in &self.nodes {
            assert!(node.queue.len() <= NODE_QUEUE_CAP);
            assert!(node.seen.len() <= NODE_SEEN_CAP);
            for replica in &node.queue {
                assert_eq!(replica.digest, ObjectDigest::of(&replica.bytes));
                assert!(replica.bytes.len() <= MAX_WIRE_ENVELOPE_BYTES);
                assert!(replica.bytes.len() <= MAX_SIM_OBJECT_BYTES);
                assert!(replica.sent_to.len() <= usize::from(INITIAL_REPLICAS));
            }
        }
        if let (Some(commit), Some(ack)) = (self.commit_tick, self.ack_tick) {
            assert!(ack >= commit, "delivery ACK preceded endpoint commit");
        }
    }

    fn report(&self) -> Report {
        Report {
            seed: self.seed,
            stats: self.stats.clone(),
            final_queued: self.nodes.iter().map(|node| node.queue.len()).sum(),
            final_seen: self.nodes.iter().map(|node| node.seen.len()).sum(),
            commit_tick: self.commit_tick,
            ack_tick: self.ack_tick,
            sender_delivered: self.sender_delivered,
        }
    }
}

fn ordered_pair(a: usize, b: usize) -> (usize, usize) {
    if a < b {
        (a, b)
    } else {
        (b, a)
    }
}

fn seeded_word(seed: u64, a: u64, b: u64, domain: u64) -> u64 {
    let mut rng = DeterministicRng::new(
        seed ^ a.wrapping_mul(0x9e37_79b9) ^ b.rotate_left(17) ^ domain.rotate_left(31),
    );
    rng.next_u64()
}

fn deterministic_seed(seed: u64, domain: u64) -> [u8; 32] {
    let mut rng = DeterministicRng::new(seed ^ domain);
    let mut bytes = [0u8; 32];
    fill_deterministic(&mut rng, &mut bytes);
    bytes
}

fn deterministic_nonce(rng: &mut DeterministicRng) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    fill_deterministic(rng, &mut nonce);
    nonce
}

fn fill_deterministic(rng: &mut DeterministicRng, bytes: &mut [u8]) {
    for chunk in bytes.chunks_mut(8) {
        let word = rng.next_u64().to_le_bytes();
        chunk.copy_from_slice(&word[..chunk.len()]);
    }
}

fn mutate_fixture(bytes: &[u8], index: usize) -> Arc<[u8]> {
    let decoded = Envelope::unpack(bytes).expect("mutation starts from strict RVN1 fixture");
    let body_start = PREFIX_LEN + decoded.ratchet_header_ciphertext.len();
    assert!(!decoded.message_ciphertext.is_empty());
    let mut mutated = bytes.to_vec();
    let offset = body_start + index % decoded.message_ciphertext.len();
    mutated[offset] ^= 1u8.wrapping_add((index % 251) as u8);
    assert_eq!(
        &mutated[8..24],
        &bytes[8..24],
        "public message id is unchanged"
    );
    assert_ne!(ObjectDigest::of(&mutated), ObjectDigest::of(bytes));
    mutated.into()
}

fn schedule_path(
    sim: &mut Simulation,
    path: &[usize],
    start: u64,
    spacing: u64,
    latency: u64,
) -> u64 {
    assert!(path.len() >= 2);
    let mut at = start;
    for pair in path.windows(2) {
        sim.schedule_contact(at, pair[0], pair[1], ContactProfile::reliable(latency));
        at += spacing;
    }
    at
}

fn schedule_reverse_path(
    sim: &mut Simulation,
    path: &[usize],
    start: u64,
    spacing: u64,
    latency: u64,
) -> u64 {
    let mut at = start;
    for pair in path.windows(2).rev() {
        sim.schedule_contact(at, pair[0], pair[1], ContactProfile::reliable(latency));
        at += spacing;
    }
    at
}

fn finish_success(name: &str, sim: &mut Simulation) -> Report {
    sim.run();
    let report = sim.report();
    print_report(name, &report);
    assert_eq!(
        report.stats.ui_deliveries, 1,
        "{name}: duplicate or missing UI delivery"
    );
    assert_eq!(
        report.stats.endpoint_commits, 1,
        "{name}: endpoint commit count"
    );
    assert_eq!(
        report.stats.ack_materializations, 1,
        "{name}: ACK materialization count"
    );
    assert_eq!(
        report.stats.ack_transitions, 1,
        "{name}: ACK transition count"
    );
    assert_eq!(
        report.stats.incorrect_ack_transitions, 0,
        "{name}: incorrect ACK transition"
    );
    assert!(
        report.sender_delivered,
        "{name}: silent loss despite a valid temporal path"
    );
    assert!(report.stats.immutable_message_checks > 0);
    assert!(report.stats.immutable_ack_checks > 0);
    assert!(report.stats.late_path_selections > 0);
    let commit = report.commit_tick.expect("message committed");
    assert!(report.ack_tick.expect("ACK accepted") >= commit);
    report
}

fn print_report(name: &str, report: &Report) {
    eprintln!(
        "network_sim_1000 scenario={name} seed={} events={}/{} contacts={} attempts={} transfers={} accepted={} duplicates={} packet_loss={} contact_loss={} ui={} ack_materialized={} ack_transition={} mutations_rejected={} restarts={} peak_event={} peak_node_queue={} peak_node_seen={} peak_total_queue={} peak_queue_bytes={} peak_inflight_bytes={} peak_offline={}",
        report.seed,
        report.stats.processed_events,
        report.stats.scheduled_events,
        report.stats.contact_events,
        report.stats.transfer_attempts,
        report.stats.scheduled_transfers,
        report.stats.accepted_replicas,
        report.stats.duplicate_receipts,
        report.stats.packet_losses,
        report.stats.contact_losses,
        report.stats.ui_deliveries,
        report.stats.ack_materializations,
        report.stats.ack_transitions,
        report.stats.mutation_rejections,
        report.stats.restarts,
        report.stats.peak_event_queue,
        report.stats.peak_node_queue,
        report.stats.peak_node_seen,
        report.stats.peak_total_queued,
        report.stats.peak_logical_buffered_bytes,
        report.stats.peak_in_flight_bytes,
        report.stats.peak_offline_nodes,
    );
}

#[test]
fn connected_baseline_delivers_and_acks_across_1_000_nodes() {
    let mut sim = Simulation::new(0x1000_0001, 0, 10);
    let path: Vec<usize> = (0..=10).collect();
    let end = schedule_path(&mut sim, &path, 10, 5, 1);
    schedule_reverse_path(&mut sim, &path, end + 10, 5, 1);
    let report = finish_success("connected_baseline", &mut sim);
    assert_eq!(report.stats.contact_losses + report.stats.packet_losses, 0);
}

fn run_loss_scenario(seed: u64) -> Report {
    // +37 is a guaranteed seeded-topology edge. The source retransmission
    // behavior creates bounded same-object attempts so a long first latency
    // and a short later latency deterministically exercise reordering.
    let mut sim = Simulation::new(seed, 100, 137);
    sim.nodes[100].behavior = RelayBehavior::Replay;
    sim.schedule_contact(1, 100, 137, ContactProfile::reliable(20));
    sim.schedule_contact(2, 100, 137, ContactProfile::reliable(1));
    let mut at = 10;
    for _round in 0..64 {
        sim.schedule_contact(at, 100, 137, ContactProfile::lossy(2, 7, 3_500, 3_500));
        at += 3;
    }
    finish_success("loss_latency_reordering", &mut sim)
}

#[test]
fn random_loss_latency_reordering_and_backoff_are_reproducible() {
    let first = run_loss_scenario(0x1000_0002);
    let second = run_loss_scenario(0x1000_0002);
    assert_eq!(
        first, second,
        "same seed must reproduce the complete report"
    );
    assert!(first.stats.contact_losses > 0);
    assert!(first.stats.packet_losses > 0);
    assert!(first.stats.retry_backoffs > 0);
    assert!(first.stats.reordered_arrivals > 0);
}

#[test]
fn half_node_loss_preserves_a_seeded_temporal_path() {
    let mut sim = Simulation::new(0x1000_0003, 200, 220);
    let protected: BTreeSet<usize> = (200..=220).collect();
    let mut selection_rng = DeterministicRng::new(0x5000_0003);
    let mut offline = BTreeSet::new();
    while offline.len() < NODE_COUNT / 2 {
        let candidate = selection_rng.index(NODE_COUNT);
        if !protected.contains(&candidate) {
            offline.insert(candidate);
        }
    }
    let offline_nodes: Vec<usize> = offline.iter().copied().collect();
    let returning_nodes: Vec<usize> = offline_nodes.iter().copied().take(50).collect();
    let replacement_nodes: Vec<usize> = (0..NODE_COUNT)
        .filter(|node| !protected.contains(node) && !offline.contains(node))
        .take(50)
        .collect();
    assert_eq!(returning_nodes.len(), 50);
    assert_eq!(replacement_nodes.len(), 50);
    for node in offline_nodes {
        sim.schedule(
            0,
            EventKind::SetOnline {
                node,
                online: false,
            },
        );
    }
    for node in returning_nodes {
        sim.schedule(5, EventKind::SetOnline { node, online: true });
    }
    for node in replacement_nodes {
        sim.schedule(
            6,
            EventKind::SetOnline {
                node,
                online: false,
            },
        );
    }
    let path: Vec<usize> = (200..=220).collect();
    let end = schedule_path(&mut sim, &path, 20, 5, 1);
    schedule_reverse_path(&mut sim, &path, end + 10, 5, 1);
    let report = finish_success("half_node_loss", &mut sim);
    assert_eq!(report.stats.peak_offline_nodes, NODE_COUNT / 2);
    assert_eq!(report.stats.availability_changes, 600);
}

#[test]
fn partition_then_heal_has_no_premature_ack() {
    let mut sim = Simulation::new(0x1000_0004, 498, 502);
    let path: Vec<usize> = (498..=502).collect();
    sim.schedule(0, EventKind::SetPartitioned(true));
    schedule_path(&mut sim, &path, 10, 5, 1);
    sim.schedule(100, EventKind::SetPartitioned(false));
    let end = schedule_path(&mut sim, &path, 110, 5, 1);
    schedule_reverse_path(&mut sim, &path, end + 10, 5, 1);
    let report = finish_success("partition_then_heal", &mut sim);
    assert!(report.stats.partition_blocked_contacts > 0);
    assert!(report.commit_tick.expect("commit") > 100);
}

#[test]
fn sender_and_recipient_need_not_be_simultaneously_online() {
    let mut sim = Simulation::new(0x1000_0005, 300, 302);
    sim.set_online_now(302, false);
    sim.schedule_contact(10, 300, 301, ContactProfile::reliable(1));
    sim.schedule(
        20,
        EventKind::SetOnline {
            node: 300,
            online: false,
        },
    );
    sim.schedule(
        20,
        EventKind::SetOnline {
            node: 302,
            online: true,
        },
    );
    sim.schedule_contact(30, 301, 302, ContactProfile::reliable(1));
    sim.schedule_contact(40, 301, 302, ContactProfile::reliable(1));
    sim.schedule(
        50,
        EventKind::SetOnline {
            node: 302,
            online: false,
        },
    );
    sim.schedule(
        50,
        EventKind::SetOnline {
            node: 300,
            online: true,
        },
    );
    sim.schedule_contact(60, 300, 301, ContactProfile::reliable(1));
    let report = finish_success("non_simultaneous_online", &mut sim);
    assert!(report.stats.accepted_replicas >= 3);
    assert_eq!(report.stats.commits_while_source_offline, 1);
    assert_eq!(report.stats.acks_while_recipient_offline, 1);
}

#[test]
fn duplicate_multipath_storm_delivers_once() {
    let mut sim = Simulation::new(0x1000_0006, 0, 74);
    sim.nodes[37].behavior = RelayBehavior::Duplicate;
    let path_a = [0, 37, 74];
    let path_b = [0, 1, 38, 75, 74];
    schedule_path(&mut sim, &path_a, 10, 10, 2);
    schedule_path(&mut sim, &path_b, 20, 10, 1);
    for offset in 0..8 {
        sim.schedule_contact(80 + offset * 4, 37, 74, ContactProfile::jittered(1, 3));
        sim.schedule_contact(82 + offset * 4, 75, 74, ContactProfile::jittered(1, 3));
    }
    schedule_reverse_path(&mut sim, &path_a, 150, 10, 1);
    schedule_reverse_path(&mut sim, &path_b, 180, 10, 1);
    let report = finish_success("duplicate_multipath_storm", &mut sim);
    assert!(report.stats.adversarial_duplicates > 0);
    assert!(report.stats.duplicate_receipts > 0);
    assert_eq!(report.stats.ui_deliveries, 1);
}

#[test]
fn out_of_order_arrivals_remain_idempotent() {
    let mut sim = Simulation::new(0x1000_0007, 400, 401);
    sim.nodes[400].behavior = RelayBehavior::Replay;
    sim.schedule_contact(10, 400, 401, ContactProfile::reliable(50));
    sim.schedule_contact(20, 400, 401, ContactProfile::reliable(1));
    sim.schedule_contact(80, 400, 401, ContactProfile::reliable(1));
    let report = finish_success("out_of_order", &mut sim);
    assert!(report.stats.reordered_arrivals > 0);
    assert!(report.stats.duplicate_receipts > 0);
}

#[test]
fn restart_reconstructs_persisted_opaque_state() {
    let mut sim = Simulation::new(0x1000_0008, 500, 502);
    sim.schedule_contact(10, 500, 501, ContactProfile::reliable(1));
    sim.schedule(20, EventKind::Restart(501));
    sim.schedule_contact(30, 501, 502, ContactProfile::reliable(1));
    sim.schedule_contact(40, 501, 502, ContactProfile::reliable(1));
    sim.schedule(50, EventKind::Restart(501));
    sim.schedule_contact(60, 500, 501, ContactProfile::reliable(1));
    let report = finish_success("restart_reconstruction", &mut sim);
    assert_eq!(report.stats.restarts, 2);
    assert!(report.stats.reconstructed_replicas >= 2);
}

#[test]
fn malicious_relays_cannot_mutate_or_false_ack() {
    let mut sim = Simulation::new(0x1000_0009, 20, 94);
    let premature_ack = sim.fixture.materialize_ack(2);
    sim.inject_opaque_test_object(19, premature_ack);
    sim.schedule_contact(5, 19, 20, ContactProfile::reliable(1));
    let malicious = BTreeSet::from([19, 21, 57, 231, 983]);
    sim.nodes[57].behavior = RelayBehavior::Mutate;
    sim.nodes[231].behavior = RelayBehavior::Drop;
    sim.nodes[19].behavior = RelayBehavior::Replay;
    sim.nodes[21].behavior = RelayBehavior::Delay;
    sim.nodes[983].behavior = RelayBehavior::Duplicate;

    let branches = [
        (10, 20, 57, 94),
        (20, 20, 231, 442),
        (30, 20, 19, 18),
        (40, 20, 21, 22),
        (60, 20, 983, 982),
    ];
    for (at, source, relay, next) in branches {
        sim.schedule_contact(at, source, relay, ContactProfile::reliable(1));
        sim.schedule_contact(at + 8, relay, next, ContactProfile::reliable(1));
    }

    let honest_path = sim.topology.shortest_path(20, 94, &malicious);
    let end = schedule_path(&mut sim, &honest_path, 110, 10, 1);
    schedule_reverse_path(&mut sim, &honest_path, end + 20, 10, 1);
    let report = finish_success("malicious_relays", &mut sim);
    assert!(report.stats.adversarial_drops > 0);
    assert!(report.stats.adversarial_replays > 0);
    assert!(report.stats.adversarial_delays > 0);
    assert!(report.stats.adversarial_duplicates > 0);
    assert!(report.stats.adversarial_mutations > 0);
    assert!(report.stats.mutation_rejections > 0);
    assert!(report.stats.rejected_ack_candidates > 0);
    assert_eq!(report.stats.incorrect_ack_transitions, 0);
}

#[test]
fn ttl_expiry_cleans_all_replica_and_dedup_state() {
    const EXPIRY: u64 = 80;
    let mut sim = Simulation::with_expiry(0x1000_0010, 600, 610, EXPIRY);
    sim.set_online_now(610, false);
    let path: Vec<usize> = (600..=609).collect();
    schedule_path(&mut sim, &path, 10, 5, 1);
    sim.schedule(EXPIRY + 1, EventKind::SweepAll);
    sim.run();
    let report = sim.report();
    print_report("ttl_expiry", &report);
    assert_eq!(report.stats.ui_deliveries, 0);
    assert_eq!(report.stats.ack_transitions, 0);
    assert!(!report.sender_delivered);
    assert_eq!(report.final_queued, 0);
    assert_eq!(report.final_seen, 0);
    assert!(report.stats.queue_expirations > 0);
    assert!(report.stats.seen_expirations > 0);
}

#[test]
fn bounded_queue_pressure_rejects_spam_without_evicting_existing_object() {
    let mut sim = Simulation::new(0x1000_0011, 700, 702);
    sim.inject_mutated_spam(700, 64);
    assert_eq!(sim.nodes[700].queue.len(), NODE_QUEUE_CAP);
    assert_eq!(
        sim.nodes[700].queue.front().unwrap().digest,
        sim.fixture.message_digest
    );
    sim.schedule_contact(100, 700, 701, ContactProfile::reliable(1));
    sim.schedule_contact(110, 701, 702, ContactProfile::reliable(1));
    sim.schedule_contact(200, 701, 702, ContactProfile::reliable(1));
    sim.schedule_contact(210, 700, 701, ContactProfile::reliable(1));
    sim.schedule_contact(230, 700, 701, ContactProfile::reliable(1));
    let report = finish_success("bounded_queue_pressure", &mut sim);
    assert_eq!(report.stats.peak_node_queue, NODE_QUEUE_CAP);
    assert!(report.stats.local_admission_rejections >= (64 - (NODE_QUEUE_CAP - 1)) as u64);
    assert!(report.stats.mutation_rejections > 0);
}

#[test]
fn bridge_crosses_two_transport_classes_with_exact_bytes() {
    let mut sim = Simulation::new(0x1000_0012, 800, 803);
    sim.schedule_contact(
        10,
        800,
        801,
        ContactProfile::bridged(TransportClass::Internet, 1),
    );
    sim.schedule_contact(
        20,
        801,
        802,
        ContactProfile::bridged(TransportClass::LocalRadio, 1),
    );
    sim.schedule_contact(
        30,
        802,
        803,
        ContactProfile::bridged(TransportClass::Internet, 1),
    );
    sim.schedule_contact(
        50,
        802,
        803,
        ContactProfile::bridged(TransportClass::Internet, 1),
    );
    sim.schedule_contact(
        60,
        801,
        802,
        ContactProfile::bridged(TransportClass::LocalRadio, 1),
    );
    sim.schedule_contact(
        70,
        800,
        801,
        ContactProfile::bridged(TransportClass::Internet, 1),
    );
    let report = finish_success("two_transport_bridge", &mut sim);
    assert!(report.stats.internet_transfers > 0);
    assert!(report.stats.local_radio_transfers > 0);
}

#[test]
fn several_fixed_seeds_retain_the_same_invariants() {
    let reports = [
        run_loss_scenario(0x5eed_0001),
        run_loss_scenario(0x5eed_0002),
        run_loss_scenario(0x5eed_0003),
    ];
    for report in reports {
        assert_eq!(report.stats.ui_deliveries, 1);
        assert_eq!(report.stats.ack_transitions, 1);
        assert_eq!(report.stats.incorrect_ack_transitions, 0);
        assert!(report.stats.peak_event_queue <= MAX_EVENT_QUEUE);
        assert!(report.stats.peak_node_queue <= NODE_QUEUE_CAP);
    }
}
