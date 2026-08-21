package envelope

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"math"
	"testing"
)

// RFC 8032 test key (same one used by shared-vectors/rvn1).
var (
	aliceSeed = mustHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	alicePub  = mustHex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
)

func mustHex(s string) []byte {
	b, err := base64.StdEncoding.DecodeString(base64.StdEncoding.EncodeToString([]byte{}))
	_ = b
	_ = err
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		hi := hexVal(s[i*2])
		lo := hexVal(s[i*2+1])
		out[i] = byte(hi<<4 | lo)
	}
	return out
}

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	default:
		panic("bad hex")
	}
}

// TestSigningDataShape locks the pipe-delimited layout for a plain text
// message: 21 segments, trailing empties for unset media/reply fields.
func TestSigningDataShape(t *testing.T) {
	text := "hello"
	env := &SecureMeshEnvelope{
		ClientMessageID: "msg-1",
		RoomID:          "A_B",
		SenderID:        "AAAA-BBBB-CCCC",
		SenderName:      "Alice",
		RecipientID:     "DDDD-EEEE-FFFF",
		Type:            TypeText,
		Text:            &text,
		Timestamp:       1700000000.25,
		SprayCounter:    5,
		HopCount:        0,
		HopLimit:        10,
		RoutePath:       []string{},
		OriginDeviceID:  "AAAA-BBBB-CCCC",
		NeedsForwarding: true,
		TTLSeconds:      86400,
		Nonce:           "bm9uY2U=",
		SenderPublicKey: "c3Br",
	}
	got := string(env.SigningData())
	want := "msg-1|A_B|AAAA-BBBB-CCCC|Alice|DDDD-EEEE-FFFF|0|bm9uY2U=|c3Br|1700000000250|AAAA-BBBB-CCCC|hello||||||||||"
	if got != want {
		t.Fatalf("signingData mismatch:\n got: %q\nwant: %q", got, want)
	}
}

// TestPayloadKindSuffix verifies the optional |pk: suffix (friend_request).
func TestPayloadKindSuffix(t *testing.T) {
	text := "{}"
	env := &SecureMeshEnvelope{
		ClientMessageID: "fr-1", RoomID: "r", SenderID: "s", SenderName: "n",
		RecipientID: "r2", Type: TypeSystem, Text: &text, Timestamp: 1,
		OriginDeviceID: "s", Nonce: "x", SenderPublicKey: "k",
		PayloadKind: "friend_request",
	}
	got := string(env.SigningData())
	if !endsWith(got, "|pk:friend_request") {
		t.Fatalf("missing pk suffix: %q", got)
	}
}

func endsWith(s, suf string) bool {
	return len(s) >= len(suf) && s[len(s)-len(suf):] == suf
}

// TestRoundTrip seals and opens a payload between two X25519 pairs.
func TestRoundTrip(t *testing.T) {
	senderSign := ed25519.NewKeyFromSeed(aliceSeed)
	bobXPub, bobXPriv := genX25519(t)
	aliceXPub, aliceXPriv := genX25519(t)

	text := "hi bob"
	env := &SecureMeshEnvelope{
		ClientMessageID: "m-2",
		RoomID:          "room",
		SenderID:        "fp-alice",
		SenderName:      "Alice",
		RecipientID:     "fp-bob",
		Type:            TypeText,
		Text:            &text,
		Timestamp:       1234.5,
		SprayCounter:    5,
		HopCount:        0,
		HopLimit:        10,
		RoutePath:       []string{},
		OriginDeviceID:  "fp-alice",
		NeedsForwarding: true,
		TTLSeconds:      86400,
		Nonce:           "nonce-b64",
		SenderPublicKey: base64.StdEncoding.EncodeToString(alicePub),
	}
	payload, err := SealWithKeys(env, aliceXPriv, aliceXPub, bobXPub, senderSign, alicePub)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	got, err := Open(payload, bobXPriv)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if got.ClientMessageID != "m-2" || got.Text == nil || *got.Text != "hi bob" {
		t.Fatalf("roundtrip mismatch: %+v", got)
	}
	if math.Abs(got.Timestamp-1234.5) > 1e-9 {
		t.Fatalf("timestamp drift: %v", got.Timestamp)
	}
}

// TestTamperRejected flips a ciphertext byte; Open must fail.
func TestTamperRejected(t *testing.T) {
	senderSign := ed25519.NewKeyFromSeed(aliceSeed)
	bobXPub, bobXPriv := genX25519(t)
	aliceXPub, aliceXPriv := genX25519(t)
	text := "secret"
	env := minimalEnv(&text)
	payload, err := SealWithKeys(env, aliceXPriv, aliceXPub, bobXPub, senderSign, alicePub)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	raw, _ := base64.StdEncoding.DecodeString(payload)
	var m map[string]json.RawMessage
	_ = json.Unmarshal(raw, &m)
	var ct []byte
	_ = json.Unmarshal(m["c"], &ct)
	ct[20] ^= 0xFF
	m["c"], _ = json.Marshal(base64.StdEncoding.EncodeToString(ct))
	raw, _ = json.Marshal(m)
	if _, err := Open(base64.StdEncoding.EncodeToString(raw), bobXPriv); err == nil {
		t.Fatal("tampered payload accepted")
	}
}

func minimalEnv(text *string) *SecureMeshEnvelope {
	return &SecureMeshEnvelope{
		ClientMessageID: "m", RoomID: "r", SenderID: "s", SenderName: "sn",
		RecipientID: "rid", Type: TypeText, Text: text, Timestamp: 1000,
		SprayCounter: 5, HopCount: 0, HopLimit: 10, RoutePath: []string{},
		OriginDeviceID: "s", NeedsForwarding: true, TTLSeconds: 86400,
		Nonce: "n", SenderPublicKey: "spk",
	}
}
