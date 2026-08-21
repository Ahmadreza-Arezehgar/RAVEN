package mailbox

import (
	"context"
	"crypto/ed25519"
	"testing"
	"time"

	libp2p "github.com/libp2p/go-libp2p"
	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"
	multiaddr "github.com/multiformats/go-multiaddr"
)

func TestDepositFetch(t *testing.T) {
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = 0x11
	}
	srv, err := NewServer(seed)
	if err != nil {
		t.Fatal(err)
	}
	go srv.GC(context.Background())
	defer srv.Host().Close()

	// recipient identity (alice)
	aliceSeed := make([]byte, 32)
	for i := range aliceSeed {
		aliceSeed[i] = 0x22
	}
	std := ed25519.NewKeyFromSeed(aliceSeed)
	priv, _, err := crypto.KeyPairFromStdKey(&std)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := peer.IDFromPrivateKey(priv)
	if err != nil {
		t.Fatal(err)
	}

	var addr string
	for _, a := range srv.Host().Addrs() {
		if m, err := multiaddr.NewMultiaddr(a.String() + "/p2p/" + srv.Host().ID().String()); err == nil {
			if p := m.Protocols(); len(p) > 0 && p[0].Code == multiaddr.P_IP4 && a.String()[5:10] == "127.0" {
				addr = m.String()
			}
		}
	}
	if addr == "" {
		t.Fatal("no loopback addr")
	}
	t.Logf("mailbox at %s, recipient %s", addr, pid)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	n, err := Deposit(ctx, addr, pid.String(), "idem-1", "cGF5bG9hZDE=")
	if err != nil {
		t.Fatalf("deposit: %v", err)
	}
	t.Logf("bucket=%d", n)

	got, err := Fetch(ctx, aliceSeed, addr)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if len(got) != 1 || got[0].PayloadB64 != "cGF5bG9hZDE=" {
		t.Fatalf("fetch got %+v", got)
	}

	// bucket cleared
	got2, err := Fetch(ctx, aliceSeed, addr)
	if err != nil {
		t.Fatalf("fetch2: %v", err)
	}
	if len(got2) != 0 {
		t.Fatalf("bucket not cleared: %+v", got2)
	}
}

var _ = libp2p.NoListenAddrs
