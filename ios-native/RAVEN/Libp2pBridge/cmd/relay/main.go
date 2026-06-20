// Command relay runs a standalone go-libp2p relay + DHT-bootstrap node for
// RAVEN's serverless internet bridge. It is the piece of infrastructure the
// mobile clients bootstrap from: a Circuit Relay v2 server (so NAT-blocked
// peers can reach each other) and a DHT server (so peers can discover each
// other by PeerID). One tiny VPS runs this; the app points at it via the
// UserDefaults key `raven.libp2p.bootstrap`.
//
// Identity is derived from a fixed dev seed by default so the PeerID — and
// therefore the bootstrap multiaddr you paste into the app — stays stable
// across restarts. Override the seed in production with RAVEN_RELAY_SEED_HEX
// (64 hex chars = 32-byte ed25519 seed).
//
// Build:  go build -o raven-relay ./cmd/relay
// Run:    ./raven-relay            (listens on tcp/udp 4001)
//         RAVEN_RELAY_PORT=4002 ./raven-relay
package main

import (
	"context"
	"crypto/ed25519"
	"encoding/hex"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	libp2p "github.com/libp2p/go-libp2p"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/network"
	multiaddr "github.com/multiformats/go-multiaddr"
)

// connLogger prints peer connect/disconnect events so a live test can see a
// client actually reach the relay.
type connLogger struct{}

func (connLogger) Listen(network.Network, multiaddr.Multiaddr)      {}
func (connLogger) ListenClose(network.Network, multiaddr.Multiaddr) {}
func (connLogger) Connected(n network.Network, c network.Conn) {
	fmt.Printf("[relay] + peer CONNECTED %s via %s (total=%d)\n",
		c.RemotePeer().String(), c.RemoteMultiaddr(), len(n.Peers()))
}
func (connLogger) Disconnected(n network.Network, c network.Conn) {
	fmt.Printf("[relay] - peer disconnected %s (total=%d)\n",
		c.RemotePeer().String(), len(n.Peers()))
}

func main() {
	// Stable identity → stable PeerID → stable bootstrap multiaddr.
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = 0x52 // 'R' — recognizable dev seed
	}
	if h := os.Getenv("RAVEN_RELAY_SEED_HEX"); h != "" {
		b, err := hex.DecodeString(h)
		if err != nil || len(b) != ed25519.SeedSize {
			fmt.Fprintf(os.Stderr, "RAVEN_RELAY_SEED_HEX must be %d hex bytes\n", ed25519.SeedSize)
			os.Exit(1)
		}
		seed = b
	}
	std := ed25519.NewKeyFromSeed(seed)
	priv, _, err := crypto.KeyPairFromStdKey(&std)
	if err != nil {
		panic(err)
	}

	port := "4001"
	if p := os.Getenv("RAVEN_RELAY_PORT"); p != "" {
		port = p
	}

	ctx := context.Background()
	h, err := libp2p.New(
		libp2p.Identity(priv),
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/tcp/%s", port),
			fmt.Sprintf("/ip4/0.0.0.0/udp/%s/quic-v1", port),
		),
		libp2p.DefaultTransports,
		libp2p.DefaultSecurity,
		// Force public reachability so the relay confidently runs the Circuit
		// Relay v2 HOP service and advertises /libp2p/circuit/relay/0.2.0/hop.
		// Without this, AutoNAT on a localhost/LAN box may classify the relay as
		// private and the hop service stays off → client reservations fail with
		// "protocols not supported: [/libp2p/circuit/relay/0.2.0/hop]".
		libp2p.ForceReachabilityPublic(),
		libp2p.EnableRelayService(), // Circuit Relay v2 server (hop)
		libp2p.EnableNATService(),
	)
	if err != nil {
		panic(err)
	}
	h.Network().Notify(connLogger{})

	// DHT in SERVER mode so the client-mode mobile DHTs can bootstrap from us
	// and resolve each other's PeerIDs.
	kdht, err := dht.New(ctx, h, dht.Mode(dht.ModeServer))
	if err != nil {
		_ = h.Close()
		panic(err)
	}
	if err := kdht.Bootstrap(ctx); err != nil {
		fmt.Printf("[relay] dht bootstrap warning: %v\n", err)
	}

	fmt.Printf("[relay] RAVEN relay/bootstrap node up.\n[relay] PeerID: %s\n", h.ID().String())
	fmt.Println("[relay] Paste ONE of these into the app's `raven.libp2p.bootstrap`:")
	for _, a := range h.Addrs() {
		fmt.Printf("[relay]   %s/p2p/%s\n", a, h.ID().String())
	}

	c := make(chan os.Signal, 1)
	signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
	<-c
	fmt.Println("\n[relay] shutting down")
	_ = kdht.Close()
	_ = h.Close()
}
