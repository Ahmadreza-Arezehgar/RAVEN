package ravenbridge

import (
	"bytes"
	"context"
	"crypto/rand"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/core/network"
	"github.com/libp2p/go-libp2p/core/peer"
)

func mustToken(t *testing.T) []byte {
	t.Helper()
	tok := make([]byte, tokenBytes)
	if _, err := rand.Read(tok); err != nil {
		t.Fatalf("rand: %v", err)
	}
	return tok
}

// ─── Derivation ──────────────────────────────────────────────────────────────

func TestDerivationIsDeterministic(t *testing.T) {
	tok := mustToken(t)

	c1, err := rendezvousCID(tok)
	if err != nil {
		t.Fatalf("cid: %v", err)
	}
	c2, err := rendezvousCID(tok)
	if err != nil {
		t.Fatalf("cid: %v", err)
	}
	if !c1.Equals(c2) {
		t.Fatal("same token produced different CIDs; inviter and redeemer would never meet")
	}

	k1, _ := rendezvousKey(tok)
	k2, _ := rendezvousKey(tok)
	if !bytes.Equal(k1, k2) {
		t.Fatal("same token produced different keys")
	}
	if len(k1) != 32 {
		t.Fatalf("expected a 32-byte key, got %d", len(k1))
	}
}

func TestDistinctTokensDoNotCollide(t *testing.T) {
	seenCID := map[string]bool{}
	seenKey := map[string]bool{}
	for i := 0; i < 200; i++ {
		tok := mustToken(t)
		c, err := rendezvousCID(tok)
		if err != nil {
			t.Fatalf("cid: %v", err)
		}
		k, err := rendezvousKey(tok)
		if err != nil {
			t.Fatalf("key: %v", err)
		}
		if seenCID[c.String()] {
			t.Fatal("CID collision across distinct tokens")
		}
		if seenKey[string(k)] {
			t.Fatal("key collision across distinct tokens")
		}
		seenCID[c.String()] = true
		seenKey[string(k)] = true
	}
}

// The DHT publicly exposes the CID. If the key were derivable from it, any
// observer could open the sealed cards without ever holding the token.
func TestCIDDoesNotRevealKey(t *testing.T) {
	tok := mustToken(t)
	c, _ := rendezvousCID(tok)
	k, _ := rendezvousKey(tok)

	if bytes.Contains(c.Bytes(), k) {
		t.Fatal("key material appears inside the published CID")
	}
	if bytes.Contains(k, c.Hash()) {
		t.Fatal("CID digest appears inside the key")
	}
}

// ─── Sealing ─────────────────────────────────────────────────────────────────

func TestSealOpenRoundTrip(t *testing.T) {
	key, _ := rendezvousKey(mustToken(t))
	card := []byte(`{"u":"AAAA-BBBB-CCCC","ik":"...","ak":"..."}`)

	sealed, err := sealCard(key, card, aadInviterCard)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if bytes.Contains(sealed, card) {
		t.Fatal("plaintext card is visible in the sealed output")
	}

	opened, err := openCard(key, sealed, aadInviterCard)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if !bytes.Equal(opened, card) {
		t.Fatal("round trip did not preserve the card")
	}
}

func TestWrongTokenCannotOpen(t *testing.T) {
	good, _ := rendezvousKey(mustToken(t))
	bad, _ := rendezvousKey(mustToken(t))
	sealed, _ := sealCard(good, []byte("secret card"), aadInviterCard)

	if _, err := openCard(bad, sealed, aadInviterCard); err == nil {
		t.Fatal("a card opened under the wrong token")
	}
}

func TestTamperedCiphertextIsRejected(t *testing.T) {
	key, _ := rendezvousKey(mustToken(t))
	sealed, _ := sealCard(key, []byte("secret card"), aadInviterCard)

	for _, i := range []int{0, len(sealed) / 2, len(sealed) - 1} {
		tampered := append([]byte(nil), sealed...)
		tampered[i] ^= 0x01
		if _, err := openCard(key, tampered, aadInviterCard); err == nil {
			t.Fatalf("tampering at byte %d was not detected", i)
		}
	}
}

// The two legs must not be interchangeable: a relay that echoes the inviter's
// own sealed card back must not have it open as the peer's card.
func TestDirectionTagPreventsLegSwap(t *testing.T) {
	key, _ := rendezvousKey(mustToken(t))
	inviter, _ := sealCard(key, []byte("inviter card"), aadInviterCard)

	if _, err := openCard(key, inviter, aadRedeemerCard); err == nil {
		t.Fatal("inviter's card opened under the redeemer direction tag")
	}
}

func TestShortSealedInputIsRejected(t *testing.T) {
	key, _ := rendezvousKey(mustToken(t))
	if _, err := openCard(key, []byte{1, 2, 3}, aadInviterCard); err == nil {
		t.Fatal("a truncated sealed card was accepted")
	}
}

// ─── Token encoding ──────────────────────────────────────────────────────────

func TestTokenEncodingRoundTrip(t *testing.T) {
	tok := mustToken(t)
	s := tokenEncoding.EncodeToString(tok)
	back, err := tokenEncoding.DecodeString(s)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !bytes.Equal(tok, back) {
		t.Fatal("token did not survive encoding")
	}
}

func TestRedeemRejectsMalformedToken(t *testing.T) {
	n := &Node{}
	for _, bad := range []string{"", "!!!!", "AAAA"} {
		if _, err := n.RedeemInvite(bad, `{"u":"x"}`); err == nil {
			t.Fatalf("malformed token %q was accepted", bad)
		}
	}
}

// ─── Integration: real hosts, real protocol ──────────────────────────────────

type capturingDelegate struct {
	redeemed chan string
}

func (d *capturingDelegate) OnEnvelope(string, string) {}
func (d *capturingDelegate) OnStatus(bool, string)     {}
func (d *capturingDelegate) OnInviteRedeemed(_ string, peerCardJSON string) {
	select {
	case d.redeemed <- peerCardJSON:
	default:
	}
}

func newTestHost(t *testing.T) host.Host {
	t.Helper()
	h, err := libp2p.New(
		libp2p.ListenAddrStrings("/ip4/127.0.0.1/tcp/0"),
		libp2p.DefaultTransports,
		libp2p.DefaultSecurity,
	)
	if err != nil {
		t.Fatalf("host: %v", err)
	}
	t.Cleanup(func() { _ = h.Close() })
	return h
}

// Drives the full card swap over /raven/rdv/1.0.0 between two real libp2p
// hosts, bypassing only the DHT lookup (no public network in a unit test).
func TestRendezvousCardExchangeBetweenTwoHosts(t *testing.T) {
	inviterHost := newTestHost(t)
	redeemerHost := newTestHost(t)

	token := mustToken(t)
	key, err := rendezvousKey(token)
	if err != nil {
		t.Fatalf("key: %v", err)
	}

	inviterCard := `{"u":"ALIC-EAAA-AAAA","role":"inviter"}`
	redeemerCard := `{"u":"SARA-BBBB-BBBB","role":"redeemer"}`

	sealed, err := sealCard(key, []byte(inviterCard), aadInviterCard)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}

	del := &capturingDelegate{redeemed: make(chan string, 1)}
	inviterNode := &Node{delegate: del}
	inv := &invite{
		token:      token,
		key:        key,
		sealedCard: sealed,
		host:       inviterHost,
		expiresAt:  time.Now().Add(time.Minute),
	}
	inviterHost.SetStreamHandler(rendezvousProtocol, func(s network.Stream) {
		inviterNode.handleRendezvous(inv, s)
	})

	redeemerNode := &Node{}
	ai := peer.AddrInfo{ID: inviterHost.ID(), Addrs: inviterHost.Addrs()}

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	got, err := redeemerNode.exchangeWithProvider(ctx, redeemerHost, nil, ai, key, redeemerCard)
	if err != nil {
		t.Fatalf("exchange: %v", err)
	}
	if got != inviterCard {
		t.Fatalf("redeemer got %q, want %q", got, inviterCard)
	}

	select {
	case peerCard := <-del.redeemed:
		if peerCard != redeemerCard {
			t.Fatalf("inviter got %q, want %q", peerCard, redeemerCard)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("inviter never received the redeemer's card")
	}

	if stored := inviterNode.InviteRedeemedCard(tokenEncoding.EncodeToString(token)); stored != "" {
		// Not registered in n.invites here (constructed directly), so "" is
		// expected — this asserts the accessor does not panic on a miss.
		t.Fatalf("unexpected stored card for an unregistered invite: %q", stored)
	}
}

// A peer holding the WRONG token must not complete the exchange, even when it
// can reach the rendezvous and speak the protocol.
func TestExchangeFailsWithWrongToken(t *testing.T) {
	inviterHost := newTestHost(t)
	redeemerHost := newTestHost(t)

	goodToken := mustToken(t)
	goodKey, _ := rendezvousKey(goodToken)
	wrongKey, _ := rendezvousKey(mustToken(t))

	sealed, _ := sealCard(goodKey, []byte(`{"u":"ALIC-EAAA-AAAA"}`), aadInviterCard)

	del := &capturingDelegate{redeemed: make(chan string, 1)}
	inviterNode := &Node{delegate: del}
	inv := &invite{token: goodToken, key: goodKey, sealedCard: sealed, host: inviterHost}
	inviterHost.SetStreamHandler(rendezvousProtocol, func(s network.Stream) {
		inviterNode.handleRendezvous(inv, s)
	})

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	redeemerNode := &Node{}
	ai := peer.AddrInfo{ID: inviterHost.ID(), Addrs: inviterHost.Addrs()}

	if _, err := redeemerNode.exchangeWithProvider(ctx, redeemerHost, nil, ai, wrongKey, `{"u":"MALL-ORYY-YYYY"}`); err == nil {
		t.Fatal("exchange succeeded with the wrong token")
	}

	// And the inviter must not have accepted the attacker's card.
	select {
	case card := <-del.redeemed:
		t.Fatalf("inviter accepted a card from a wrong-token peer: %q", card)
	case <-time.After(2 * time.Second):
	}
}

func TestCreateInviteRequiresStartedNode(t *testing.T) {
	n := &Node{}
	if _, err := n.CreateInvite(`{"u":"x"}`, 600); err == nil {
		t.Fatal("CreateInvite succeeded on an unstarted node")
	}
}

func TestCancelInviteIsIdempotent(t *testing.T) {
	n := &Node{invites: map[string]*invite{}}
	if err := n.CancelInvite("nope"); err != nil {
		t.Fatalf("cancelling an unknown invite errored: %v", err)
	}
	if err := n.CancelInvite("nope"); err != nil {
		t.Fatalf("second cancel errored: %v", err)
	}
}

// ─── Ephemeral-identity regression ───────────────────────────────────────────

// The rendezvous exists to let strangers connect WITHOUT exposing the
// permanent device identity. An earlier version advertised through the main
// node's DHT, so the provider record named the permanent PeerID — leaking the
// inviter's identity and IP to anyone who could compute the CID, and pointing
// redeemers at a host that does not even serve the rendezvous protocol. The
// existing integration tests could not catch it because they dial the provider
// directly and never consult the DHT. This asserts the separation structurally.
func TestInviteUsesEphemeralIdentityNotDeviceIdentity(t *testing.T) {
	mainHost := newTestHost(t)

	n := &Node{
		host:    mainHost,
		started: true,
		invites: map[string]*invite{},
	}

	token, err := n.CreateInvite(`{"u":"ALIC-EAAA-AAAA"}`, 60)
	if err != nil {
		t.Fatalf("CreateInvite: %v", err)
	}
	t.Cleanup(func() { _ = n.CancelInvite(token) })

	n.inviteMu.Lock()
	inv := n.invites[token]
	n.inviteMu.Unlock()
	if inv == nil {
		t.Fatal("invite was not registered")
	}

	if inv.host == nil {
		t.Fatal("invite has no ephemeral host")
	}
	if inv.host.ID() == mainHost.ID() {
		t.Fatal("invite is served by the DEVICE identity — the ephemeral key is not in use")
	}
	if inv.dht == nil {
		t.Fatal("invite has no DHT of its own; provider records would carry the device PeerID")
	}
	// The DHT that publishes the provider record must belong to the ephemeral
	// host, since Provide announces whichever host the DHT is attached to.
	if inv.dht.Host().ID() != inv.host.ID() {
		t.Fatalf("invite DHT is attached to %s, want ephemeral host %s",
			inv.dht.Host().ID(), inv.host.ID())
	}
}

// Stopping the node must release every invite's ephemeral host and relay slots.
func TestStopTearsDownLiveInvites(t *testing.T) {
	mainHost := newTestHost(t)
	n := &Node{host: mainHost, started: true, invites: map[string]*invite{}}

	tok, err := n.CreateInvite(`{"u":"ALIC-EAAA-AAAA"}`, 60)
	if err != nil {
		t.Fatalf("CreateInvite: %v", err)
	}
	n.inviteMu.Lock()
	inv := n.invites[tok]
	n.inviteMu.Unlock()
	ephID := inv.host.ID()

	n.CancelAllInvites()

	n.inviteMu.Lock()
	remaining := len(n.invites)
	n.inviteMu.Unlock()
	if remaining != 0 {
		t.Fatalf("invites still registered after teardown: %d", remaining)
	}
	// The ephemeral host must be closed: a fresh peer must not be able to open
	// a rendezvous stream to it any more.
	probe := newTestHost(t)
	probe.Peerstore().AddAddrs(ephID, inv.host.Addrs(), time.Minute)
	pctx, pcancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer pcancel()
	if _, err := probe.NewStream(pctx, ephID, rendezvousProtocol); err == nil {
		t.Fatal("ephemeral host still serving the rendezvous after teardown")
	}
}
