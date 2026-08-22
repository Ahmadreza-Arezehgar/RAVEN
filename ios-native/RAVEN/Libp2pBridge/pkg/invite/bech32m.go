// Package bech32m implements BIP-350 Bech32m encoding/decoding (the same
// checksum family RAVEN_ADDRESS_V1 uses for rvn1 addresses). It exists here so
// the invite codec stays dependency-free.
package invite

import (
	"fmt"
	"strings"
)

const charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

var reverseCharset = func() [128]byte {
	var rev [128]byte
	for i := 0; i < len(charset); i++ {
		rev[charset[i]] = byte(i)
	}
	return rev
}()

const bech32mConst = 0x2bc830a3

func polymod(values []byte) uint32 {
	gen := [5]uint32{0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3}
	chk := uint32(1)
	for _, v := range values {
		top := chk >> 25
		chk = (chk&0x1ffffff)<<5 ^ uint32(v)
		for i := 0; i < 5; i++ {
			if (top>>uint(i))&1 == 1 {
				chk ^= gen[i]
			}
		}
	}
	return chk
}

func hrpExpand(hrp string) []byte {
	out := make([]byte, 0, len(hrp)*2+1)
	for i := 0; i < len(hrp); i++ {
		out = append(out, hrp[i]>>5)
	}
	out = append(out, 0)
	for i := 0; i < len(hrp); i++ {
		out = append(out, hrp[i]&31)
	}
	return out
}

func checksum(hrp string, data []byte) []byte {
	values := append(hrpExpand(hrp), data...)
	values = append(values, 0, 0, 0, 0, 0, 0)
	mod := polymod(values) ^ bech32mConst
	out := make([]byte, 6)
	for i := range out {
		out[i] = byte((mod >> uint(5*(5-i))) & 31)
	}
	return out
}

func convertBits(from []byte, fromBits, toBits uint, pad bool) ([]byte, error) {
	var acc uint
	var bits uint
	maxv := uint(1)<<toBits - 1
	maxAcc := uint(1)<<(fromBits+toBits-1) - 1
	out := make([]byte, 0, len(from)*int(fromBits)/int(toBits)+1)
	for _, b := range from {
		v := uint(b)
		if v>>fromBits != 0 {
			return nil, fmt.Errorf("invalid value %d for %d-bit group", v, fromBits)
		}
		acc = (acc<<fromBits | v) & maxAcc
		bits += fromBits
		for bits >= toBits {
			bits -= toBits
			out = append(out, byte(acc>>bits&maxv))
		}
	}
	if pad {
		if bits > 0 {
			out = append(out, byte(acc<<(toBits-bits)&maxv))
		}
	} else if bits >= fromBits || acc<<(toBits-bits)&maxv != 0 {
		return nil, fmt.Errorf("invalid padding")
	}
	return out, nil
}

func bech32mEncode(hrp string, data []byte) (string, error) {
	five, err := convertBits(data, 8, 5, true)
	if err != nil {
		return "", err
	}
	combined := append(five, checksum(hrp, five)...)
	var sb strings.Builder
	sb.WriteString(hrp)
	sb.WriteByte('1')
	for _, v := range combined {
		sb.WriteByte(charset[v])
	}
	return sb.String(), nil
}

func bech32mDecode(s string, hrp string) ([]byte, error) {
	if len(s) < len(hrp)+7 { // hrp + '1' + >=0 data + 6-char checksum
		return nil, fmt.Errorf("string too short")
	}
	if s != strings.ToLower(s) && s != strings.ToUpper(s) {
		return nil, fmt.Errorf("mixed case")
	}
	s = strings.ToLower(s)
	if s[:len(hrp)] != hrp || s[len(hrp)] != '1' {
		return nil, fmt.Errorf("wrong prefix (want %s1...)", hrp)
	}
	dataPart := s[len(hrp)+1:]
	five := make([]byte, 0, len(dataPart))
	for i := 0; i < len(dataPart); i++ {
		c := dataPart[i]
		if c < 33 || c > 126 {
			return nil, fmt.Errorf("invalid character %q", c)
		}
		v := reverseCharset[c]
		if c != charset[v] {
			return nil, fmt.Errorf("invalid character %q", c)
		}
		five = append(five, v)
	}
	verify := append(hrpExpand(hrp), five...)
	if polymod(verify) != bech32mConst {
		return nil, fmt.Errorf("checksum failed (typo?)")
	}
	return convertBits(five[:len(five)-6], 5, 8, false)
}
