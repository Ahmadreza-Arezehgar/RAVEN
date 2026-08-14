package ravenbridge

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/libp2p/go-libp2p/core/peer"
)

type memoryInboundStream struct {
	reader io.Reader

	mu       sync.Mutex
	closed   int
	reset    int
	deadline time.Time
}

func (s *memoryInboundStream) Read(p []byte) (int, error) {
	return s.reader.Read(p)
}

func (s *memoryInboundStream) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed++
	return nil
}

func (s *memoryInboundStream) Reset() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.reset++
	return nil
}

func (s *memoryInboundStream) SetReadDeadline(deadline time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.deadline = deadline
	return nil
}

func (s *memoryInboundStream) closeCounts() (closed, reset int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closed, s.reset
}

type pipeInboundStream struct {
	net.Conn

	mu    sync.Mutex
	reset int
}

func (s *pipeInboundStream) Reset() error {
	s.mu.Lock()
	s.reset++
	s.mu.Unlock()
	return s.Conn.Close()
}

func (s *pipeInboundStream) wasReset() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.reset > 0
}

func encodedBridgeFrame(envelope, idempotencyKey []byte) []byte {
	var frame bytes.Buffer
	var envelopeHeader [4]byte
	binary.BigEndian.PutUint32(envelopeHeader[:], uint32(len(envelope)))
	frame.Write(envelopeHeader[:])
	frame.Write(envelope)
	var keyHeader [2]byte
	binary.BigEndian.PutUint16(keyHeader[:], uint16(len(idempotencyKey)))
	frame.Write(keyHeader[:])
	frame.Write(idempotencyKey)
	return frame.Bytes()
}

func assertLimiterDrained(t *testing.T, limiter *inboundLimiter) {
	t.Helper()
	limiter.mu.Lock()
	defer limiter.mu.Unlock()
	if limiter.streams != 0 || limiter.bytes != 0 || len(limiter.usageByPeer) != 0 {
		t.Fatalf("limiter leak: streams=%d bytes=%d peers=%d", limiter.streams, limiter.bytes, len(limiter.usageByPeer))
	}
}

func TestInboundMalformedFramesResetAndReleaseReservations(t *testing.T) {
	tests := []struct {
		name  string
		frame []byte
	}{
		{
			name:  "zero envelope",
			frame: []byte{0, 0, 0, 0},
		},
		{
			name: "oversize envelope",
			frame: func() []byte {
				var header [4]byte
				binary.BigEndian.PutUint32(header[:], uint32(maxEnvelopeBytes+1))
				return header[:]
			}(),
		},
		{
			name:  "oversize idempotency key",
			frame: encodedBridgeFrame([]byte("x"), make([]byte, maxIdempotencyKeyBytes+1)),
		},
		{
			name: "truncated envelope",
			frame: func() []byte {
				var header [4]byte
				binary.BigEndian.PutUint32(header[:], 10)
				return append(header[:], []byte("short")...)
			}(),
		},
		{
			name: "truncated idempotency key",
			frame: func() []byte {
				frame := encodedBridgeFrame([]byte("envelope"), []byte("key"))
				return frame[:len(frame)-1]
			}(),
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			limiter := newInboundLimiter(defaultInboundLimits)
			delegate := newRecordingDelegate()
			node := &Node{
				delegate:           delegate,
				inboundLimiter:     limiter,
				inboundReadTimeout: time.Second,
			}
			stream := &memoryInboundStream{reader: bytes.NewReader(test.frame)}

			node.handleInboundStream(stream, peer.ID("attacker"))

			closed, reset := stream.closeCounts()
			if closed != 0 || reset != 1 {
				t.Fatalf("malicious stream close=%d reset=%d, want close=0 reset=1", closed, reset)
			}
			if got := delegate.received(); len(got) != 0 {
				t.Fatalf("malformed frame reached delegate: %q", got)
			}
			assertLimiterDrained(t, limiter)
		})
	}
}

func TestInboundValidFrameClosesWithoutMutation(t *testing.T) {
	limiter := newInboundLimiter(defaultInboundLimits)
	delegate := newRecordingDelegate()
	node := &Node{
		delegate:           delegate,
		inboundLimiter:     limiter,
		inboundReadTimeout: time.Second,
	}
	stream := &memoryInboundStream{reader: bytes.NewReader(encodedBridgeFrame(
		[]byte{0x00, 0xff, 0x42},
		[]byte("idem-1"),
	))}

	node.handleInboundStream(stream, peer.ID("sender"))

	closed, reset := stream.closeCounts()
	if closed != 1 || reset != 0 {
		t.Fatalf("valid stream close=%d reset=%d, want close=1 reset=0", closed, reset)
	}
	delegate.mu.Lock()
	defer delegate.mu.Unlock()
	if len(delegate.envelopes) != 1 || delegate.envelopes[0] != string([]byte{0x00, 0xff, 0x42}) {
		t.Fatalf("opaque envelope changed: %q", delegate.envelopes)
	}
	if len(delegate.idemKeys) != 1 || delegate.idemKeys[0] != "idem-1" {
		t.Fatalf("idempotency key changed: %q", delegate.idemKeys)
	}
	assertLimiterDrained(t, limiter)
}

func TestInboundSlowStreamHitsDeadlineAndReleasesReservation(t *testing.T) {
	limiter := newInboundLimiter(defaultInboundLimits)
	node := &Node{
		delegate:           newRecordingDelegate(),
		inboundLimiter:     limiter,
		inboundReadTimeout: 25 * time.Millisecond,
	}
	local, remote := net.Pipe()
	t.Cleanup(func() { _ = remote.Close() })
	stream := &pipeInboundStream{Conn: local}
	done := make(chan struct{})
	go func() {
		node.handleInboundStream(stream, peer.ID("slow-peer"))
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stalled inbound stream outlived its read deadline")
	}
	if !stream.wasReset() {
		t.Fatal("stalled inbound stream was not reset")
	}
	assertLimiterDrained(t, limiter)
}

func TestInboundLimiterConcurrentBudgetsAndRelease(t *testing.T) {
	limits := inboundLimitConfig{
		streamsGlobal:  8,
		streamsPerPeer: 8,
		bytesGlobal:    100,
		bytesPerPeer:   100,
	}
	limiter := newInboundLimiter(limits)

	const workers = 8
	start := make(chan struct{})
	release := make(chan struct{})
	results := make(chan bool, workers)
	var group sync.WaitGroup
	for i := 0; i < workers; i++ {
		group.Add(1)
		go func(i int) {
			defer group.Done()
			reservation, ok := limiter.acquire(peer.ID(fmt.Sprintf("peer-%d", i)))
			if !ok {
				results <- false
				return
			}
			<-start
			if !reservation.reserveBytes(40) {
				reservation.release()
				results <- false
				return
			}
			results <- true
			<-release
			reservation.release()
		}(i)
	}
	close(start)

	succeeded := 0
	for i := 0; i < workers; i++ {
		if <-results {
			succeeded++
		}
	}
	if succeeded != 2 {
		t.Fatalf("concurrent byte reservations succeeded=%d, want 2", succeeded)
	}
	limiter.mu.Lock()
	if limiter.bytes != 80 || limiter.streams != 2 {
		t.Errorf("live bounded usage streams=%d bytes=%d, want streams=2 bytes=80", limiter.streams, limiter.bytes)
	}
	limiter.mu.Unlock()

	close(release)
	group.Wait()
	assertLimiterDrained(t, limiter)
}

func TestInboundLimiterPreservesMaximumFrameAndIsolatesPeers(t *testing.T) {
	limiter := newInboundLimiter(defaultInboundLimits)
	peerA := peer.ID("peer-a")
	peerB := peer.ID("peer-b")

	maximumA, ok := limiter.acquire(peerA)
	if !ok || !maximumA.reserveBytes(maxEnvelopeBytes) || !maximumA.reserveBytes(maxIdempotencyKeyBytes) {
		t.Fatal("one peer could not reserve the legitimate maximum frame")
	}
	secondA, ok := limiter.acquire(peerA)
	if !ok {
		t.Fatal("small concurrent streams should fit the per-peer stream limit")
	}
	if secondA.reserveBytes(1) {
		t.Fatal("one peer exceeded its unvalidated-byte budget")
	}
	secondA.release()

	maximumB, ok := limiter.acquire(peerB)
	if !ok || !maximumB.reserveBytes(maxEnvelopeBytes) || !maximumB.reserveBytes(maxIdempotencyKeyBytes) {
		t.Fatal("a second peer could not reserve the legitimate maximum frame")
	}
	thirdPeer, ok := limiter.acquire(peer.ID("peer-c"))
	if !ok {
		t.Fatal("global stream budget unexpectedly exhausted")
	}
	if thirdPeer.reserveBytes(1) {
		t.Fatal("peers exceeded the global unvalidated-byte budget")
	}
	thirdPeer.release()

	maximumA.release()
	replacementA, ok := limiter.acquire(peerA)
	if !ok || !replacementA.reserveBytes(maxEnvelopeBytes) || !replacementA.reserveBytes(maxIdempotencyKeyBytes) {
		t.Fatal("released capacity was not reusable")
	}
	replacementA.release()
	maximumB.release()
	assertLimiterDrained(t, limiter)
}

func TestOutboundFrameRejectsOversizeIdempotencyKey(t *testing.T) {
	if err := validateOutboundFrame([]byte("envelope"), make([]byte, maxIdempotencyKeyBytes)); err != nil {
		t.Fatalf("maximum idempotency key rejected: %v", err)
	}
	if err := validateOutboundFrame([]byte("envelope"), make([]byte, maxIdempotencyKeyBytes+1)); err == nil {
		t.Fatal("oversize idempotency key accepted")
	}
}
