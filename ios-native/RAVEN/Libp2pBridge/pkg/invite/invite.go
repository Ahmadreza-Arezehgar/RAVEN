// Package invite implements the RAVEN one-string contact code ("invite"):
//
//	rvn1i1<bech32m(TLV)>
//
// A single copy-pasteable string that carries EVERYTHING needed to pin a
// contact — Ed25519 identity key, X25519 agreement key, issue time, display
// name and signature — instead of three separate blobs (address + pub_hex +
// fingerprint). The address, fingerprint and libp2p PeerID are all DERIVED
// locally from the embedded key, never trusted from the string.
//
// Design notes:
//   - Bech32m checksum (BIP-350, same family as RAVEN_ADDRESS_V1) catches
//     typos and forces a uniform lowercase, double-click-selectable token.
//   - The signature transcript is byte-for-byte `qr-v2:{fp}:{x}:{ed}:{ts}` —
//     the exact iPhone FriendQRPayload v2 transcript — so one signed payload
//     round-trips between the long raven:// card and this compact form with
//     zero new trust code.
//   - TLV layout (like Nostr NIP-19 nprofile) lets future fields ship without
//     breaking old parsers: unknown types are ignored on decode.
package invite

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"strings"
	"time"
)

// HRP is the human-readable prefix of every invite code.
const HRP = "rvn1i"

// TLV type tags (frozen; only append).
const (
	tlvIdentity  = 0x00 // 32B ed25519 public key
	tlvAgreement = 0x01 // 32B x25519 public key
	tlvIssuedAt  = 0x02 // 6B big-endian unix seconds
	tlvName      = 0x03 // utf-8 display name, <= maxNameLen bytes
	tlvSignature = 0x04 // 64B ed25519 over Transcript()
)

const (
	maxNameLen   = 32
	issuedAtLen  = 6
	maxFutureAge = -5 * time.Minute // clock skew tolerance
	maxCardAge   = 24 * time.Hour   // same window as the qr-v2 card
)

// Invite is a verified set of contact fields.
type Invite struct {
	IdentityPub  []byte // 32-byte ed25519 public key
	AgreementPub []byte // 32-byte x25519 public key
	IssuedAt     int64  // unix seconds the card was signed
	Name         string // optional display name (unsigned, like qr-v2)
	Signature    []byte // 64-byte ed25519 signature
}

func appendTLV(dst []byte, tag byte, val []byte) []byte {
	dst = append(dst, tag)
	dst = append(dst, byte(len(val)))
	return append(dst, val...)
}

// signedPayload serializes the TLVs covered by the signature (everything but
// tlvSignature), in canonical ascending tag order.
func (inv *Invite) signedPayload() []byte {
	var buf []byte
	buf = appendTLV(buf, tlvIdentity, inv.IdentityPub)
	buf = appendTLV(buf, tlvAgreement, inv.AgreementPub)
	ts := make([]byte, issuedAtLen)
	for i := 0; i < issuedAtLen; i++ {
		ts[issuedAtLen-1-i] = byte(uint64(inv.IssuedAt) >> (8 * i))
	}
	buf = appendTLV(buf, tlvIssuedAt, ts)
	if inv.Name != "" {
		name := []byte(inv.Name)
		if len(name) > maxNameLen {
			name = name[:maxNameLen]
		}
		buf = appendTLV(buf, tlvName, name)
	}
	return buf
}

// Transcript returns the qr-v2 signing string so invites and iPhone cards
// share ONE signature format.
func (inv *Invite) Transcript() []byte {
	fp := FingerprintOf(inv.IdentityPub)
	return []byte(fmt.Sprintf("qr-v2:%s:%s:%s:%d",
		fp,
		base64.StdEncoding.EncodeToString(inv.AgreementPub),
		base64.StdEncoding.EncodeToString(inv.IdentityPub),
		inv.IssuedAt))
}

// Encode renders the invite as a single rvn1i1… bech32m string (signature
// must already be set).
func (inv *Invite) Encode() (string, error) {
	if len(inv.IdentityPub) != ed25519.PublicKeySize {
		return "", fmt.Errorf("identity key must be 32 bytes")
	}
	if len(inv.AgreementPub) != 32 {
		return "", fmt.Errorf("agreement key must be 32 bytes")
	}
	if len(inv.Signature) != ed25519.SignatureSize {
		return "", fmt.Errorf("signature must be 64 bytes")
	}
	payload := append(inv.signedPayload(), appendTLV(nil, tlvSignature, inv.Signature)...)
	return bech32mEncode(HRP, payload)
}

// Build signs and encodes a fresh invite for the given keys. now stamps the
// 24-hour validity window that parse-side enforces.
func Build(priv ed25519.PrivateKey, identityPub, agreementPub []byte, name string, now time.Time) (*Invite, error) {
	if len(identityPub) != ed25519.PublicKeySize || len(agreementPub) != 32 {
		return nil, fmt.Errorf("bad key sizes")
	}
	inv := &Invite{
		IdentityPub:  append([]byte(nil), identityPub...),
		AgreementPub: append([]byte(nil), agreementPub...),
		IssuedAt:     now.Unix(),
		Name:         name,
	}
	inv.Signature = ed25519.Sign(priv, inv.Transcript())
	return inv, nil
}

// Decode parses a pasted invite code, verifies the signature against the
// derived fingerprint and enforces the 24h freshness window. Accepts the raw
// code or the https://…/#code wrapper form. Unknown TLV types are skipped
// (forward compatibility); duplicate required types are rejected.
func Decode(input string) (*Invite, error) {
	code := normalizeCode(input)
	if code == "" {
		return nil, fmt.Errorf("no %s… invite code found in input", HRP)
	}
	raw, err := bech32mDecode(code, HRP)
	if err != nil {
		return nil, err
	}
	inv := &Invite{}
	seen := map[byte]bool{}
	for i := 0; i < len(raw); {
		if i+2 > len(raw) {
			return nil, fmt.Errorf("truncated TLV")
		}
		tag, ln := raw[i], int(raw[i+1])
		i += 2
		if i+ln > len(raw) {
			return nil, fmt.Errorf("truncated TLV value")
		}
		val := raw[i : i+ln]
		i += ln
		switch tag {
		case tlvIdentity, tlvAgreement, tlvIssuedAt, tlvName, tlvSignature:
			if seen[tag] {
				return nil, fmt.Errorf("duplicate field %d", tag)
			}
			seen[tag] = true
		default:
			continue // unknown: ignore, per TLV policy
		}
		switch tag {
		case tlvIdentity:
			inv.IdentityPub = append([]byte(nil), val...)
		case tlvAgreement:
			inv.AgreementPub = append([]byte(nil), val...)
		case tlvIssuedAt:
			if ln != issuedAtLen {
				return nil, fmt.Errorf("issued-at must be %d bytes", issuedAtLen)
			}
			var v uint64
			for _, b := range val {
				v = v<<8 | uint64(b)
			}
			inv.IssuedAt = int64(v)
		case tlvName:
			if ln > maxNameLen {
				return nil, fmt.Errorf("name longer than %d bytes", maxNameLen)
			}
			inv.Name = strings.TrimSpace(string(val))
		case tlvSignature:
			inv.Signature = append([]byte(nil), val...)
		}
	}
	if len(inv.IdentityPub) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("missing/bad identity key")
	}
	if len(inv.AgreementPub) != 32 {
		return nil, fmt.Errorf("missing/bad agreement key")
	}
	if len(inv.Signature) != ed25519.SignatureSize {
		return nil, fmt.Errorf("missing/bad signature")
	}
	if !ed25519.Verify(ed25519.PublicKey(inv.IdentityPub), inv.Transcript(), inv.Signature) {
		return nil, fmt.Errorf("signature INVALID")
	}
	if err := inv.CheckFresh(time.Now()); err != nil {
		return nil, err
	}
	return inv, nil
}

// CheckFresh enforces the same ±window as qr-v2 cards.
func (inv *Invite) CheckFresh(now time.Time) error {
	age := now.Sub(time.Unix(inv.IssuedAt, 0))
	if age > maxCardAge || age < maxFutureAge {
		return fmt.Errorf("invite outside 24h validity window (issue it again)")
	}
	return nil
}

var wrapperPrefixes = []string{
	"https://raven-messager.com/i#",
	"http://raven-messager.com/i#",
}

// normalizeCode digs the rvn1i… code out of whatever people paste: bare code,
// quoted/bracketed, trailing punctuation, or the share-wrapper URL.
func normalizeCode(input string) string {
	s := strings.TrimSpace(input)
	for _, prefix := range wrapperPrefixes {
		if idx := strings.Index(s, prefix); idx >= 0 {
			s = s[idx+len(prefix):]
			break
		}
	}
	for _, tok := range strings.Fields(s) {
		t := strings.Trim(tok, "\"'`<>()[]{},.;:!?")
		if strings.HasPrefix(t, HRP+"1") {
			return t
		}
	}
	return ""
}

// FingerprintOf derives the XXXX-XXXX-XXXX display fingerprint from an
// ed25519 public key (DeviceIdentityService derivation). Empty on bad input.
func FingerprintOf(pub []byte) string {
	if len(pub) != ed25519.PublicKeySize {
		return ""
	}
	sum := sha256.Sum256(pub)
	b64 := base64.StdEncoding.EncodeToString(sum[:9])
	clean := strings.Map(func(r rune) rune {
		if r == '+' || r == '/' {
			return -1
		}
		return r
	}, b64)
	if len(clean) > 12 {
		clean = clean[:12]
	}
	var out []byte
	for i := 0; i < len(clean); i++ {
		if i > 0 && i%4 == 0 {
			out = append(out, '-')
		}
		out = append(out, clean[i])
	}
	return string(out)
}
