package envelope

import (
	"crypto/ed25519"
	crand "crypto/rand"
	"testing"

	"golang.org/x/crypto/curve25519"
)

func genX25519(t *testing.T) (pub, priv []byte) {
	t.Helper()
	priv = make([]byte, curve25519.ScalarSize)
	if _, err := crand.Read(priv); err != nil {
		t.Fatal(err)
	}
	pub, err := curve25519.X25519(priv, curve25519.Basepoint)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

var _ = ed25519.PublicKeySize
