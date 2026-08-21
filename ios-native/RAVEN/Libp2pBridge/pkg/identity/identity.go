// Package identity implements RAVEN's device identity for terminal clients,
// byte-compatible with the iOS app's DeviceIdentityService.
//
// One Ed25519 key drives everything:
//   - libp2p PeerID (base58btc identity multihash of the protobuf-marshaled
//     public key) — identical to what the iOS gomobile bridge derives.
//   - display fingerprint: SHA256(pub)[0..9] -> std base64 -> strip "+/"
//     -> first 12 chars -> dash every 4 ("XXXX-XXXX-XXXX").
//   - Ed25519 signatures over mesh envelope signingData().
//
// A separate X25519 agreement key (same split as iOS) drives static-static
// ECDH for AES-256-GCM payload encryption.
package identity

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/crypto/curve25519"
)

// Identity is a terminal device identity.
type Identity struct {
	Seed         ed25519.PrivateKey // 64-byte std key (seed+pub)
	X25519Priv   []byte             // 32-byte agreement private key
	X25519Pub    []byte             // 32-byte agreement public key
	DataDir      string
	bootstrapCSV string
}

// Generate creates a fresh identity (not persisted).
func Generate() (*Identity, error) {
	_, edPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("ed25519 keygen: %w", err)
	}
	xPriv := make([]byte, curve25519.ScalarSize)
	if _, err := rand.Read(xPriv); err != nil {
		return nil, fmt.Errorf("x25519 keygen: %w", err)
	}
	xPub, err := curve25519.X25519(xPriv, curve25519.Basepoint)
	if err != nil {
		return nil, fmt.Errorf("x25519 pubkey: %w", err)
	}
	return &Identity{Seed: edPriv, X25519Priv: xPriv, X25519Pub: xPub}, nil
}

// Fingerprint derives the display fingerprint from an Ed25519 public key,
// mirroring DeviceIdentityService.deriveFingerprint exactly.
func Fingerprint(publicKey []byte) (string, error) {
	if len(publicKey) != ed25519.PublicKeySize {
		return "", fmt.Errorf("public key must be %d bytes, got %d", ed25519.PublicKeySize, len(publicKey))
	}
	sum := sha256.Sum256(publicKey)
	b64 := base64.StdEncoding.EncodeToString(sum[:9])
	clean := stringsMap(b64, '+', '/')
	if len(clean) > 12 {
		clean = clean[:12]
	}
	out := make([]byte, 0, len(clean)+2)
	for i, c := range []byte(clean) {
		if i > 0 && i%4 == 0 {
			out = append(out, '-')
		}
		out = append(out, c)
	}
	return string(out), nil
}

func stringsMap(s string, remove ...byte) string {
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		skip := false
		for _, r := range remove {
			if s[i] == r {
				skip = true
				break
			}
		}
		if !skip {
			out = append(out, s[i])
		}
	}
	return string(out)
}

// Fingerprint returns this identity's display fingerprint.
func (id *Identity) Fingerprint() string {
	fp, err := Fingerprint(id.Seed.Public().(ed25519.PublicKey))
	if err != nil {
		return ""
	}
	return fp
}

// PublicKey returns the raw Ed25519 public key.
func (id *Identity) PublicKey() ed25519.PublicKey {
	return id.Seed.Public().(ed25519.PublicKey)
}

// Sign signs data with the Ed25519 key.
func (id *Identity) Sign(data []byte) []byte {
	return ed25519.Sign(id.Seed, data)
}

// Save persists the identity seeds to <dir>/identity.json (0600).
func (id *Identity) Save(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	file := filepath.Join(dir, "identity.json")
	tmp := file + ".tmp"
	content := fmt.Sprintf(`{
  "ed25519_seed_hex": %q,
  "x25519_priv_hex": %q,
  "x25519_pub_hex": %q
}`, hex.EncodeToString(id.Seed.Seed()), hex.EncodeToString(id.X25519Priv), hex.EncodeToString(id.X25519Pub))
	if err := os.WriteFile(tmp, []byte(content), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, file)
}

// Load reads an identity from <dir>/identity.json.
func Load(dir string) (*Identity, error) {
	raw, err := os.ReadFile(filepath.Join(dir, "identity.json"))
	if err != nil {
		return nil, err
	}
	var m struct {
		Ed25519SeedHex string `json:"ed25519_seed_hex"`
		X25519PrivHex  string `json:"x25519_priv_hex"`
		X25519PubHex   string `json:"x25519_pub_hex"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("parse identity.json: %w", err)
	}
	seed, err := hex.DecodeString(m.Ed25519SeedHex)
	if err != nil || len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("bad ed25519 seed")
	}
	xPriv, err := hex.DecodeString(m.X25519PrivHex)
	if err != nil || len(xPriv) != curve25519.ScalarSize {
		return nil, fmt.Errorf("bad x25519 private key")
	}
	xPub, err := curve25519.X25519(xPriv, curve25519.Basepoint)
	if err != nil {
		return nil, fmt.Errorf("bad x25519 private key: %w", err)
	}
	return &Identity{
		Seed:       ed25519.NewKeyFromSeed(seed),
		X25519Priv: xPriv,
		X25519Pub:  xPub,
		DataDir:    dir,
	}, nil
}

// Ensure loads or creates+saves an identity in dir.
func Ensure(dir string) (*Identity, bool, error) {
	if id, err := Load(dir); err == nil {
		id.DataDir = dir
		return id, false, nil
	}
	id, err := Generate()
	if err != nil {
		return nil, false, err
	}
	if err := id.Save(dir); err != nil {
		return nil, false, err
	}
	id.DataDir = dir
	return id, true, nil
}
