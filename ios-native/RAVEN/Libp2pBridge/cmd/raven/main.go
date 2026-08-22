// Command raven is RAVEN's serverless terminal client for macOS, Linux and
// Windows: identity management, contact pairing via iPhone-compatible QR /
// card exchange, E2E internet messaging over libp2p (DHT + relay +
// hole-punching), a community relay/bootstrap mode, and offline
// store-and-forward via a mailbox node.
//
// It speaks the exact wire protocol of the iOS app (/raven/bridge/1.0.0 with
// the legacy EncryptedMeshPayload) because it reuses the same Go node the
// iPhone app embeds via gomobile.
package main

import (
	"bufio"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	qrcode "github.com/skip2/go-qrcode"

	"github.com/raven/ravenbridge/pkg/contacts"
	inv "github.com/raven/ravenbridge/pkg/invite"
	mbox "github.com/raven/ravenbridge/pkg/mailbox"
	"github.com/raven/ravenbridge/pkg/session"
)

const banner = `
  ___  _    ___ _   _____ _____
 | _ \| |  |_ _| | |_   _|_   _|
 |   /| |__ | || |__ | |   | |
 |_|_\|____|___|____|___|  |_|
 serverless encrypted messaging — no central server
`

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}
	dir := dataDir()
	if v := flagValue(args, "--data-dir"); v != "" {
		dir = v
	}
	cmd, rest := splitCommand(args)
	var err error
	switch cmd {
	case "init":
		err = cmdInit(dir)
	case "whoami":
		err = cmdWhoami(dir)
	case "invite":
		err = cmdInvite(rest)
	case "words":
		err = cmdWords(dir, rest)
	case "add":
		err = cmdAdd(dir, rest)
	case "list":
		err = cmdList(dir)
	case "send":
		err = cmdSend(dir, rest)
	case "chat":
		err = cmdChat(dir, rest)
	case "listen":
		err = cmdListen(dir)
	case "relay":
		err = cmdRelay()
	case "mailbox":
		err = cmdMailbox()
	case "fetch":
		err = cmdFetch(dir)
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "raven %s: %v\n", cmd, err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Print(`raven — RAVEN serverless terminal client

usage: raven [--data-dir DIR] <command>

  init                 create identity in DIR (~/.raven by default)
  whoami               show identity; --qr renders an iPhone-scannable QR
  invite               ONE-LINE contact code (rvn1i…) — keys+signature inside;
                       --qr renders it; this single string replaces
                       address + pub_hex + fingerprint copy-paste
  words [CODE]         four-word key face ("copper raven …") for verifying a
                       contact out loud — yours, or of a pasted code
  add --petname NAME   pin a contact from pasted rvn1i code / raven:// card / JSON
  list                 list contacts
  send WHO TEXT        one-shot E2E message over the internet bridge
  chat WHO             interactive chat (sends + receives)
  listen               receive-only daemon (logs to inbox.jsonl)
  fetch                pull queued messages from mailbox nodes and exit
  relay                run a community relay + DHT bootstrap node
  mailbox              run a store-and-forward mailbox node

environment:
  RAVEN_DATA_DIR       default data dir (~/.raven)
  RAVEN_BOOTSTRAP      comma-separated libp2p multiaddrs of relay nodes
                       (required for internet sends/receives)
  RAVEN_MAILBOX        comma-separated mailbox multiaddrs for offline delivery
  RAVEN_NAME           display name used in envelopes
`)
}

// splitCommand finds the first non-flag token as the subcommand and returns
// the remaining args, so `raven --data-dir X invite` and
// `raven invite --data-dir X` both work.
func splitCommand(args []string) (string, []string) {
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--data-dir":
			i++
		case strings.HasPrefix(args[i], "-"):
		default:
			rest := make([]string, 0, len(args)-1)
			rest = append(rest, args[:i]...)
			rest = append(rest, args[i+1:]...)
			return args[i], rest
		}
	}
	return "", args
}

func dataDir() string {
	if v := os.Getenv("RAVEN_DATA_DIR"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".raven")
}

func flagValue(args []string, name string) string {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

// ---- config ----

type config struct {
	Name      string `json:"name,omitempty"`
	Bootstrap string `json:"bootstrap,omitempty"`
	Mailbox   string `json:"mailbox,omitempty"`
}

func loadConfig(dir string) *config {
	c := &config{}
	raw, err := os.ReadFile(filepath.Join(dir, "config.json"))
	if err == nil {
		_ = json.Unmarshal(raw, c)
	}
	if v := os.Getenv("RAVEN_BOOTSTRAP"); v != "" {
		c.Bootstrap = v
	}
	if v := os.Getenv("RAVEN_MAILBOX"); v != "" {
		c.Mailbox = v
	}
	if v := os.Getenv("RAVEN_NAME"); v != "" {
		c.Name = v
	}
	return c
}

// ---- identity ----

func mustIdentity(dir string) (*identityBundle, error) {
	id, fresh, err := idEnsure(dir)
	if err != nil {
		return nil, err
	}
	_ = fresh
	return &identityBundle{id: id}, nil
}

type identityBundle struct{ id idType }

// ---- init / whoami ----

func cmdInit(dir string) error {
	id, fresh, err := idEnsure(dir)
	if err != nil {
		return err
	}
	if fresh {
		fmt.Println("new identity created")
	} else {
		fmt.Println("existing identity loaded")
	}
	printIdentity(id, dir)
	return nil
}

func printIdentity(id idType, dir string) {
	fmt.Printf("  fingerprint : %s\n", id.Fingerprint())
	fmt.Printf("  peer id     : %s\n", peerIDOf(id))
	fmt.Printf("  ed25519 pub : %s\n", b64(id.PublicKey()))
	fmt.Printf("  x25519 pub  : %s\n", b64(id.X25519Pub))
	fmt.Printf("  data dir    : %s\n", dir)
}

func cmdWhoami(dir string) error {
	id, _, err := idEnsure(dir)
	if err != nil {
		return err
	}
	cfg := loadConfig(dir)
	printIdentity(id, dir)

	code, err := inviteCode(id, cfg.Name)
	if err != nil {
		return err
	}
	fmt.Printf("\ninvite code — ONE line, share this (keys + signature inside):\n  %s\n", code)
	fmt.Printf("words: %s\n", inv.Words(id.PublicKey()))

	card := buildCard(id, cfg.Name)
	b64url := cardURIBody(card)
	uri := "raven://friend?v=2&d=" + b64url
	fmt.Printf("\ncard uri (legacy, iPhone-compatible):\n  %s\n", uri)
	if hasFlag(os.Args[1:], "--qr") {
		qr, err := qrcode.New(uri, qrcode.Low)
		if err == nil {
			fmt.Println("\nscan with RAVEN iOS → Discover → Scan QR:")
			fmt.Println(qr.ToSmallString(false))
		}
	}
	return nil
}

// inviteCode builds the compact one-string contact code for this identity.
func inviteCode(id idType, name string) (string, error) {
	ivc, err := inv.Build(id.Seed, id.PublicKey(), id.X25519Pub, name, time.Now())
	if err != nil {
		return "", err
	}
	return ivc.Encode()
}

// cmdInvite prints just the one-line rvn1i… code (pipe-friendly).
func cmdInvite(args []string) error {
	dir := dataDir()
	if v := flagValue(args, "--data-dir"); v != "" {
		dir = v
	}
	id, _, err := idEnsure(dir)
	if err != nil {
		return err
	}
	cfg := loadConfig(dir)
	code, err := inviteCode(id, cfg.Name)
	if err != nil {
		return err
	}
	fmt.Println(code)
	if hasFlag(args, "--qr") {
		qr, err := qrcode.New(code, qrcode.Low)
		if err == nil {
			fmt.Println("\nscan with another raven terminal (`raven add`):")
			fmt.Println(qr.ToSmallString(false))
		}
	}
	return nil
}

// cmdWords prints the speakable four-word key face — yours by default, or of
// a pasted invite code for out-loud comparison ("read me your words").
func cmdWords(dir string, args []string) error {
	id, _, err := idEnsure(dir)
	if err != nil {
		return err
	}
	var targetPub []byte
	label := "you"
	for _, a := range args {
		if strings.HasPrefix(strings.TrimSpace(a), inv.HRP+"1") {
			parsed, err := inv.Decode(a)
			if err != nil {
				return fmt.Errorf("bad invite code: %w", err)
			}
			targetPub = parsed.IdentityPub
			label = parsed.Name
			if label == "" {
				label = fingerprintOf(parsed.IdentityPub)
			}
		}
	}
	if targetPub == nil {
		targetPub = id.PublicKey()
	}
	fmt.Printf("%s: %s\nfingerprint: %s\n", label, inv.Words(targetPub), fingerprintOf(targetPub))
	return nil
}

func hasFlag(args []string, f string) bool {
	for _, a := range args {
		if a == f {
			return true
		}
	}
	return false
}

// ---- contact cards (iPhone QR v2 compatible) ----

type cardJSON struct {
	UserID          string `json:"u"`
	Name            string `json:"n,omitempty"`
	Handle          string `json:"h,omitempty"`
	AgreementPubB64 string `json:"p"`
	IdentityPubB64  string `json:"i"`
	FingerprintSafe string `json:"f,omitempty"`
	IssuedAt        int64  `json:"t"`
	SignatureB64    string `json:"s"`
}

func buildCard(id idType, name string) cardJSON {
	ts := time.Now().Unix()
	transcript := fmt.Sprintf("qr-v2:%s:%s:%s:%d",
		id.Fingerprint(), b64(id.X25519Pub), b64(id.PublicKey()), ts)
	sig := ed25519.Sign(id.Seed, []byte(transcript))
	fp := id.Fingerprint()
	return cardJSON{
		UserID:          fp,
		Name:            name,
		AgreementPubB64: b64(id.X25519Pub),
		IdentityPubB64:  b64(id.PublicKey()),
		FingerprintSafe: fp,
		IssuedAt:        ts,
		SignatureB64:    b64(sig),
	}
}

func cardURIBody(c cardJSON) string {
	raw, _ := json.Marshal(c)
	s := base64.StdEncoding.EncodeToString(raw)
	s = strings.ReplaceAll(s, "+", "-")
	s = strings.ReplaceAll(s, "/", "_")
	return strings.TrimRight(s, "=")
}

// parseCard accepts a raven:// URI or bare card JSON, verifies signature and
// age, and derives the fingerprint locally (never trusting claimed ids).
func parseCard(input string) (*cardJSON, error) {
	input = strings.TrimSpace(input)
	var raw []byte
	if strings.HasPrefix(input, "raven://friend?v=2&d=") {
		b64u := strings.TrimPrefix(input, "raven://friend?v=2&d=")
		b64u = strings.ReplaceAll(b64u, "-", "+")
		b64u = strings.ReplaceAll(b64u, "_", "/")
		if pad := len(b64u) % 4; pad != 0 {
			b64u += strings.Repeat("=", 4-pad)
		}
		var err error
		raw, err = base64.StdEncoding.DecodeString(b64u)
		if err != nil {
			return nil, fmt.Errorf("bad card base64: %w", err)
		}
	} else if strings.HasPrefix(input, "{") {
		raw = []byte(input)
	} else {
		return nil, fmt.Errorf("not a raven:// card or JSON blob")
	}
	var c cardJSON
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("bad card json: %w", err)
	}
	idPub, err := base64.StdEncoding.DecodeString(c.IdentityPubB64)
	if err != nil || len(idPub) != ed25519.PublicKeySize {
		return nil, fmt.Errorf("bad identity key")
	}
	xPub, err := base64.StdEncoding.DecodeString(c.AgreementPubB64)
	if err != nil || len(xPub) != 32 {
		return nil, fmt.Errorf("bad agreement key")
	}
	if c.IssuedAt == 0 || c.SignatureB64 == "" {
		return nil, fmt.Errorf("card missing timestamp/signature (v1 unsupported)")
	}
	if age := time.Since(time.Unix(c.IssuedAt, 0)); age > 24*time.Hour || age < -5*time.Minute {
		return nil, fmt.Errorf("card outside 24h validity window")
	}
	transcript := fmt.Sprintf("qr-v2:%s:%s:%s:%d", c.UserID, c.AgreementPubB64, c.IdentityPubB64, c.IssuedAt)
	sig, err := base64.StdEncoding.DecodeString(c.SignatureB64)
	if err != nil || !ed25519.Verify(ed25519.PublicKey(idPub), []byte(transcript), sig) {
		return nil, fmt.Errorf("card signature INVALID")
	}
	derived := fingerprintOf(idPub)
	if derived != c.UserID {
		return nil, fmt.Errorf("userId mismatch (impersonation?): claimed %s… derived %s…",
			c.UserID[:8], derived[:8])
	}
	return &c, nil
}

func cmdAdd(dir string, args []string) error {
	id, _, err := idEnsure(dir)
	if err != nil {
		return err
	}
	petname := flagValue(args, "--petname")
	store, err := contacts.Open(dir)
	if err != nil {
		return err
	}
	fmt.Println("paste contact code (rvn1i… / raven:// URI / JSON), then Enter:")
	rd := bufio.NewReader(os.Stdin)
	line, _ := rd.ReadString('\n')
	c, err := parseCard(line)
	if err != nil {
		// fall back to the compact one-string invite (already fully verified
		// by Decode: signature, derived fingerprint, 24h window)
		parsed, ierr := inv.Decode(line)
		if ierr != nil {
			return fmt.Errorf("not a valid contact code — tried card (%v) and invite (%v)", err, ierr)
		}
		fp := inv.FingerprintOf(parsed.IdentityPub)
		c = &cardJSON{
			UserID:          fp,
			Name:            parsed.Name,
			AgreementPubB64: b64(parsed.AgreementPub),
			IdentityPubB64:  b64(parsed.IdentityPub),
			FingerprintSafe: fp,
			IssuedAt:        parsed.IssuedAt,
			SignatureB64:    b64(parsed.Signature),
		}
	}
	if petname == "" && c.Name != "" {
		petname = strings.ToLower(strings.TrimSpace(c.Name))
	}
	if petname == "" {
		petname = strings.ToLower(c.UserID[:4])
	}
	pid := derivePeerIDFromPub(decodeB64(c.IdentityPubB64))
	if err := store.Upsert(contacts.Contact{
		Petname:      petname,
		Fingerprint:  fingerprintOf(decodeB64(c.IdentityPubB64)),
		PeerID:       pid,
		IdentityB64:  c.IdentityPubB64,
		AgreementB64: c.AgreementPubB64,
		AddedAt:      time.Now().Unix(),
	}); err != nil {
		return err
	}
	_ = id
	fmt.Printf("contact pinned: @%s  %s  (peer %s…)\n", petname, c.UserID, pid[:12])
	return nil
}

func cmdList(dir string) error {
	store, err := contacts.Open(dir)
	if err != nil {
		return err
	}
	all := store.All()
	if len(all) == 0 {
		fmt.Println("(no contacts — try `raven add --petname alice`)")
		return nil
	}
	for _, c := range all {
		fmt.Printf("@%-14s %s  peer %s…\n", c.Petname, c.Fingerprint, c.PeerID[:16])
	}
	return nil
}

// ---- session plumbing ----

func startSession(dir string) (*session.Session, *contacts.Store, *config, func()) {
	id, _, err := idEnsure(dir)
	must(err)
	cfg := loadConfig(dir)
	if cfg.Bootstrap == "" {
		fmt.Fprintln(os.Stderr, "warning: RAVEN_BOOTSTRAP empty — DHT discovery only; set it to a relay multiaddr for reliable connectivity")
	}
	ses, err := session.Start(id, dir, cfg.Bootstrap)
	must(err)
	store, err := contacts.Open(dir)
	must(err)
	stop := func() { _ = ses.Node.Stop() }
	return ses, store, cfg, stop
}

func resolveContact(store *contacts.Store, who string) (*contacts.Contact, error) {
	c, err := store.Resolve(who)
	if err != nil {
		return nil, err
	}
	return c, nil
}

func senderName(cfg *config, id idType) string {
	if cfg.Name != "" {
		return cfg.Name
	}
	return "term-" + id.Fingerprint()[:4]
}

func cmdSend(dir string, args []string) error {
	if len(args) < 2 {
		return fmt.Errorf("usage: raven send WHO TEXT...")
	}
	who := args[0]
	text := strings.Join(args[1:], " ")
	ses, store, cfg, stop := startSession(dir)
	defer stop()
	c, err := resolveContact(store, who)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		done <- ses.SendText(session.ContactInfo{
			Petname:      c.Petname,
			Fingerprint:  c.Fingerprint,
			PeerID:       c.PeerID,
			AgreementKey: decodeB64(c.AgreementB64),
		}, senderName(cfg, ses.ID), text)
	}()
	select {
	case err := <-done:
		if err != nil {
			fmt.Fprintf(os.Stderr, "! direct delivery failed (%v)\n", err)
		} else {
			fmt.Println("DELIVERED")
		}
	case <-ctx.Done():
		fmt.Fprintf(os.Stderr, "! direct delivery timeout\n")
	}
	// mailbox deposit always attempted: covers recipient-offline and
	// direct-path failures alike.
	depositToMailboxes(cfg, c, ses, text, senderName(cfg, ses.ID))
	return nil
}

func depositToMailboxes(cfg *config, c *contacts.Contact, ses *session.Session, text, name string) {
	if cfg.Mailbox == "" {
		return
	}
	payload, idem := sealForDeposit(ses, c, text, name)
	for _, mb := range strings.Split(cfg.Mailbox, ",") {
		mb = strings.TrimSpace(mb)
		if mb == "" {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		n, err := mbox.Deposit(ctx, mb, c.PeerID, idem, payload)
		cancel()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[mailbox] deposit failed (%s): %v\n", mb, err)
			continue
		}
		fmt.Printf("[mailbox] queued at %s (bucket=%d)\n", mb, n)
	}
}

func sealForDeposit(ses *session.Session, c *contacts.Contact, text, name string) (payload, idem string) {
	p, idem, err := ses.SealText(session.ContactInfo{
		Petname:      c.Petname,
		Fingerprint:  c.Fingerprint,
		PeerID:       c.PeerID,
		AgreementKey: decodeB64(c.AgreementB64),
	}, name, text)
	if err != nil {
		return "", ""
	}
	return p, idem
}

func cmdChat(dir string, args []string) error {
	if len(args) < 1 {
		return fmt.Errorf("usage: raven chat WHO")
	}
	who := args[0]
	ses, store, cfg, stop := startSession(dir)
	defer stop()
	c, err := resolveContact(store, who)
	if err != nil {
		return err
	}
	name := senderName(cfg, ses.ID)
	ses.SetHandlers(func(m session.InboundMessage) {
		if m.PayloadKind == "friend_request" {
			return
		}
		fmt.Printf("\r\033[K  %s> %s\n%s> ", displayName(m), m.Text, name)
	}, func(connected bool, pid string) {
		state := "offline"
		if connected {
			state = "online"
		}
		fmt.Fprintf(os.Stderr, "\r\033[K[node] %s as %s\n%s> ", state, pid[:16], name)
	})
	fmt.Printf(banner)
	fmt.Printf("chatting with @%s (%s) — type messages, /q to quit\n", c.Petname, c.Fingerprint)
	fmt.Printf("%s> ", name)
	sc := bufio.NewScanner(os.Stdin)
	sc.Buffer(make([]byte, 1024*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		line = strings.TrimSpace(line)
		if line == "" {
			fmt.Printf("%s> ", name)
			continue
		}
		if line == "/q" || line == "/quit" || line == "/exit" {
			return nil
		}
		if line == "/who" {
			fmt.Printf("  you: %s peer:%s\n  them: %s peer:%s\n", ses.ID.Fingerprint(), ses.PeerID, c.Fingerprint, c.PeerID)
			fmt.Printf("%s> ", name)
			continue
		}
		info := session.ContactInfo{
			Petname:      c.Petname,
			Fingerprint:  c.Fingerprint,
			PeerID:       c.PeerID,
			AgreementKey: decodeB64(c.AgreementB64),
		}
		if err := ses.SendText(info, name, line); err != nil {
			fmt.Fprintf(os.Stderr, "\r\033[K! send failed: %v\n%s> ", err, name)
		} else {
			depositToMailboxes(cfg, c, ses, line, name)
		}
		fmt.Printf("%s> ", name)
	}
	return sc.Err()
}

func displayName(m session.InboundMessage) string {
	if m.SenderName != "" {
		return m.SenderName
	}
	return m.From
}

func cmdListen(dir string) error {
	ses, _, cfg, stop := startSession(dir)
	defer stop()
	name := senderName(cfg, ses.ID)
	ses.SetHandlers(func(m session.InboundMessage) {
		if m.PayloadKind == "friend_request" {
			fmt.Printf("\n[friend-request] from %s (%s)\n> ", displayName(m), m.From)
			return
		}
		fmt.Printf("\r\033[K  %s> %s\n%s> ", displayName(m), m.Text, name)
	}, func(connected bool, pid string) {
		state := "offline"
		if connected {
			state = "online"
		}
		fmt.Fprintf(os.Stderr, "\r\033-K[node] %s as %s\n", state, pid)
	})
	fmt.Printf(banner)
	fmt.Printf("listening — peer %s, fingerprint %s\ninbox: %s/inbox.jsonl\n", ses.PeerID, ses.ID.Fingerprint(), dir)
	fetchMailboxes(ses, cfg)
	c := make(chan os.Signal, 1)
	signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
	<-c
	return nil
}

func fetchMailboxes(ses *session.Session, cfg *config) {
	if cfg.Mailbox == "" {
		return
	}
	for _, mb := range strings.Split(cfg.Mailbox, ",") {
		mb = strings.TrimSpace(mb)
		if mb == "" {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		items, err := mbox.Fetch(ctx, ses.ID.Seed.Seed(), mb)
		cancel()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[mailbox] fetch failed (%s): %v\n", mb, err)
			continue
		}
		for _, it := range items {
			ses.Ingest(it.PayloadB64, it.IDemKey)
		}
		if len(items) > 0 {
			fmt.Printf("[mailbox] fetched %d message(s) from %s\n", len(items), mb)
		}
	}
}

func cmdFetch(dir string) error {
	ses, _, cfg, stop := startSession(dir)
	defer stop()
	fetchMailboxes(ses, cfg)
	return nil
}
