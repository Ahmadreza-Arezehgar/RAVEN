// Package envelope implements RAVEN's legacy mesh payload, byte-compatible
// with the iOS app's SecureMeshEnvelope / EncryptedMeshPayload (the format
// actually carried over the /raven/bridge/1.0.0 libp2p stream today).
//
// Crypto contract (must match MeshCryptoService.swift + DeviceIdentityService.swift):
//
//	inner   : JSON(SecureMeshEnvelope) with short CodingKeys
//	sign     : Ed25519 over pipe-delimited signingData()  -> payload.s/ssk
//	encrypt  : AES-256-GCM(key=ECDH(ourX25519Priv, peerX25519Pub) -> HKDF-SHA256,
//	               salt="RAVEN-MESH", info="", 32B), combined = nonce||ct||tag
//	payload  : JSON {c,n,spk,v,s,ssk} -> base64 -> bridge frame
package envelope

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
)

// Message type wire ints (MeshEnvelope.swift MessageType.index).
const (
	TypeText   = 0
	TypeSystem = 6
)

// SecureMeshEnvelope mirrors SecureMeshEnvelope.swift including short keys.
// Field order here is irrelevant to receivers (decoded as a map/struct), but
// signingData() below must reproduce Swift's exact concatenation.
type SecureMeshEnvelope struct {
	ClientMessageID string   `json:"id"`
	RoomID          string   `json:"rm"`
	SenderID        string   `json:"sid"`
	SenderName      string   `json:"sn"`
	RecipientID     string   `json:"rid"`
	Type            int      `json:"t"`
	Text            *string  `json:"txt"`
	Timestamp       float64  `json:"ts"` // seconds, fractional; signed as ms
	SprayCounter    int      `json:"sc"`
	HopCount        int      `json:"hc"`
	HopLimit        int      `json:"hl"`
	RoutePath       []string `json:"rp"`
	OriginDeviceID  string   `json:"od"`
	NeedsForwarding bool     `json:"nf"`
	TTLSeconds      int      `json:"ttl"`
	Nonce           string   `json:"n"`
	SenderPublicKey string   `json:"spk"` // Ed25519 identity pub, b64

	MediaURL       *string `json:"mu,omitempty"`
	ThumbnailURL   *string `json:"tu,omitempty"`
	FileName       *string `json:"fn,omitempty"`
	MimeType       *string `json:"mt,omitempty"`
	FileSize       *int    `json:"fs,omitempty"`
	AudioDuration  *int    `json:"ad,omitempty"`
	MediaSealed    *string `json:"msl,omitempty"`
	MediaCipher    *string `json:"mc,omitempty"`
	ReplyToMsgID   *string `json:"rtid,omitempty"`
	ReplyToPreview *string `json:"rttp,omitempty"`
	ReplyToName    *string `json:"rtsn,omitempty"`
	IsBridged      *bool   `json:"ib,omitempty"`
	IsGroup        *bool   `json:"ig,omitempty"`
	GroupKeyVer    *int    `json:"gkv,omitempty"`
	PayloadKind    string  `json:"pk,omitempty"`
}

// SigningData reproduces SecureMeshEnvelope.signingData() for the v1 form
// (no sealed-sender v2). Optional trailing segments appended only when set.
func (e *SecureMeshEnvelope) SigningData() []byte {
	tsMs := strconv.FormatInt(int64(e.Timestamp*1000+0.5), 10)
	seg := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	num := func(p *int) string {
		if p == nil {
			return ""
		}
		return strconv.Itoa(*p)
	}
	parts := []string{
		e.ClientMessageID,
		e.RoomID,
		e.SenderID,
		e.SenderName,
		e.RecipientID,
		strconv.Itoa(e.Type),
		e.Nonce,
		e.SenderPublicKey,
		tsMs,
		e.OriginDeviceID,
		seg(e.Text),
		seg(e.MediaURL),
		seg(e.ThumbnailURL),
		seg(e.FileName),
		seg(e.MimeType),
		num(e.FileSize),
		num(e.AudioDuration),
		seg(e.MediaSealed),
		seg(e.ReplyToMsgID),
		seg(e.ReplyToPreview),
		seg(e.ReplyToName),
	}
	out := strings.Join(parts, "|")
	if e.GroupKeyVer != nil {
		out += "|gkv:" + strconv.Itoa(*e.GroupKeyVer)
	}
	if e.PayloadKind != "" {
		out += "|pk:" + e.PayloadKind
	}
	return []byte(out)
}

// EncryptedMeshPayload mirrors EncryptedMeshPayload.swift.
type EncryptedMeshPayload struct {
	Ciphertext      string `json:"c"`   // b64 of nonce||ct||tag
	Nonce           string `json:"n"`   // b64 of the 12-byte nonce (duplicated)
	SenderPublicKey string `json:"spk"` // our X25519 agreement pub, b64
	Version         int    `json:"v"`   // 1
	Signature       string `json:"s"`   // b64 Ed25519 over SigningData()
	SignerPublicKey string `json:"ssk"` // b64 Ed25519 identity pub
}

// DeriveSharedKey computes HKDF-SHA256(X25519(priv, peerPub), salt="RAVEN-MESH",
// info="", 32B) — identical to DeviceIdentityService.deriveSharedSecret.
func DeriveSharedKey(x25519Priv, peerX25519Pub []byte) ([]byte, error) {
	shared, err := curve25519.X25519(x25519Priv, peerX25519Pub)
	if err != nil {
		return nil, fmt.Errorf("x25519: %w", err)
	}
	r := hkdf.New(sha256.New, shared, []byte("RAVEN-MESH"), nil)
	key := make([]byte, 32)
	if _, err := readFull(r, key); err != nil {
		return nil, fmt.Errorf("hkdf: %w", err)
	}
	return key, nil
}

func readFull(r interface{ Read([]byte) (int, error) }, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := r.Read(buf[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

func sealAESGCM(key, plaintext []byte) (combined, nonceB64 []byte, err error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := crand.Read(nonce); err != nil {
		return nil, nil, err
	}
	combined = gcm.Seal(nonce, nonce, plaintext, nil) // prefix nonce = CryptoKit .combined
	return combined, nonce, nil
}

func openAESGCM(key, combined []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if len(combined) < gcm.NonceSize()+gcm.Overhead() {
		return nil, fmt.Errorf("ciphertext too short")
	}
	return gcm.Open(nil, combined[:gcm.NonceSize()], combined[gcm.NonceSize():], nil)
}

// SealWithKeys signs then encrypts an envelope exactly like DeliveryJobRunner
// + MeshCryptoService.encryptEnvelope: AES-256-GCM over the JSON of the
// envelope only; Ed25519 signature rides outside the AEAD. xPriv/xPub are OUR
// X25519 agreement keys (xPub rides in spk), peerXPub is the recipient's.
func SealWithKeys(env *SecureMeshEnvelope, xPriv, xPub, peerXPub []byte,
	signKey ed25519.PrivateKey, signerPub ed25519.PublicKey) (string, error) {

	key, err := DeriveSharedKey(xPriv, peerXPub)
	if err != nil {
		return "", err
	}
	plaintext, err := json.Marshal(env)
	if err != nil {
		return "", err
	}
	combined, _, err := sealAESGCM(key, plaintext)
	if err != nil {
		return "", fmt.Errorf("aes-gcm: %w", err)
	}
	sig := ed25519.Sign(signKey, env.SigningData())
	payload := EncryptedMeshPayload{
		Ciphertext:      base64.StdEncoding.EncodeToString(combined),
		Nonce:           base64.StdEncoding.EncodeToString(combined[:12]),
		SenderPublicKey: base64.StdEncoding.EncodeToString(xPub),
		Version:         1,
		Signature:       base64.StdEncoding.EncodeToString(sig),
		SignerPublicKey: base64.StdEncoding.EncodeToString(signerPub),
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(raw), nil
}

// Open decodes a bridge payload b64, decrypts and verifies it against the
// sender's Ed25519 identity key. Returns the inner envelope.
func Open(payloadB64 string, xPriv []byte) (*SecureMeshEnvelope, error) {
	raw, err := base64.StdEncoding.DecodeString(payloadB64)
	if err != nil {
		return nil, fmt.Errorf("payload b64: %w", err)
	}
	var payload EncryptedMeshPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, fmt.Errorf("payload json: %w", err)
	}
	if payload.Version != 1 {
		return nil, fmt.Errorf("unsupported payload version %d", payload.Version)
	}
	senderXPub, err := base64.StdEncoding.DecodeString(payload.SenderPublicKey)
	if err != nil || len(senderXPub) != curve25519.PointSize {
		return nil, fmt.Errorf("bad senderPublicKey")
	}
	key, err := DeriveSharedKey(xPriv, senderXPub)
	if err != nil {
		return nil, err
	}
	combined, err := base64.StdEncoding.DecodeString(payload.Ciphertext)
	if err != nil {
		return nil, fmt.Errorf("ciphertext b64: %w", err)
	}
	plaintext, err := openAESGCM(key, combined)
	if err != nil {
		return nil, fmt.Errorf("decrypt: %w", err)
	}
	var env SecureMeshEnvelope
	if err := json.Unmarshal(plaintext, &env); err != nil {
		return nil, fmt.Errorf("envelope json: %w", err)
	}
	// Verify signature when present.
	if payload.Signature != "" && payload.SignerPublicKey != "" {
		sig, err := base64.StdEncoding.DecodeString(payload.Signature)
		if err != nil || len(sig) != ed25519.SignatureSize {
			return nil, fmt.Errorf("bad signature encoding")
		}
		pub, err := base64.StdEncoding.DecodeString(payload.SignerPublicKey)
		if err != nil || len(pub) != ed25519.PublicKeySize {
			return nil, fmt.Errorf("bad signerPublicKey")
		}
		if !ed25519.Verify(ed25519.PublicKey(pub), env.SigningData(), sig) {
			return nil, fmt.Errorf("signature verification FAILED")
		}
	}
	return &env, nil
}
