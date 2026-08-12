// Rendezvous: serverless remote contact add.
//
// Two people who are not physically together become contacts without a server
// and without putting anything sensitive through a third-party channel. The
// inviter generates a random token, publishes a DHT provider record addressed by
// a hash of that token, and serves their (Swift-signed) contact card sealed
// under a key derived from the same token. The token travels over any channel —
// voice, SMS, another messenger — and is worthless to anyone who captures it
// after it expires.
//
// Two deliberate design points:
//
//   - The rendezvous runs on an EPHEMERAL libp2p identity, never `Node.priv`.
//     The main host's PeerID is derived from RAVEN's permanent Ed25519 device
//     key, so providing records under it would let any DHT observer correlate a
//     user's invites and reach their IP. The ephemeral key is discarded when the
//     invite expires.
//
//   - Go never sees a long-term secret and makes no trust decision. It moves
//     opaque bytes. The card is built and signed in Swift (identity key lives in
//     the Keychain) and its signature is verified in Swift. This package only
//     provides confidentiality-in-transit against non-token-holders.
package ravenbridge

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base32"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/ipfs/go-cid"
	"github.com/libp2p/go-libp2p"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/libp2p/go-libp2p/core/protocol"
	relayclient "github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/client"
	multiaddr "github.com/multiformats/go-multiaddr"
	multihash "github.com/multiformats/go-multihash"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"
	"crypto/sha256"
)

const rendezvousProtocol = protocol.ID("/raven/rdv/1.0.0")

// tokenBytes is the raw entropy in an invite token. 16 bytes (128 bits) is far
// beyond dictionary attack, which is what lets this phase skip a PAKE: there is
// nothing to guess. A short human-speakable code would NOT be safe this way and
// must go through SPAKE2 instead (see the design doc, approach A).
const tokenBytes = 16

// maxCardBytes caps a sealed card. Cards are small JSON blobs (userId + three
// public keys + signature); this is a hostile-input ceiling, not a target.
const maxCardBytes = 64 * 1024

// rendezvousDialTimeout bounds the whole redeem attempt.
const rendezvousDialTimeout = 45 * time.Second

// rendezvousStreamTimeout bounds a single card exchange once connected.
const rendezvousStreamTimeout = 30 * time.Second

// tokenEncoding is unpadded, uppercase-free base32 — reasonable to paste into a
// URL and to read back if someone has to.
var tokenEncoding = base32.StdEncoding.WithPadding(base32.NoPadding)

// ─── Derivation ──────────────────────────────────────────────────────────────

// rendezvousCID maps a token to the DHT address the inviter provides under.
//
// Note this is a *hash* of the token, so observing the CID on the DHT does not
// reveal the token: a watcher cannot derive the payload key from what the DHT
// exposes.
func rendezvousCID(token []byte) (cid.Cid, error) {
	h := sha256.New()
	h.Write([]byte("raven-rdv-v1"))
	h.Write(token)
	digest := h.Sum(nil)

	mh, err := multihash.Encode(digest, multihash.SHA2_256)
	if err != nil {
		return cid.Undef, fmt.Errorf("multihash: %w", err)
	}
	return cid.NewCidV1(cid.Raw, mh), nil
}

// rendezvousKey derives the AEAD key that seals the cards.
//
// Domain-separated from rendezvousCID: the CID uses a plain SHA-256 with its own
// prefix while the key goes through HKDF with a distinct salt and info, so
// knowing the CID yields nothing about the key.
func rendezvousKey(token []byte) ([]byte, error) {
	r := hkdf.New(sha256.New, token,
		[]byte("raven-rdv-v1/key"),
		[]byte("card"))
	key := make([]byte, chacha20poly1305.KeySize)
	if _, err := io.ReadFull(r, key); err != nil {
		return nil, fmt.Errorf("hkdf: %w", err)
	}
	return key, nil
}

// Direction tags bound into the AAD so the two legs of the exchange are not
// interchangeable — a relay cannot echo the inviter's own sealed card back at
// the redeemer and have it open as if it were the peer's.
var (
	aadInviterCard  = []byte("raven-rdv-v1/inviter-card")
	aadRedeemerCard = []byte("raven-rdv-v1/redeemer-card")
)

// sealCard encrypts a card under the token-derived key. Output is
// [12-byte nonce || ciphertext+tag].
func sealCard(key, plaintext, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	return aead.Seal(nonce, nonce, plaintext, aad), nil
}

// openCard reverses sealCard. Returns an error on a wrong token, a tampered
// ciphertext, or a swapped direction tag.
func openCard(key, sealed, aad []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		return nil, err
	}
	if len(sealed) < aead.NonceSize() {
		return nil, errors.New("sealed card too short")
	}
	nonce := sealed[:aead.NonceSize()]
	ct := sealed[aead.NonceSize():]
	return aead.Open(nil, nonce, ct, aad)
}

// ─── Invite state ────────────────────────────────────────────────────────────

// invite is one live rendezvous: an ephemeral host advertising a CID and serving
// the inviter's sealed card.
type invite struct {
	token      []byte
	key        []byte
	sealedCard []byte
	host       host.Host
	// Own DHT, attached to `host` (the ephemeral identity) so provider records
	// never carry the permanent PeerID. See CreateInvite.
	dht         *dht.IpfsDHT
	cancel      context.CancelFunc
	expiresAt   time.Time
	mu          sync.Mutex
	peerCardRaw []byte // set when a redeemer completes the exchange
}

// ─── Public API (gomobile-visible) ───────────────────────────────────────────

// CreateInvite publishes a rendezvous for `cardJSON` and returns the token to
// hand to the other person.
//
// `cardJSON` must already be signed on the Swift side — this package neither
// signs nor validates it. `ttlSeconds` bounds how long the invite stays live;
// it is clamped to [60, 3600].
//
// The returned token is base32 and belongs in a `raven://i/<token>` link or
// spoken/typed directly.
func (n *Node) CreateInvite(cardJSON string, ttlSeconds int) (string, error) {
	if cardJSON == "" {
		return "", errors.New("cardJSON is required")
	}
	if len(cardJSON) > maxCardBytes {
		return "", errors.New("card too large")
	}
	n.mu.Lock()
	started, relays := n.started, n.relays
	n.mu.Unlock()
	if !started {
		return "", errors.New("node not started")
	}

	if ttlSeconds < 60 {
		ttlSeconds = 60
	}
	if ttlSeconds > 3600 {
		ttlSeconds = 3600
	}

	token := make([]byte, tokenBytes)
	if _, err := rand.Read(token); err != nil {
		return "", fmt.Errorf("token: %w", err)
	}
	key, err := rendezvousKey(token)
	if err != nil {
		return "", err
	}
	sealed, err := sealCard(key, []byte(cardJSON), aadInviterCard)
	if err != nil {
		return "", err
	}
	rcid, err := rendezvousCID(token)
	if err != nil {
		return "", err
	}

	// Ephemeral identity — see the package comment. Never n.priv.
	ephPriv, _, err := crypto.GenerateEd25519Key(rand.Reader)
	if err != nil {
		return "", fmt.Errorf("ephemeral key: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(ttlSeconds)*time.Second)

	h, err := libp2p.New(
		libp2p.Identity(ephPriv),
		libp2p.DefaultTransports,
		libp2p.DefaultSecurity,
		libp2p.EnableRelay(),
		libp2p.EnableHolePunching(),
	)
	if err != nil {
		cancel()
		return "", fmt.Errorf("ephemeral host: %w", err)
	}

	// The ephemeral host needs its OWN DHT.
	//
	// 🔴 2026-07-19 — this previously advertised through `n.dht`, which is
	// attached to the MAIN host. `Provide` announces *the providing host's*
	// PeerID, so the record pointed at the permanent device identity — the
	// exact deanonymization the ephemeral key exists to prevent, and it would
	// have leaked the inviter's identity and IP to anyone who computed the CID.
	// It also broke the feature outright: the redeemer would have found the
	// main host, which does not serve /raven/rdv/1.0.0. The in-process
	// integration test missed both because it dials the provider directly and
	// never touches the DHT.
	ephDHT, err := dht.New(ctx, h, dht.Mode(dht.ModeClient))
	if err != nil {
		_ = h.Close()
		cancel()
		return "", fmt.Errorf("ephemeral dht: %w", err)
	}

	inv := &invite{
		token:      token,
		key:        key,
		sealedCard: sealed,
		host:       h,
		dht:        ephDHT,
		cancel:     cancel,
		expiresAt:  time.Now().Add(time.Duration(ttlSeconds) * time.Second),
	}

	h.SetStreamHandler(rendezvousProtocol, func(s network.Stream) {
		n.handleRendezvous(inv, s)
	})

	// A mobile peer has no dialable address, so it is reachable only through a
	// relay it holds a reservation on. Same requirement Send() works around.
	// The ephemeral host must also connect to the bootstrap peers in its own
	// right, or its DHT has no routing table to publish into.
	for i := range relays {
		rctx, rcancel := context.WithTimeout(ctx, 20*time.Second)
		if cerr := h.Connect(rctx, relays[i]); cerr != nil {
			fmt.Printf("[ravenbridge] invite bootstrap connect failed for %s: %v\n", relays[i].ID, cerr)
		}
		if _, rerr := relayclient.Reserve(rctx, h, relays[i]); rerr != nil {
			fmt.Printf("[ravenbridge] invite relay reservation failed for %s: %v\n", relays[i].ID, rerr)
		}
		rcancel()
	}

	// Announce on the DHT from the EPHEMERAL host, so the provider record
	// carries the throwaway PeerID. Provider records are namespace-agnostic,
	// unlike PutValue, which public DHT servers reject for unknown namespaces.
	go func() {
		if berr := ephDHT.Bootstrap(ctx); berr != nil {
			fmt.Printf("[ravenbridge] invite dht bootstrap warning: %v\n", berr)
		}
		pctx, pcancel := context.WithTimeout(ctx, 60*time.Second)
		defer pcancel()
		if perr := ephDHT.Provide(pctx, rcid, true); perr != nil {
			fmt.Printf("[ravenbridge] invite provide failed: %v\n", perr)
		}
	}()

	tokenStr := tokenEncoding.EncodeToString(token)

	n.inviteMu.Lock()
	if n.invites == nil {
		n.invites = map[string]*invite{}
	}
	n.invites[tokenStr] = inv
	n.inviteMu.Unlock()

	// Reap on expiry so the ephemeral identity and its relay slots do not
	// outlive the invite.
	go func() {
		<-ctx.Done()
		n.CancelInvite(tokenStr)
	}()

	return tokenStr, nil
}

// handleRendezvous serves the inviter's sealed card and accepts the redeemer's.
func (n *Node) handleRendezvous(inv *invite, s network.Stream) {
	defer s.Close()
	_ = s.SetDeadline(time.Now().Add(rendezvousStreamTimeout))

	// Send ours first: the redeemer already proved nothing, but the card is
	// sealed under the token, so a peer without it learns only its length.
	if err := writeFrame(s, inv.sealedCard); err != nil {
		return
	}

	r := bufio.NewReader(s)
	peerSealed, err := readFrame(r, maxCardBytes)
	if err != nil {
		return
	}
	peerCard, err := openCard(inv.key, peerSealed, aadRedeemerCard)
	if err != nil {
		// Wrong token or tampering — drop silently, the invite stays live for
		// the legitimate redeemer.
		return
	}

	inv.mu.Lock()
	inv.peerCardRaw = peerCard
	inv.mu.Unlock()

	if n.delegate != nil {
		n.delegate.OnInviteRedeemed(tokenEncoding.EncodeToString(inv.token), string(peerCard))
	}
}

// RedeemInvite resolves `token`, exchanges cards, and returns the inviter's
// card JSON. The caller MUST verify the returned card's signature in Swift.
func (n *Node) RedeemInvite(token string, myCardJSON string) (string, error) {
	if myCardJSON == "" {
		return "", errors.New("myCardJSON is required")
	}
	if len(myCardJSON) > maxCardBytes {
		return "", errors.New("card too large")
	}
	raw, err := tokenEncoding.DecodeString(token)
	if err != nil || len(raw) != tokenBytes {
		return "", errors.New("malformed invite token")
	}

	n.mu.Lock()
	h, kdht, ctx, relays := n.host, n.dht, n.ctx, n.relays
	n.mu.Unlock()
	if h == nil || kdht == nil {
		return "", errors.New("node not started")
	}

	key, err := rendezvousKey(raw)
	if err != nil {
		return "", err
	}
	rcid, err := rendezvousCID(raw)
	if err != nil {
		return "", err
	}

	dctx, dcancel := context.WithTimeout(ctx, rendezvousDialTimeout)
	defer dcancel()

	// FindProviders yields the inviter's EPHEMERAL peer, not their identity.
	provCh := kdht.FindProvidersAsync(dctx, rcid, 4)
	var lastErr error = errors.New("no provider found for this invite")
	for ai := range provCh {
		if ai.ID == "" || ai.ID == h.ID() {
			continue
		}
		card, rerr := n.exchangeWithProvider(dctx, h, relays, ai, key, myCardJSON)
		if rerr == nil {
			return card, nil
		}
		lastErr = rerr
	}
	return "", lastErr
}

// exchangeWithProvider dials one candidate provider and runs the card swap.
func (n *Node) exchangeWithProvider(
	ctx context.Context,
	h host.Host,
	relays []peer.AddrInfo,
	ai peer.AddrInfo,
	key []byte,
	myCardJSON string,
) (string, error) {
	if len(ai.Addrs) > 0 {
		h.Peerstore().AddAddrs(ai.ID, ai.Addrs, 10*time.Minute)
	}
	// Relay-circuit fallback, mirroring Send(): the inviter is mobile and is
	// reachable only through a relay it reserved on.
	for _, r := range relays {
		suffix, serr := multiaddr.NewMultiaddr("/p2p/" + r.ID.String() + "/p2p-circuit")
		if serr != nil {
			continue
		}
		for _, ra := range r.Addrs {
			h.Peerstore().AddAddrs(ai.ID, []multiaddr.Multiaddr{ra.Encapsulate(suffix)}, 10*time.Minute)
		}
	}

	cctx := network.WithAllowLimitedConn(ctx, "raven-rendezvous")
	s, err := h.NewStream(cctx, ai.ID, rendezvousProtocol)
	if err != nil {
		return "", fmt.Errorf("open rendezvous stream: %w", err)
	}
	defer s.Close()
	_ = s.SetDeadline(time.Now().Add(rendezvousStreamTimeout))

	r := bufio.NewReader(s)
	inviterSealed, err := readFrame(r, maxCardBytes)
	if err != nil {
		return "", fmt.Errorf("read inviter card: %w", err)
	}
	inviterCard, err := openCard(key, inviterSealed, aadInviterCard)
	if err != nil {
		// Wrong token, or this provider is not who the token points at.
		return "", errors.New("invite token does not match this rendezvous")
	}

	mySealed, err := sealCard(key, []byte(myCardJSON), aadRedeemerCard)
	if err != nil {
		return "", err
	}
	if err := writeFrame(s, mySealed); err != nil {
		return "", fmt.Errorf("send our card: %w", err)
	}
	return string(inviterCard), nil
}

// CancelInvite tears down a live invite: stops advertising, closes the ephemeral
// host, and drops its identity. Safe to call twice.
func (n *Node) CancelInvite(token string) error {
	n.inviteMu.Lock()
	inv, ok := n.invites[token]
	if ok {
		delete(n.invites, token)
	}
	n.inviteMu.Unlock()
	if !ok {
		return nil
	}
	return inv.teardown()
}

// teardown releases everything an invite holds: the DHT, the ephemeral host
// (which drops its relay reservations), and the context driving the expiry
// goroutine. Closing the host is what stops the sealed card being served.
func (inv *invite) teardown() error {
	if inv.cancel != nil {
		inv.cancel()
	}
	if inv.dht != nil {
		_ = inv.dht.Close()
	}
	if inv.host != nil {
		return inv.host.Close()
	}
	return nil
}

// CancelAllInvites tears down every live invite. Called from Node.Stop so an
// app going away does not leave ephemeral hosts advertising a card nobody is
// waiting for, holding relay slots on someone else's node.
func (n *Node) CancelAllInvites() {
	n.inviteMu.Lock()
	live := n.invites
	n.invites = map[string]*invite{}
	n.inviteMu.Unlock()
	for _, inv := range live {
		_ = inv.teardown()
	}
}

// InviteRedeemedCard returns the redeemer's card once someone has completed the
// exchange, or "" while still pending. Lets Swift poll if it would rather not
// rely solely on the delegate callback.
func (n *Node) InviteRedeemedCard(token string) string {
	n.inviteMu.Lock()
	inv, ok := n.invites[token]
	n.inviteMu.Unlock()
	if !ok || inv == nil {
		return ""
	}
	inv.mu.Lock()
	defer inv.mu.Unlock()
	return string(inv.peerCardRaw)
}

// ─── Framing ─────────────────────────────────────────────────────────────────

func writeFrame(w io.Writer, payload []byte) error {
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(payload)))
	if _, err := w.Write(hdr[:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func readFrame(r *bufio.Reader, max int) ([]byte, error) {
	var hdr [4]byte
	if _, err := readFull(r, hdr[:]); err != nil {
		return nil, err
	}
	n := int(binary.BigEndian.Uint32(hdr[:]))
	if n <= 0 || n > max {
		return nil, fmt.Errorf("frame length %d out of range", n)
	}
	buf := make([]byte, n)
	if _, err := readFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}
