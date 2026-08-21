package identity

import (
	"crypto/ed25519"
	"encoding/hex"
	"testing"
)

// KAT from the Rust twin (node/crates/raven-core/src/fingerprint.rs):
// pub d75a98…511a -> "If4x-36FU-omFi"
func TestFingerprintKAT(t *testing.T) {
	pub, _ := hex.DecodeString("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
	got, err := Fingerprint(pub)
	if err != nil {
		t.Fatal(err)
	}
	if got != "If4x-36FU-omFi" {
		t.Fatalf("fingerprint = %q, want If4x-36FU-omFi", got)
	}
}

func TestSaveLoadRoundTrip(t *testing.T) {
	id, err := Generate()
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	if err := id.Save(dir); err != nil {
		t.Fatal(err)
	}
	loaded, err := Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(loaded.Seed.Seed()) != ed25519.SeedSize || len(loaded.X25519Pub) != 32 {
		t.Fatal("bad load")
	}
	if !loaded.PublicKey().Equal(id.PublicKey()) {
		t.Fatal("pubkey mismatch after reload")
	}
	sig := id.Sign([]byte("x"))
	if !ed25519.Verify(loaded.PublicKey(), []byte("x"), sig) {
		t.Fatal("signature not valid after reload")
	}
}
