package main

import (
	"context"
	"crypto/ed25519"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	libp2p "github.com/libp2p/go-libp2p"
	dht "github.com/libp2p/go-libp2p-kad-dht"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/network"
	multiaddr "github.com/multiformats/go-multiaddr"

	mbox "github.com/raven/ravenbridge/pkg/mailbox"
)

// cmdRelay runs a community Circuit Relay v2 + DHT bootstrap node — the only
// "infrastructure" the serverless internet path needs, runnable by anyone.
func cmdRelay() error {
	port := os.Getenv("RAVEN_RELAY_PORT")
	if port == "" {
		port = "4001"
	}
	priv := devRelayKey()
	h, err := libp2p.New(
		libp2p.Identity(priv),
		libp2p.ListenAddrStrings(
			fmt.Sprintf("/ip4/0.0.0.0/tcp/%s", port),
			fmt.Sprintf("/ip4/0.0.0.0/udp/%s/quic-v1", port),
		),
		libp2p.DefaultTransports,
		libp2p.DefaultSecurity,
		libp2p.ForceReachabilityPublic(),
		libp2p.EnableRelayService(),
		libp2p.EnableNATService(),
	)
	if err != nil {
		return err
	}
	h.Network().Notify(relayConnLogger{})

	ctx := context.Background()
	kdht, err := dht.New(ctx, h, dht.Mode(dht.ModeServer))
	if err != nil {
		_ = h.Close()
		return err
	}
	_ = kdht.Bootstrap(ctx)

	fmt.Println("[relay] RAVEN relay/bootstrap node up")
	fmt.Printf("[relay] PeerID: %s\n", h.ID().String())
	fmt.Println("[relay] set RAVEN_BOOTSTRAP (clients) / raven.libp2p.bootstrap (iOS) to:")
	for _, a := range h.Addrs() {
		fmt.Printf("[relay]   %s/p2p/%s\n", a, h.ID().String())
	}
	c := make(chan os.Signal, 1)
	signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
	<-c
	fmt.Println("\n[relay] shutting down")
	_ = kdht.Close()
	return h.Close()
}

func devRelayKey() crypto.PrivKey {
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = 0x52
	}
	std := ed25519.NewKeyFromSeed(seed)
	priv, _, err := crypto.KeyPairFromStdKey(&std)
	must(err)
	return priv
}

type relayConnLogger struct{}

func (relayConnLogger) Listen(network.Network, multiaddr.Multiaddr)      {}
func (relayConnLogger) ListenClose(network.Network, multiaddr.Multiaddr) {}
func (relayConnLogger) Connected(n network.Network, c network.Conn) {
	fmt.Printf("[relay] + CONNECTED %s via %s (total=%d)\n", c.RemotePeer().String(), c.RemoteMultiaddr(), len(n.Peers()))
}
func (relayConnLogger) Disconnected(n network.Network, c network.Conn) {
	fmt.Printf("[relay] - disconnected %s (total=%d)\n", c.RemotePeer().String(), len(n.Peers()))
}

// cmdMailbox runs the store-and-forward node (/raven/mailbox/1.0.0).
func cmdMailbox() error {
	port := os.Getenv("RAVEN_MAILBOX_PORT")
	if port == "" {
		port = "4002"
	}
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(0x4D) // 'M' dev seed; override via RAVEN_MAILBOX_SEED_HEX
	}
	if h := os.Getenv("RAVEN_MAILBOX_SEED_HEX"); h != "" {
		b := decodeHex(h)
		if len(b) != 32 {
			return fmt.Errorf("RAVEN_MAILBOX_SEED_HEX must be 64 hex chars")
		}
		seed = b
	}
	srv, err := mbox.NewServer(seed)
	if err != nil {
		return err
	}
	host := srv.Host()
	fmt.Printf("[mailbox] node up — PeerID %s\n[mailbox] set RAVEN_MAILBOX to:\n", host.ID().String())
	for _, a := range host.Addrs() {
		fmt.Printf("[mailbox]   %s/p2p/%s\n", a, host.ID().String())
	}
	go srv.GC(context.Background())
	c := make(chan os.Signal, 1)
	signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
	<-c
	fmt.Println("\n[mailbox] shutting down")
	return host.Close()
}

func decodeHex(s string) []byte {
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		out[i] = hexByte(s[i*2])<<4 | hexByte(s[i*2+1])
	}
	return out
}

func hexByte(c byte) byte {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10
	default:
		return 0
	}
}
