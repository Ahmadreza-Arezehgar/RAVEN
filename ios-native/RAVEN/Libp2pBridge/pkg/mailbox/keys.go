package mailbox

import "crypto/ed25519"

type ed25519Private = ed25519.PrivateKey

func ed25519Seed(seed []byte) ed25519.PrivateKey { return ed25519.NewKeyFromSeed(seed) }

func ed25519Std(key []byte) ed25519.PrivateKey { return ed25519.PrivateKey(key) }
