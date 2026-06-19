//go:build tools

// Package tools pins golang.org/x/mobile as a direct module dependency so
// `gomobile bind` can find it (and `go mod tidy` keeps it + its go.sum
// entries). Excluded from normal builds by the `tools` build tag.
package tools

import (
	_ "golang.org/x/mobile/bind"
)
