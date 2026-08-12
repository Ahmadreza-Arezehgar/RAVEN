package ravenbridge

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/host"
	"github.com/libp2p/go-libp2p/p2p/protocol/circuitv2/relay"
)

// End-to-end verification of the internet bridge.
//
// The scenario is the real one: two RAVEN phones, neither publicly dialable
// (behind NAT, no inbound port), reaching each other only through a Circuit
// Relay v2 node — which is exactly what `cmd/relay/main.go` is for. This
// exercises the production path (Node.Start → reserveRelays → Node.Send →
// handleStream → Delegate.OnEnvelope) rather than a hand-wired stub, so it
// covers the relay-circuit address construction in Send() that the unit tests
// never touch.

// recordingDelegate captures envelopes delivered to a node.
type recordingDelegate struct {
	mu        sync.Mutex
	envelopes []string
	idemKeys  []string
	got       chan struct{}
}

func newRecordingDelegate() *recordingDelegate {
	return &recordingDelegate{got: make(chan struct{}, 8)}
}

func (d *recordingDelegate) OnEnvelope(env string, idem string) {
	d.mu.Lock()
	d.envelopes = append(d.envelopes, env)
	d.idemKeys = append(d.idemKeys, idem)
	d.mu.Unlock()
	select {
	case d.got <- struct{}{}:
	default:
	}
}
func (d *recordingDelegate) OnStatus(bool, string)              {}
func (d *recordingDelegate) OnInviteRedeemed(string, string)    {}
func (d *recordingDelegate) received() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.envelopes...)
}

// startRelay boots a Circuit Relay v2 server, mirroring cmd/relay/main.go.
func startRelay(t *testing.T) host.Host {
	t.Helper()
	h, err := libp2p.New(
		libp2p.ListenAddrStrings("/ip4/127.0.0.1/tcp/0"),
		libp2p.DefaultTransports,
		libp2p.DefaultSecurity,
	)
	if err != nil {
		t.Fatalf("relay host: %v", err)
	}
	if _, err := relay.New(h); err != nil {
		_ = h.Close()
		t.Fatalf("relay service: %v", err)
	}
	t.Cleanup(func() { _ = h.Close() })
	return h
}

// relayCSV renders the relay's full p2p multiaddr as Start() expects.
func relayCSV(t *testing.T, r host.Host) string {
	t.Helper()
	for _, a := range r.Addrs() {
		s := a.String()
		// Prefer a concrete loopback TCP address.
		if len(s) > 0 && s != "/p2p-circuit" {
			return fmt.Sprintf("%s/p2p/%s", s, r.ID())
		}
	}
	t.Fatal("relay has no dialable address")
	return ""
}

// startNode boots a production Node against the relay, using a deterministic
// 32-byte seed so its PeerID is stable within the test.
func startNode(t *testing.T, seedByte byte, csv string, del Delegate) *Node {
	t.Helper()
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = seedByte
	}
	n, err := NewNode(seed, del)
	if err != nil {
		t.Fatalf("NewNode: %v", err)
	}
	if err := n.Start(csv); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(func() { _ = n.Stop() })
	return n
}

// The headline bridge capability: an envelope crosses from one NAT-bound phone
// to another through a relay, with no direct connectivity between them.
func TestBridgeDeliversEnvelopeThroughCircuitRelay(t *testing.T) {
	r := startRelay(t)
	csv := relayCSV(t, r)

	recvDel := newRecordingDelegate()
	receiver := startNode(t, 0xB0, csv, recvDel)
	sender := startNode(t, 0xA0, csv, newRecordingDelegate())

	// Give both peers a moment to complete their relay reservations.
	time.Sleep(1500 * time.Millisecond)

	const envelope = "UlZOUzEAAAB0ZXN0LWNpcGhlcnRleHQ=" // opaque, as the bridge treats it
	const idem = "idem-key-001"

	if err := sender.Send(receiver.PeerID(), envelope, idem); err != nil {
		t.Fatalf("Send through relay failed: %v", err)
	}

	select {
	case <-recvDel.got:
	case <-time.After(20 * time.Second):
		t.Fatal("receiver never got the envelope — the internet bridge is not delivering")
	}

	got := recvDel.received()
	if len(got) != 1 || got[0] != envelope {
		t.Fatalf("receiver got %v, want exactly [%q]", got, envelope)
	}
	if recvDel.idemKeys[0] != idem {
		t.Fatalf("idempotency key = %q, want %q", recvDel.idemKeys[0], idem)
	}
}

// PeerID must derive deterministically from the device key, since that is what
// lets a QR-scanned contact be dialed with no directory lookup.
func TestPeerIDIsDeterministicFromDeviceKey(t *testing.T) {
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = 0x42
	}
	del := newRecordingDelegate()
	a, err := NewNode(seed, del)
	if err != nil {
		t.Fatalf("NewNode: %v", err)
	}
	b, err := NewNode(seed, del)
	if err != nil {
		t.Fatalf("NewNode: %v", err)
	}
	if a.PeerID() == "" || a.PeerID() != b.PeerID() {
		t.Fatalf("PeerID not deterministic: %q vs %q", a.PeerID(), b.PeerID())
	}
}

// Multiple envelopes must all arrive, each with its own idempotency key — the
// receiver's dedup is keyed on it, so collapsing them would silently drop
// messages.
func TestBridgeDeliversMultipleEnvelopesInOrder(t *testing.T) {
	r := startRelay(t)
	csv := relayCSV(t, r)

	recvDel := newRecordingDelegate()
	receiver := startNode(t, 0xC0, csv, recvDel)
	sender := startNode(t, 0xD0, csv, newRecordingDelegate())

	time.Sleep(1500 * time.Millisecond)

	const count = 3
	for i := 0; i < count; i++ {
		env := fmt.Sprintf("envelope-%d", i)
		if err := sender.Send(receiver.PeerID(), env, fmt.Sprintf("idem-%d", i)); err != nil {
			t.Fatalf("Send %d: %v", i, err)
		}
	}

	deadline := time.After(25 * time.Second)
	for len(recvDel.received()) < count {
		select {
		case <-recvDel.got:
		case <-deadline:
			t.Fatalf("only %d/%d envelopes arrived", len(recvDel.received()), count)
		}
	}

	got := recvDel.received()
	for i := 0; i < count; i++ {
		want := fmt.Sprintf("envelope-%d", i)
		if got[i] != want {
			t.Fatalf("envelope %d = %q, want %q", i, got[i], want)
		}
	}
}

// Sending to a peer that does not exist must fail cleanly rather than hang or
// panic — the app surfaces this as a delivery failure and falls back to mesh.
func TestBridgeSendToUnknownPeerFails(t *testing.T) {
	r := startRelay(t)
	csv := relayCSV(t, r)
	sender := startNode(t, 0xE0, csv, newRecordingDelegate())

	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		// Well-formed but unreachable PeerID.
		done <- sender.Send("12D3KooWGRUBUJ8kZBHnDmMDMSbMFVMSGFyDPPvJDCUnkxvNCrTr", "x", "y")
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("Send to an unreachable peer unexpectedly succeeded")
		}
	case <-ctx.Done():
		t.Fatal("Send to an unreachable peer hung instead of failing")
	}
}
