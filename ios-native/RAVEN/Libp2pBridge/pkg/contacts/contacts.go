// Package contacts stores RAVEN terminal contacts (petname -> pinned keys).
//
// A contact pins BOTH of the peer's public keys:
//   - Ed25519 identity/signing key (fingerprint + PeerID derive from it)
//   - X25519 agreement key (static-static ECDH for payload encryption)
//
// This mirrors PeerKeyDirectory on iOS, where both keys get pinned when a QR
// contact card is scanned. The terminal equivalent is exchanging card JSON.
package contacts

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"golang.org/x/crypto/curve25519"
)

// Contact is one pinned remote identity.
type Contact struct {
	Petname      string `json:"petname"`
	Fingerprint  string `json:"fingerprint"`   // XXXX-XXXX-XXXX display id
	PeerID       string `json:"peer_id"`       // libp2p PeerID (12D3Koo...)
	IdentityB64  string `json:"identity_b64"`  // Ed25519 pub, b64
	AgreementB64 string `json:"agreement_b64"` // X25519 pub, b64
	AddedAt      int64  `json:"added_at"`
}

// Store is a JSON-file-backed contact list.
type Store struct {
	mu   sync.Mutex
	path string
	list []Contact
}

// Open loads (or creates) the store at dir/contacts.json.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	s := &Store{path: filepath.Join(dir, "contacts.json")}
	raw, err := os.ReadFile(s.path)
	if err == nil && len(raw) > 0 {
		if err := json.Unmarshal(raw, &s.list); err != nil {
			return nil, fmt.Errorf("parse %s: %w", s.path, err)
		}
	}
	return s, nil
}

func (s *Store) flushLocked() error {
	raw, err := json.MarshalIndent(s.list, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, raw, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

// Upsert adds or updates a contact by fingerprint.
func (s *Store) Upsert(c Contact) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i := range s.list {
		if s.list[i].Fingerprint == c.Fingerprint {
			s.list[i] = c
			return s.flushLocked()
		}
	}
	s.list = append(s.list, c)
	return s.flushLocked()
}

// All returns a copy of all contacts.
func (s *Store) All() []Contact {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Contact, len(s.list))
	copy(out, s.list)
	return out
}

// Resolve finds a contact by petname (case-insensitive), fingerprint, or
// PeerID prefix.
func (s *Store) Resolve(q string) (*Contact, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	q = strings.ToLower(strings.TrimPrefix(q, "@"))
	for i := range s.list {
		if strings.ToLower(s.list[i].Petname) == q || s.list[i].Fingerprint == q {
			c := s.list[i]
			return &c, nil
		}
	}
	for i := range s.list {
		if strings.HasPrefix(strings.ToLower(s.list[i].PeerID), q) && len(q) >= 8 {
			c := s.list[i]
			return &c, nil
		}
	}
	return nil, fmt.Errorf("no contact matching %q", q)
}

// IdentityKey returns the raw Ed25519 public key.
func (c *Contact) IdentityKey() (ed25519.PublicKey, error) {
	raw, err := base64.StdEncoding.DecodeString(c.IdentityB64)
	if err != nil || len(raw) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("bad identity key for %s", c.Petname)
	}
	return ed25519.PublicKey(raw), nil
}

// AgreementKey returns the raw X25519 public key.
func (c *Contact) AgreementKey() ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(c.AgreementB64)
	if err != nil || len(raw) != curve25519.PointSize {
		return nil, fmt.Errorf("bad agreement key for %s", c.Petname)
	}
	return raw, nil
}
