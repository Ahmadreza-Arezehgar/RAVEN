package session

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
)

// RoomID matches MessageService.makeRoomId: the two user ids sorted and
// joined with "_".
func RoomID(a, b string) string {
	if a < b {
		return a + "_" + b
	}
	return b + "_" + a
}

func ptr[T any](v T) *T { return &v }

func b64(raw []byte) string { return base64.StdEncoding.EncodeToString(raw) }

func randomB64(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return base64.StdEncoding.EncodeToString(b)
}

func newUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

var _ = sha256.Sum256
var _ = hex.EncodeToString
var _ = json.Marshal
