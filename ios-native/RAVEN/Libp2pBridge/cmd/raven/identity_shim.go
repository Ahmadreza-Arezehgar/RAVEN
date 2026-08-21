package main

import (
	"encoding/base64"

	"github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"
	"github.com/raven/ravenbridge/pkg/identity"
)

// idType aliases the shared identity for local helpers.
type idType = *identity.Identity

func idEnsure(dir string) (idType, bool, error) { return identity.Ensure(dir) }

func b64(raw []byte) string { return base64.StdEncoding.EncodeToString(raw) }

func decodeB64(s string) []byte {
	raw, _ := base64.StdEncoding.DecodeString(s)
	return raw
}

func fingerprintOf(pub []byte) string {
	fp, err := identity.Fingerprint(pub)
	if err != nil {
		return ""
	}
	return fp
}

// derivePeerIDFromPub mirrors libp2p peer.IDFromPublicKey for an ed25519 key.
func derivePeerIDFromPub(pub []byte) string {
	pk, err := crypto.UnmarshalEd25519PublicKey(pub)
	if err != nil {
		return ""
	}
	id, err := peer.IDFromPublicKey(pk)
	if err != nil {
		return ""
	}
	return id.String()
}

func peerIDOf(id idType) string { return derivePeerIDFromPub(id.PublicKey()) }

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func ravenUUID() string { return "" }
