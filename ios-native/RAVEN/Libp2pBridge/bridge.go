// Package ravenbridge is the serverless internet-bridge transport for RAVEN,
// compiled to an iOS xcframework via `gomobile bind`.
//
// It runs a go-libp2p host whose identity is RAVEN's own Ed25519 device key
// (so its PeerID derives from the same public key as the device fingerprint).
// Peers discover each other over the Kademlia DHT and connect directly or via
// Circuit Relay v2 (+ DCUtR hole-punching) when NAT-blocked, then exchange the
// opaque, already-E2E-encrypted RAVEN envelope over the /raven/bridge/1.0.0
// stream. No central server.
//
// gomobile note: only a restricted type set crosses the bind boundary
// (bool/int/int64/float64/string/[]byte, plus structs/interfaces from this
// package). The exported API below sticks to strings/[]byte + a Delegate
// interface implemented on the Swift side. context.Context, channels and
// libp2p types stay internal.
package ravenbridge

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	dht "github.com/libp2p/go-libp2p-kad-dht"
	libp2p "github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
	multiaddr "github.com/multiformats/go-multiaddr"
)

const bridgeProtocol = protocol.ID("/raven/bridge/1.0.0")

// maxEnvelopeBytes caps a single inbound frame (defends against a hostile peer
// streaming an unbounded "length"). Mirrors the server's 64 KiB bridge cap.
const maxEnvelopeBytes = 64 * 1024

// Delegate is implemented on the Swift side. Calls arrive on background
// goroutines — the Swift implementation must hop to its own actor/queue.
type Delegate interface {
	// OnEnvelope delivers an inbound opaque envelope (base64) plus the
	// sender's idempotency key, for MeshBridgeReceiver.ingest(...).
	OnEnvelope(envelopeB64 string, idempotencyKey string)
	// OnStatus reports connectivity changes (host started/stopped, our PeerID).
	OnStatus(connected bool, peerID string)
}

// Node wraps a libp2p host. Exposed to Swift as a class by gomobile.
type Node struct {
	mu       sync.Mutex
	host     host.Host
	dht      *dht.IpfsDHT
	delegate Delegate
	priv     crypto.PrivKey
	ctx      context.Context
	cancel   context.CancelFunc
	started  bool
}

// NewNode builds (but does not start) a node from RAVEN's Ed25519 private key.
// `ed25519Key` is either the 32-byte seed (CryptoKit
// Curve25519.Signing.PrivateKey.rawRepresentation) or the 64-byte std key.
func NewNode(ed25519Key []byte, delegate Delegate) (*Node, error) {
	if delegate == nil {
		return nil, errors.New("delegate is required")
	}
	var std ed25519.PrivateKey
	switch len(ed25519Key) {
	case ed25519.SeedSize: // 32
		std = ed25519.NewKeyFromSeed(ed25519Key)
	case ed25519.PrivateKeySize: // 64
		std = ed25519.PrivateKey(ed25519Key)
	default:
		return nil, fmt.Errorf("ed25519Key must be %d or %d bytes, got %d",
			ed25519.SeedSize, ed25519.PrivateKeySize, len(ed25519Key))
	}
	priv, _, err := crypto.KeyPairFromStdKey(&std)
	if err != nil {
		return nil, fmt.Errorf("wrap ed25519 key: %w", err)
	}
	return &Node{priv: priv, delegate: delegate}, nil
}

// Start boots the libp2p host: identity, Noise transport, Circuit Relay v2
// client, hole-punching, and the Kademlia DHT (client mode) bootstrapped from
// the comma-separated multiaddrs in `bootstrapCSV`.
func (n *Node) Start(bootstrapCSV string) error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.started {
		return nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	n.ctx, n.cancel = ctx, cancel

	h, err := libp2p.New(
		libp2p.Identity(n.priv),
		libp2p.DefaultTransports,
		libp2p.DefaultSecurity, // Noise + TLS
		libp2p.NATPortMap(),
		libp2p.EnableRelay(),         // use relays as a client
		libp2p.EnableHolePunching(),  // DCUtR: upgrade relayed -> direct
		libp2p.EnableNATService(),
	)
	if err != nil {
		cancel()
		return fmt.Errorf("libp2p.New: %w", err)
	}
	n.host = h

	// DHT in client mode (mobile shouldn't serve as a full DHT server).
	kdht, err := dht.New(ctx, h, dht.Mode(dht.ModeClient))
	if err != nil {
		_ = h.Close()
		cancel()
		return fmt.Errorf("dht.New: %w", err)
	}
	n.dht = kdht

	// Inbound envelope stream handler.
	h.SetStreamHandler(bridgeProtocol, n.handleStream)

	// Connect to bootstrap peers, then bootstrap the DHT.
	n.connectBootstrap(ctx, bootstrapCSV)
	if err := kdht.Bootstrap(ctx); err != nil {
		// non-fatal: discovery degrades but direct/relayed dials may still work
		fmt.Printf("[ravenbridge] dht bootstrap warning: %v\n", err)
	}

	n.started = true
	if n.delegate != nil {
		n.delegate.OnStatus(true, h.ID().String())
	}
	return nil
}

func (n *Node) connectBootstrap(ctx context.Context, csv string) {
	for _, raw := range strings.Split(csv, ",") {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		ma, err := multiaddr.NewMultiaddr(raw)
		if err != nil {
			continue
		}
		ai, err := peer.AddrInfoFromP2pAddr(ma)
		if err != nil {
			continue
		}
		cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		_ = n.host.Connect(cctx, *ai)
		cancel()
	}
}

func (n *Node) handleStream(s network.Stream) {
	defer s.Close()
	r := bufio.NewReader(s)

	// Frame: [4-byte big-endian len][envelope bytes][2-byte idemKey len][idemKey].
	var lenBuf [4]byte
	if _, err := readFull(r, lenBuf[:]); err != nil {
		return
	}
	envLen := int(binary.BigEndian.Uint32(lenBuf[:]))
	if envLen <= 0 || envLen > maxEnvelopeBytes {
		return
	}
	env := make([]byte, envLen)
	if _, err := readFull(r, env); err != nil {
		return
	}
	var keyLenBuf [2]byte
	if _, err := readFull(r, keyLenBuf[:]); err != nil {
		return
	}
	keyLen := int(binary.BigEndian.Uint16(keyLenBuf[:]))
	idem := make([]byte, keyLen)
	if keyLen > 0 {
		if _, err := readFull(r, idem); err != nil {
			return
		}
	}
	// Hand the opaque envelope to Swift. `env` is already the base64 text the
	// sender wrote (1:1 with the server bridge's envelope_b64 contract).
	if n.delegate != nil {
		n.delegate.OnEnvelope(string(env), string(idem))
	}
}

func readFull(r *bufio.Reader, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		m, err := r.Read(buf[total:])
		total += m
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// Send dials/relays to `peerIDStr`, opening a /raven/bridge/1.0.0 stream and
// writing the opaque envelope. `envelopeB64` is the same base64 string the
// server bridge used; `idempotencyKey` dedups on the receiver.
func (n *Node) Send(peerIDStr, envelopeB64, idempotencyKey string) error {
	n.mu.Lock()
	h, kdht, ctx := n.host, n.dht, n.ctx
	n.mu.Unlock()
	if h == nil || kdht == nil {
		return errors.New("node not started")
	}

	pid, err := peer.Decode(peerIDStr)
	if err != nil {
		return fmt.Errorf("bad peer id: %w", err)
	}

	// Discover the peer over the DHT if we don't already have addrs.
	dctx, dcancel := context.WithTimeout(ctx, 30*time.Second)
	ai, err := kdht.FindPeer(dctx, pid)
	dcancel()
	if err == nil {
		h.Peerstore().AddAddrs(pid, ai.Addrs, 10*time.Minute)
	}

	cctx, ccancel := context.WithTimeout(ctx, 30*time.Second)
	defer ccancel()
	// Allow dialing through relays.
	cctx = network.WithAllowLimitedConn(cctx, "raven-bridge")
	s, err := h.NewStream(cctx, pid, bridgeProtocol)
	if err != nil {
		return fmt.Errorf("open stream: %w", err)
	}
	defer s.Close()

	env := []byte(envelopeB64)
	if len(env) > maxEnvelopeBytes {
		return errors.New("envelope too large")
	}
	idem := []byte(idempotencyKey)

	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(env)))
	if _, err := s.Write(hdr[:]); err != nil {
		return err
	}
	if _, err := s.Write(env); err != nil {
		return err
	}
	var khdr [2]byte
	binary.BigEndian.PutUint16(khdr[:], uint16(len(idem)))
	if _, err := s.Write(khdr[:]); err != nil {
		return err
	}
	if _, err := s.Write(idem); err != nil {
		return err
	}
	return nil
}

// PeerID returns our libp2p peer ID (derived from the RAVEN Ed25519 key).
func (n *Node) PeerID() string {
	n.mu.Lock()
	defer n.mu.Unlock()
	if n.host == nil {
		if id, err := peer.IDFromPrivateKey(n.priv); err == nil {
			return id.String()
		}
		return ""
	}
	return n.host.ID().String()
}

// Stop shuts the host down.
func (n *Node) Stop() error {
	n.mu.Lock()
	defer n.mu.Unlock()
	if !n.started {
		return nil
	}
	if n.cancel != nil {
		n.cancel()
	}
	var err error
	if n.host != nil {
		err = n.host.Close()
	}
	n.started = false
	if n.delegate != nil {
		n.delegate.OnStatus(false, "")
	}
	return err
}
