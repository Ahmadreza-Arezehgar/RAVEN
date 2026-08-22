package invite

import (
	"crypto/ed25519"
	"crypto/rand"
	"strings"
	"testing"
	"time"

	"github.com/raven/ravenbridge/pkg/identity"
)

func testKeys(t *testing.T) (ed25519.PrivateKey, []byte, []byte) {
	t.Helper()
	id, err := identity.Generate()
	if err != nil {
		t.Fatal(err)
	}
	return id.Seed, id.PublicKey(), id.X25519Pub
}

func TestRoundTrip(t *testing.T) {
	priv, edPub, xPub := testKeys(t)
	code, err := Build(priv, edPub, xPub, "Alice", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	str, err := code.Encode()
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(str, HRP+"1") {
		t.Fatalf("code must start with %s1, got %q", HRP, str[:8])
	}
	got, err := Decode(str)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if string(got.IdentityPub) != string(edPub) ||
		string(got.AgreementPub) != string(xPub) ||
		got.IssuedAt != code.IssuedAt ||
		got.Name != "Alice" {
		t.Fatalf("fields mismatch: %+v vs %+v", got, code)
	}
}

func TestFingerprintMatchesIdentityPackage(t *testing.T) {
	_, edPub, _ := testKeys(t)
	want, err := identity.Fingerprint(edPub)
	if err != nil {
		t.Fatal(err)
	}
	if got := FingerprintOf(edPub); got != want {
		t.Fatalf("fingerprint derivation mismatch: %s vs %s", got, want)
	}
}

func TestTamperRejected(t *testing.T) {
	priv, edPub, xPub := testKeys(t)
	inv, _ := Build(priv, edPub, xPub, "", time.Now())
	code, err := inv.Encode()
	if err != nil {
		t.Fatal(err)
	}
	raw := []byte(code)
	mutated := string(raw)
	// flip one data character to another charset char
	i := strings.Index(mutated, "1") + 2
	old := mutated[i]
	repl := byte('p')
	if old == 'p' {
		repl = 'q'
	}
	mutated = mutated[:i] + string(repl) + mutated[i+1:]
	if _, err := Decode(mutated); err == nil {
		t.Fatal("tampered code must fail")
	}

	// signature from a DIFFERENT key must fail
	otherPriv, otherEdPub, otherXPub := testKeys(t)
	forged := &Invite{IdentityPub: edPub, AgreementPub: xPub, IssuedAt: inv.IssuedAt}
	forged.Signature = ed25519.Sign(otherPriv, forged.Transcript())
	if string(forged.IdentityPub) == string(otherEdPub) && string(forged.AgreementPub) == string(otherXPub) {
		t.Fatal("test setup degenerate")
	}
	s, _ := forged.Encode()
	if _, err := Decode(s); err == nil {
		t.Fatal("forged signature must fail")
	}

	// swapped agreement key breaks transcript
	swapped := &Invite{IdentityPub: edPub, AgreementPub: otherXPub, IssuedAt: inv.IssuedAt, Signature: inv.Signature}
	s, _ = swapped.Encode()
	if _, err := Decode(s); err == nil {
		t.Fatal("swapped key must fail signature")
	}
}

func TestFreshnessWindow(t *testing.T) {
	priv, edPub, xPub := testKeys(t)
	old, _ := Build(priv, edPub, xPub, "", time.Now().Add(-25*time.Hour))
	s, _ := old.Encode()
	if _, err := Decode(s); err == nil || !strings.Contains(err.Error(), "24h") {
		t.Fatalf("expired invite must be rejected with window error, got %v", err)
	}
	future, _ := Build(priv, edPub, xPub, "", time.Now().Add(6*time.Minute))
	s, _ = future.Encode()
	if _, err := Decode(s); err == nil {
		t.Fatal("future-dated invite must be rejected")
	}
}

func TestUnknownTLVIgnored(t *testing.T) {
	priv, edPub, xPub := testKeys(t)
	inv, _ := Build(priv, edPub, xPub, "Zoe", time.Now())
	payload := append(inv.signedPayload(), appendTLV(nil, tlvSignature, inv.Signature)...)
	payload = append(payload, 0x7f, 3, 'a', 'b', 'c') // unknown type 0x7f
	s, err := bech32mEncode(HRP, payload)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Decode(s)
	if err != nil {
		t.Fatalf("unknown TLV should be ignored, got %v", err)
	}
	if got.Name != "Zoe" {
		t.Fatalf("name lost: %q", got.Name)
	}
}

func TestNormalizeCodeAcceptsWrapperAndPunctuation(t *testing.T) {
	priv, edPub, xPub := testKeys(t)
	inv, _ := Build(priv, edPub, xPub, "", time.Now())
	code, _ := inv.Encode()
	for _, wrapped := range []string{
		"https://raven-messager.com/i#" + code,
		"<" + code + ">",
		"  \n " + code + " . ",
		"check this out " + code + ", thanks!",
	} {
		if _, err := Decode(wrapped); err != nil {
			t.Fatalf("wrapper form rejected: %v (%q)", err, wrapped)
		}
	}
}

func TestWordlistUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, w := range ravenWords {
		if seen[w] {
			t.Fatalf("duplicate word %q", w)
		}
		seen[w] = true
	}
	if len(seen) != 256 {
		t.Fatalf("want 256 words, got %d", len(seen))
	}
}

func TestWordsDeterministic(t *testing.T) {
	_, edPub, _ := testKeys(t)
	a := Words(edPub)
	b := Words(edPub)
	if a != b || len(strings.Fields(a)) != 4 {
		t.Fatalf("words must be deterministic 4-tuple, got %q/%q", a, b)
	}
}

func TestBech32mAgainstBIP350Vector(t *testing.T) {
	// BIP-350 "valid Bech32m" vectors.
	for _, vec := range []struct{ s, hrp string }{
		{"abcdef1l7aum6echk45nj3s0wdvt2fg8x9yrzpqzd3ryx", "abcdef"},
		{"split1checkupstagehandshakeupstreamerranterredcaperredlc445v", "split"},
		{"a1lqfn3a", "a"},
	} {
		if _, err := bech32mDecode(vec.s, vec.hrp); err != nil {
			t.Fatalf("reference vector %q must decode: %v", vec.s, err)
		}
	}
	// This one is a VALID BECH32 (BIP-173) string and must FAIL as bech32m.
	bech32NotM := "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw"
	if _, err := bech32mDecode(bech32NotM, "abcdef"); err == nil {
		t.Fatal("bech32 checksum must not verify as bech32m")
	}
	// our own encoding must round-trip and detect mutations
	got, err := bech32mEncode(HRP, []byte{0xde, 0xad, 0xbe, 0xef})
	if err != nil {
		t.Fatal(err)
	}
	if back, err := bech32mDecode(got, HRP); err != nil || string(back) != "\xde\xad\xbe\xef" {
		t.Fatalf("roundtrip failed: %v %q", err, back)
	}
	bad := []byte(got)
	if bad[len(bad)-2] == 'p' {
		bad[len(bad)-2] = 'q'
	} else {
		bad[len(bad)-2] = 'p'
	}
	if _, err := bech32mDecode(string(bad), HRP); err == nil {
		t.Fatal("mutated checksum must fail")
	}
}

func TestRandomKeysRoundTrip(t *testing.T) {
	for i := 0; i < 5; i++ {
		pub, priv, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		x := make([]byte, 32)
		rand.Read(x)
		inv, _ := Build(priv, pub, x, "k", time.Now())
		s, _ := inv.Encode()
		got, err := Decode(s)
		if err != nil {
			t.Fatalf("iter %d: %v", i, err)
		}
		if got.Name != "k" {
			t.Fatal("name mismatch")
		}
	}
}
