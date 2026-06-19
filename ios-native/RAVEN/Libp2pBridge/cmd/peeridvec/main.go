package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"fmt"

	lcrypto "github.com/libp2p/go-libp2p/core/crypto"
	"github.com/libp2p/go-libp2p/core/peer"
)

func main() {
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(i + 1) // 01 02 ... 20
	}
	std := ed25519.NewKeyFromSeed(seed)
	pub := std.Public().(ed25519.PublicKey)
	fmt.Println("seedHex:", hex.EncodeToString(seed))
	fmt.Println("pubHex:", hex.EncodeToString(pub))
	lpub, err := lcrypto.UnmarshalEd25519PublicKey(pub)
	if err != nil {
		panic(err)
	}
	pid, err := peer.IDFromPublicKey(lpub)
	if err != nil {
		panic(err)
	}
	fmt.Println("peerID:", pid.String())
}
