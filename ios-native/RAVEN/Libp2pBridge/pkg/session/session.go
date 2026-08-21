// Package session wires a terminal identity to the shared ravenbridge.Node
// (the exact same Go node gomobile binds into the iOS app), plus local
// receive plumbing: dedup, inbox persistence, and delivery callbacks.
package session

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	ravenbridge "github.com/raven/ravenbridge"
	"github.com/raven/ravenbridge/pkg/envelope"
	"github.com/raven/ravenbridge/pkg/identity"
)

// InboundMessage is a decrypted, verified incoming payload.
type InboundMessage struct {
	From        string  // sender fingerprint (envelope.sid)
	SenderName  string  // envelope.sn
	Text        string  // envelope.txt (may hold JSON for pk kinds)
	PayloadKind string  // "" = chat, "friend_request", ...
	Type        int     // wire type int
	ID          string  // clientMessageId (dedup key)
	Timestamp   float64 // seconds
	Raw         *envelope.SecureMeshEnvelope
	ReceivedAt  time.Time
}

// Handler receives inbound messages.
type Handler func(InboundMessage)

// StatusHandler receives connect/disconnect events.
type StatusHandler func(connected bool, peerID string)

// delegate adapts callbacks to the gomobile-style Delegate interface.
type delegate struct {
	ses *Session
}

func (d *delegate) OnEnvelope(envelopeB64 string, idempotencyKey string) {
	d.ses.onEnvelope(envelopeB64, idempotencyKey)
}
func (d *delegate) OnStatus(connected bool, peerID string) {
	d.ses.dispatchStatus(connected, peerID)
}
func (d *delegate) OnInviteRedeemed(token string, peerCardJSON string) {}

// Session is a running terminal endpoint.
type Session struct {
	ID      *identity.Identity
	Node    *ravenbridge.Node
	PeerID  string
	DataDir string

	mu            sync.Mutex
	seen          map[string]bool // idempotency keys seen this run
	inboxPath     string
	msgHandler    Handler
	statusHandler StatusHandler
}

// Start boots the libp2p node from identity + bootstrap multiaddrs CSV.
func Start(id *identity.Identity, dataDir, bootstrapCSV string) (*Session, error) {
	s := &Session{
		ID:        id,
		DataDir:   dataDir,
		seen:      map[string]bool{},
		inboxPath: filepath.Join(dataDir, "inbox.jsonl"),
	}
	node, err := ravenbridge.NewNode(id.Seed, &delegate{ses: s})
	if err != nil {
		return nil, fmt.Errorf("new node: %w", err)
	}
	if err := node.Start(bootstrapCSV); err != nil {
		return nil, fmt.Errorf("start node: %w", err)
	}
	s.Node = node
	s.PeerID = node.PeerID()
	return s, nil
}

// SetHandlers registers callbacks (call before Start for no missed events).
func (s *Session) SetHandlers(onMessage Handler, onStatus StatusHandler) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.msgHandler, s.statusHandler = onMessage, onStatus
}

func (s *Session) dispatchStatus(connected bool, peerID string) {
	if s.statusHandler != nil {
		go s.statusHandler(connected, peerID)
	}
}

// onEnvelope decrypts + verifies an inbound bridge payload and dispatches it.
// Envelopes addressed to someone else (transit) are dropped silently — this
// endpoint is a leaf, not a router.
func (s *Session) onEnvelope(payloadB64, idemKey string) {
	s.mu.Lock()
	if s.seen[idemKey] {
		s.mu.Unlock()
		return
	}
	s.seen[idemKey] = true
	s.mu.Unlock()

	env, err := envelope.Open(payloadB64, s.ID.X25519Priv)
	if err != nil {
		log.Printf("[raven] dropping undecryptable/invalid payload (%v)", err)
		return
	}
	msg := InboundMessage{
		From:        env.SenderID,
		SenderName:  env.SenderName,
		PayloadKind: env.PayloadKind,
		Type:        env.Type,
		ID:          env.ClientMessageID,
		Timestamp:   env.Timestamp,
		Raw:         env,
		ReceivedAt:  time.Now(),
	}
	if env.Text != nil {
		msg.Text = *env.Text
	}
	s.appendInbox(msg)
	if s.msgHandler != nil {
		s.msgHandler(msg)
	}
}

func (s *Session) appendInbox(msg InboundMessage) {
	f, err := os.OpenFile(s.inboxPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "%s\n", inboxLine(msg))
}

type inboxJSON struct {
	From       string  `json:"from"`
	Name       string  `json:"name"`
	Text       string  `json:"text"`
	Kind       string  `json:"kind,omitempty"`
	ID         string  `json:"id"`
	Ts         float64 `json:"ts"`
	ReceivedAt int64   `json:"received_at"`
}

func inboxLine(m InboundMessage) string {
	b, _ := json.Marshal(inboxJSON{
		From: m.From, Name: m.SenderName, Text: m.Text,
		Kind: m.PayloadKind, ID: m.ID, Ts: m.Timestamp,
		ReceivedAt: m.ReceivedAt.Unix(),
	})
	return string(b)
}

// ContactInfo carries the pinned remote keys needed to seal + address a send.
type ContactInfo struct {
	Petname      string // local petname (unused on wire)
	Fingerprint  string // remote display id -> envelope.rid
	PeerID       string // libp2p PeerID
	AgreementKey []byte // remote X25519 agreement pub
}

// SealText builds and seals a 1:1 text payload for a contact without sending.
// Returns the bridge payload b64 + idempotency key.
func (s *Session) SealText(c ContactInfo, senderName, text string) (string, string, error) {
	now := time.Now()
	env := &envelope.SecureMeshEnvelope{
		ClientMessageID: newUUID(),
		RoomID:          RoomID(s.ID.Fingerprint(), c.Fingerprint),
		SenderID:        s.ID.Fingerprint(),
		SenderName:      senderName,
		RecipientID:     c.Fingerprint,
		Type:            envelope.TypeText,
		Text:            ptr(text),
		Timestamp:       float64(now.UnixMilli()) / 1000.0,
		SprayCounter:    5,
		HopCount:        0,
		HopLimit:        10,
		RoutePath:       []string{},
		OriginDeviceID:  s.ID.Fingerprint(),
		NeedsForwarding: true,
		TTLSeconds:      86400,
		Nonce:           randomB64(16),
		SenderPublicKey: b64(s.ID.PublicKey()),
	}
	payload, err := envelope.SealWithKeys(env, s.ID.X25519Priv, s.ID.X25519Pub, c.AgreementKey, s.ID.Seed, s.ID.PublicKey())
	if err != nil {
		return "", "", fmt.Errorf("seal: %w", err)
	}
	return payload, env.ClientMessageID, nil
}

// SendText seals via SealText and sends over the bridge to the contact's
// libp2p PeerID.
func (s *Session) SendText(c ContactInfo, senderName, text string) error {
	payload, idem, err := s.SealText(c, senderName, text)
	if err != nil {
		return err
	}
	return s.Node.Send(c.PeerID, payload, idem)
}

// Ingest feeds an externally retrieved opaque payload through the same
// decrypt/verify/dedup pipeline as bridge inbound (used by mailbox fetch).
func (s *Session) Ingest(payloadB64, idemKey string) { s.onEnvelope(payloadB64, idemKey) }
