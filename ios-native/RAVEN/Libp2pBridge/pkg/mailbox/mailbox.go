// Package mailbox implements RAVEN's serverless store-and-forward node over
// libp2p (/raven/mailbox/1.0.0).
//
// A mailbox is an untrusted, dumb courier: it stores OPAQUE base64 payloads
// (already E2E-encrypted by the sender) keyed by the RECIPIENT's libp2p
// PeerID, and hands them to whoever connects holding that PeerID's private
// key. It cannot read message content. It does see metadata (depositor,
// bucket, timing) — the same trust level as a Circuit Relay v2 hop.
//
// Wire format (one stream per operation):
//
//	Deposit: 'P' | u16 len recipientPeerID | u16 len idemKey | u32 len payloadB64
//	         -> reply 'K' u32 bucketSize   (or 'E' u16 len msg)
//	Fetch:   'F'  (bucket chosen by the connection's authenticated PeerID)
//	         -> reply 'K' u32 count, then count x {u16 len idemKey | u32 len payloadB64}
//
// Limits: 512 msgs & 64 MiB per bucket, 24 MiB per msg, 72 h retention.
package mailbox

import (
	"bufio"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"sync"
	"time"

	libp2p "github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
	multiaddr "github.com/multiformats/go-multiaddr"
)

const (
	ProtocolID     = protocol.ID("/raven/mailbox/1.0.0")
	maxMsgBytes    = 24 * 1024 * 1024
	maxBucketMsgs  = 512
	maxBucketBytes = 64 * 1024 * 1024
	retention      = 72 * time.Hour
	opTimeout      = 60 * time.Second
)

type entry struct {
	idemKey  string
	payload  string
	storedAt time.Time
}

// Server is a mailbox node.
type Server struct {
	mu      sync.Mutex
	buckets map[string][]entry // recipient PeerID -> entries
	bytes   map[string]int64
	host    host.Host
}

// NewServer builds (not started) a mailbox server bound to an ed25519 seed.
func NewServer(seed []byte) (*Server, error) {
	if len(seed) != 32 && len(seed) != 64 {
		return nil, fmt.Errorf("seed must be 32 or 64 bytes")
	}
	var priv crypto.PrivKey
	switch len(seed) {
	case 32:
		std := ed25519Seed(seed)
		p, _, err := crypto.KeyPairFromStdKey(&std)
		if err != nil {
			return nil, err
		}
		priv = p
	default:
		std := ed25519Std(seed)
		p, _, err := crypto.KeyPairFromStdKey(&std)
		if err != nil {
			return nil, err
		}
		priv = p
	}
	h, err := libp2p.New(
		libp2p.Identity(priv),
		libp2p.ListenAddrStrings("/ip4/0.0.0.0/tcp/4002", "/ip4/0.0.0.0/udp/4002/quic-v1"),
		libp2p.DefaultTransports,
		libp2p.DefaultSecurity,
		libp2p.ForceReachabilityPublic(),
	)
	if err != nil {
		return nil, err
	}
	s := &Server{buckets: map[string][]entry{}, bytes: map[string]int64{}, host: h}
	h.SetStreamHandler(ProtocolID, s.handle)
	return s, nil
}

// Host returns the underlying libp2p host (for address printing).
func (s *Server) Host() host.Host { return s.host }

func (s *Server) handle(stream network.Stream) {
	defer stream.Close()
	_ = stream.SetReadDeadline(time.Now().Add(opTimeout))
	r := bufio.NewReader(stream)
	op, err := r.ReadByte()
	if err != nil {
		return
	}
	switch op {
	case 'P':
		s.handleDeposit(r, stream)
	case 'F':
		s.handleFetch(r, stream)
	default:
		writeErr(stream, "unknown op")
	}
}

func (s *Server) handleDeposit(r *bufio.Reader, stream network.Stream) {
	rcpt, ok := readStr16(r, 128)
	if !ok {
		writeErr(stream, "bad recipient")
		return
	}
	if _, err := peer.Decode(rcpt); err != nil {
		writeErr(stream, "recipient not a PeerID")
		return
	}
	idem, ok := readStr16(r, 512)
	if !ok {
		writeErr(stream, "bad idem key")
		return
	}
	payload, err := readStr32(r, maxMsgBytes)
	if err != nil {
		writeErr(stream, "payload too large")
		return
	}
	s.mu.Lock()
	b := s.buckets[rcpt]
	for _, e := range b { // dedup by idem key
		if e.idemKey == idem {
			s.mu.Unlock()
			replyOK(stream, uint32(len(b)))
			return
		}
	}
	if len(b) >= maxBucketMsgs || s.bytes[rcpt]+int64(len(payload)) > maxBucketBytes {
		// drop oldest to make room (best-effort courier semantics)
		if len(b) > 0 {
			s.bytes[rcpt] -= int64(len(b[0].payload))
			b = b[1:]
		}
	}
	b = append(b, entry{idemKey: idem, payload: payload, storedAt: time.Now()})
	s.buckets[rcpt] = b
	s.bytes[rcpt] += int64(len(payload))
	s.mu.Unlock()
	replyOK(stream, uint32(len(b)))
}

func (s *Server) handleFetch(_ *bufio.Reader, stream network.Stream) {
	// NOTE: peer.ID.String() (base58btc), not string(ID) which is raw multihash.
	me := stream.Conn().RemotePeer().String()
	s.mu.Lock()
	b := s.buckets[me]
	out := make([]entry, len(b))
	copy(out, b)
	delete(s.buckets, me)
	delete(s.bytes, me)
	s.mu.Unlock()

	w := bufio.NewWriter(stream)
	var hdr [5]byte
	hdr[0] = 'K'
	binary.BigEndian.PutUint32(hdr[1:], uint32(len(out)))
	w.Write(hdr[:])
	for _, e := range out {
		writeStr16(w, e.idemKey)
		writeStr32(w, e.payload)
	}
	w.Flush()
}

// GC drops entries older than retention.
func (s *Server) GC(ctx context.Context) {
	t := time.NewTicker(10 * time.Minute)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			cutoff := time.Now().Add(-retention)
			s.mu.Lock()
			for k, b := range s.buckets {
				kept := b[:0]
				for _, e := range b {
					if e.storedAt.After(cutoff) {
						kept = append(kept, e)
					} else {
						s.bytes[k] -= int64(len(e.payload))
					}
				}
				if len(kept) == 0 {
					delete(s.buckets, k)
					delete(s.bytes, k)
				} else {
					s.buckets[k] = kept
				}
			}
			s.mu.Unlock()
		}
	}
}

// ---- client ----

// Deposit stores one opaque payload for recipientPeerID on the mailbox at
// mailboxAddr (full multiaddr incl. /p2p/<id>).
func Deposit(ctx context.Context, mailboxAddr, recipientPeerID, idemKey, payloadB64 string) (uint32, error) {
	ma, err := multiaddr.NewMultiaddr(mailboxAddr)
	if err != nil {
		return 0, fmt.Errorf("bad mailbox addr: %w", err)
	}
	ai, err := peer.AddrInfoFromP2pAddr(ma)
	if err != nil {
		return 0, fmt.Errorf("bad mailbox addrinfo: %w", err)
	}
	// ephemeral single-use host keeps the depositor unlinkable to fetches
	h, err := libp2p.New(libp2p.NoListenAddrs, libp2p.DefaultTransports, libp2p.DefaultSecurity)
	if err != nil {
		return 0, err
	}
	defer h.Close()
	dctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := h.Connect(dctx, *ai); err != nil {
		return 0, fmt.Errorf("connect mailbox: %w", err)
	}
	s, err := h.NewStream(dctx, ai.ID, ProtocolID)
	if err != nil {
		return 0, err
	}
	defer s.Close()

	w := bufio.NewWriter(s)
	w.WriteByte('P')
	writeStr16(w, recipientPeerID)
	writeStr16(w, idemKey)
	writeStr32(w, payloadB64)
	if err := w.Flush(); err != nil {
		return 0, err
	}
	_ = s.SetReadDeadline(time.Now().Add(opTimeout))
	r := bufio.NewReader(s)
	resp, _ := r.ReadByte()
	if resp != 'K' {
		return 0, fmt.Errorf("deposit rejected: %s", mustReadErr(r))
	}
	var cnt [4]byte
	if _, err := io.ReadFull(r, cnt[:]); err != nil {
		return 0, err
	}
	return binary.BigEndian.Uint32(cnt[:]), nil
}

// Fetched is one retrieved opaque entry.
type Fetched struct {
	IDemKey    string
	PayloadB64 string
}

// Fetch retrieves and clears the caller's bucket on the mailbox at addr. The
// local seed identifies WHICH bucket (libp2p PeerID of the connection).
func Fetch(ctx context.Context, seed []byte, mailboxAddr string) ([]Fetched, error) {
	ma, err := multiaddr.NewMultiaddr(mailboxAddr)
	if err != nil {
		return nil, fmt.Errorf("bad mailbox addr: %w", err)
	}
	ai, err := peer.AddrInfoFromP2pAddr(ma)
	if err != nil {
		return nil, fmt.Errorf("bad mailbox addrinfo: %w", err)
	}
	var std ed25519Private
	switch len(seed) {
	case 32:
		std = ed25519Seed(seed)
	default:
		std = ed25519Std(seed)
	}
	priv, _, err := crypto.KeyPairFromStdKey(&std)
	if err != nil {
		return nil, err
	}
	h, err := libp2p.New(libp2p.Identity(priv), libp2p.NoListenAddrs, libp2p.DefaultTransports, libp2p.DefaultSecurity)
	if err != nil {
		return nil, err
	}
	defer h.Close()
	dctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if err := h.Connect(dctx, *ai); err != nil {
		return nil, fmt.Errorf("connect mailbox: %w", err)
	}
	s, err := h.NewStream(dctx, ai.ID, ProtocolID)
	if err != nil {
		return nil, err
	}
	defer s.Close()
	if _, err := s.Write([]byte{'F'}); err != nil {
		return nil, err
	}
	_ = s.SetReadDeadline(time.Now().Add(opTimeout))
	r := bufio.NewReader(s)
	resp, _ := r.ReadByte()
	if resp != 'K' {
		return nil, fmt.Errorf("fetch rejected: %s", mustReadErr(r))
	}
	var cnt [4]byte
	if _, err := io.ReadFull(r, cnt[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint32(cnt[:])
	out := make([]Fetched, 0, min(n, 4096))
	for i := uint32(0); i < n; i++ {
		idem, ok := readStr16(r, 512)
		if !ok {
			break
		}
		payload, err := readStr32(r, maxMsgBytes)
		if err != nil {
			break
		}
		out = append(out, Fetched{IDemKey: idem, PayloadB64: payload})
	}
	return out, nil
}

// ---- tiny frame helpers ----

func writeStr16(w io.Writer, s string) {
	var l [2]byte
	binary.BigEndian.PutUint16(l[:], uint16(len(s)))
	w.Write(l[:])
	io.WriteString(w, s)
}

func writeStr32(w io.Writer, s string) {
	var l [4]byte
	binary.BigEndian.PutUint32(l[:], uint32(len(s)))
	w.Write(l[:])
	io.WriteString(w, s)
}

func readStr16(r *bufio.Reader, max int) (string, bool) {
	var l [2]byte
	if _, err := io.ReadFull(r, l[:]); err != nil {
		return "", false
	}
	n := int(binary.BigEndian.Uint16(l[:]))
	if n > max {
		return "", false
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return "", false
	}
	return string(buf), true
}

func readStr32(r *bufio.Reader, max int) (string, error) {
	var l [4]byte
	if _, err := io.ReadFull(r, l[:]); err != nil {
		return "", err
	}
	n := binary.BigEndian.Uint32(l[:])
	if n > uint32(max) {
		return "", fmt.Errorf("frame too large: %d", n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return "", err
	}
	return string(buf), nil
}

func replyOK(w io.Writer, count uint32) {
	var hdr [5]byte
	hdr[0] = 'K'
	binary.BigEndian.PutUint32(hdr[1:], count)
	w.Write(hdr[:])
}

func writeErr(w io.Writer, msg string) {
	var hdr [3]byte
	hdr[0] = 'E'
	binary.BigEndian.PutUint16(hdr[1:], uint16(len(msg)))
	w.Write(hdr[:])
	io.WriteString(w, msg)
}

func mustReadErr(r *bufio.Reader) string {
	msg, ok := readStr16(r, 256)
	if !ok {
		return "unknown"
	}
	return msg
}

func min(a, b uint32) uint32 {
	if a < b {
		return a
	}
	return b
}
