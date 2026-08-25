//! Task 6 — git-pinned `spqr` PolyEncoder/PolyDecoder wrapper for Full Braid lab.
//!
//! Wraps Signal SPQR polynomial erasure Encode/Decode only (no Raven RS).
//! Requires `spqr` feature `test-utils` so `spqr::encoding` is public (lab-only).
//!
//! **`N(L)` semantics:** `N(L) = L/CW` is the systematic threshold (any `N`
//! distinct chunks suffice to recover). It is **not** the maximum chunk index.
//! Redundancy chunks use indices `N .. BRAID_MAX_CHUNK_INDEX` inclusive
//! (`BRAID_MAX_CHUNKS_PER_EPOCH = 64` → indices `0..=63`).

use spqr::encoding::polynomial::{PolyDecoder, PolyEncoder};
use spqr::encoding::{Chunk, Decoder, Encoder, EncodingError};
use thiserror::Error;

use crate::hybrid_ratchet_v2_full_braid::spqr_pin_audit::{
    CW, L_CT1, L_CT2, L_EK, L_HDR, N_CT1, N_CT2, N_EK, N_HDR,
};

/// Design §3 `BRAID_MAX_CHUNKS_PER_EPOCH = 64` → valid indices `0..=63`.
pub const BRAID_MAX_CHUNKS_PER_EPOCH: usize = 64;
pub const BRAID_MAX_CHUNK_INDEX: u32 = (BRAID_MAX_CHUNKS_PER_EPOCH as u32) - 1;

/// Braid chunk wire types (design §5.1).
pub const WIRE_NONE: u8 = 0;
pub const WIRE_HDR: u8 = 1;
pub const WIRE_EK: u8 = 2;
pub const WIRE_EK_CT1_ACK: u8 = 3;
pub const WIRE_CT1_ACK: u8 = 4;
pub const WIRE_CT1: u8 = 5;
pub const WIRE_CT2: u8 = 6;

#[derive(Debug, Error, Clone, PartialEq)]
pub enum SpqrCodecError {
    #[error("spqr encoding error: {0}")]
    Encoding(#[from] EncodingError),
    #[error("unsupported source length {0}")]
    UnsupportedSourceLen(usize),
    #[error("chunk length {0} != CW ({CW})")]
    BadChunkLen(usize),
    #[error("chunk index {index} exceeds BRAID_MAX_CHUNK_INDEX ({BRAID_MAX_CHUNK_INDEX})")]
    ChunkIndexOutOfRange { index: u32 },
    #[error("unknown wire type {0}")]
    UnknownWireType(u8),
    #[error("message not yet decodable")]
    Incomplete,
}

pub struct BraidEncoder {
    inner: PolyEncoder,
    /// Systematic threshold `N(L)` — not a max index.
    n: usize,
    next_index: u32,
}

pub struct BraidDecoder {
    inner: PolyDecoder,
    n: usize,
}

fn validate_chunk_index(index: u32) -> Result<u16, SpqrCodecError> {
    if index > BRAID_MAX_CHUNK_INDEX {
        return Err(SpqrCodecError::ChunkIndexOutOfRange { index });
    }
    u16::try_from(index).map_err(|_| SpqrCodecError::ChunkIndexOutOfRange { index })
}

impl BraidEncoder {
    pub fn encode(source: &[u8]) -> Result<Self, SpqrCodecError> {
        let n = Self::expected_n(source.len())
            .ok_or(SpqrCodecError::UnsupportedSourceLen(source.len()))?;
        let inner = PolyEncoder::encode_bytes(source)?;
        Ok(Self {
            inner,
            n,
            next_index: 0,
        })
    }

    /// Emit chunk at `index` (systematic `0..N` or redundancy `N..=63`).
    pub fn chunk_at(&mut self, index: u32) -> Result<[u8; CW], SpqrCodecError> {
        let idx = validate_chunk_index(index)?;
        let chunk = self.inner.chunk_at(idx);
        Ok(chunk.data)
    }

    /// Sequential emit starting at 0; continues through redundancy indices.
    pub fn next_chunk(&mut self) -> Result<[u8; CW], SpqrCodecError> {
        let idx = validate_chunk_index(self.next_index)?;
        let chunk = self.inner.next_chunk();
        debug_assert_eq!(chunk.index, idx);
        debug_assert_eq!(chunk.data.len(), CW);
        self.next_index = self.next_index.saturating_add(1);
        Ok(chunk.data)
    }

    pub fn expected_n(source_len: usize) -> Option<usize> {
        match source_len {
            L_HDR => Some(N_HDR),
            L_EK => Some(N_EK),
            L_CT1 => Some(N_CT1),
            L_CT2 => Some(N_CT2),
            _ => None,
        }
    }

    /// Systematic threshold `N(L)`.
    pub fn n(&self) -> usize {
        self.n
    }
}

impl BraidDecoder {
    pub fn new(message_len: usize) -> Result<Self, SpqrCodecError> {
        let n = Self::expected_n(message_len)
            .ok_or(SpqrCodecError::UnsupportedSourceLen(message_len))?;
        let inner = PolyDecoder::new(message_len)?;
        Ok(Self { inner, n })
    }

    pub fn add_chunk(&mut self, index: u32, chunk: &[u8]) -> Result<(), SpqrCodecError> {
        if chunk.len() != CW {
            return Err(SpqrCodecError::BadChunkLen(chunk.len()));
        }
        let idx = validate_chunk_index(index)?;
        let data: [u8; CW] = chunk
            .try_into()
            .map_err(|_| SpqrCodecError::BadChunkLen(chunk.len()))?;
        self.inner.add_chunk(&Chunk { index: idx, data });
        Ok(())
    }

    pub fn has_message(&self) -> bool {
        self.inner.decoded_message().is_some()
    }

    pub fn message(&self) -> Result<Vec<u8>, SpqrCodecError> {
        self.inner
            .decoded_message()
            .ok_or(SpqrCodecError::Incomplete)
    }

    pub fn expected_n(message_len: usize) -> Option<usize> {
        BraidEncoder::expected_n(message_len)
    }

    pub fn n(&self) -> usize {
        self.n
    }
}

/// Whether an inbound braid set needs an SPQR decoder for its source body.
///
/// Fail-closed: only registered payload wire types return `Ok(true|false)`.
pub fn wire_needs_decoder(wire_type: u8) -> Result<bool, SpqrCodecError> {
    match wire_type {
        WIRE_NONE | WIRE_CT1_ACK => Ok(false),
        WIRE_HDR | WIRE_EK | WIRE_EK_CT1_ACK | WIRE_CT1 | WIRE_CT2 => Ok(true),
        other => Err(SpqrCodecError::UnknownWireType(other)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use spqr::encoding::polynomial::PolyDecoder as DirectPolyDecoder;
    use spqr::encoding::polynomial::PolyEncoder as DirectPolyEncoder;
    use spqr::encoding::{
        Chunk as DirectChunk, Decoder as DirectDecoder, Encoder as DirectEncoder,
    };

    const LENGTHS: [(usize, usize); 4] =
        [(L_HDR, N_HDR), (L_EK, N_EK), (L_CT1, N_CT1), (L_CT2, N_CT2)];

    fn fill(len: usize, seed: u8) -> Vec<u8> {
        (0..len).map(|i| seed.wrapping_add(i as u8)).collect()
    }

    #[test]
    fn expected_n_is_threshold_not_max_index() {
        for (l, n) in LENGTHS {
            assert_eq!(BraidEncoder::expected_n(l), Some(n));
            assert_eq!(n * CW, l);
            // Redundancy indices are legal.
            let mut enc = BraidEncoder::encode(&fill(l, 1)).unwrap();
            assert!(enc.chunk_at(n as u32).is_ok());
            assert!(enc.chunk_at(BRAID_MAX_CHUNK_INDEX).is_ok());
            assert!(matches!(
                enc.chunk_at(BRAID_MAX_CHUNK_INDEX + 1),
                Err(SpqrCodecError::ChunkIndexOutOfRange { .. })
            ));
        }
    }

    #[test]
    fn wire_needs_decoder_exhaustive() {
        assert_eq!(wire_needs_decoder(WIRE_NONE), Ok(false));
        assert_eq!(wire_needs_decoder(WIRE_HDR), Ok(true));
        assert_eq!(wire_needs_decoder(WIRE_EK), Ok(true));
        assert_eq!(wire_needs_decoder(WIRE_EK_CT1_ACK), Ok(true));
        assert_eq!(wire_needs_decoder(WIRE_CT1_ACK), Ok(false));
        assert_eq!(wire_needs_decoder(WIRE_CT1), Ok(true));
        assert_eq!(wire_needs_decoder(WIRE_CT2), Ok(true));
        for t in 7u8..=255 {
            assert!(matches!(
                wire_needs_decoder(t),
                Err(SpqrCodecError::UnknownWireType(_))
            ));
        }
    }

    #[test]
    fn chunk_index_no_u32_truncation() {
        let mut enc = BraidEncoder::encode(&fill(L_HDR, 0)).unwrap();
        let mut dec = BraidDecoder::new(L_HDR).unwrap();
        // 65536 would truncate to 0 as u16 — must be rejected before cast.
        assert!(matches!(
            enc.chunk_at(65536),
            Err(SpqrCodecError::ChunkIndexOutOfRange { index: 65536 })
        ));
        assert!(matches!(
            dec.add_chunk(65536, &[0u8; CW]),
            Err(SpqrCodecError::ChunkIndexOutOfRange { index: 65536 })
        ));
        assert!(matches!(
            enc.chunk_at(u32::MAX),
            Err(SpqrCodecError::ChunkIndexOutOfRange { .. })
        ));
    }

    #[test]
    fn loss_reorder_using_redundancy_indices() {
        for (len, n) in LENGTHS {
            let source = fill(len, 0x7A);
            let mut enc = BraidEncoder::encode(&source).unwrap();
            // Drop first systematic chunk; use N..(N+k) redundancy + remaining systematic.
            let mut indices: Vec<u32> = (1..n as u32).collect();
            let need = n - indices.len();
            for k in 0..need {
                indices.push(n as u32 + k as u32);
            }
            assert_eq!(indices.len(), n);
            // Reorder: reverse delivery order.
            indices.reverse();

            let mut dec = BraidDecoder::new(len).unwrap();
            for i in indices {
                let chunk = enc.chunk_at(i).unwrap();
                assert_eq!(chunk.len(), CW);
                dec.add_chunk(i, &chunk).unwrap();
            }
            assert!(dec.has_message());
            assert_eq!(dec.message().unwrap(), source);
        }
    }

    #[test]
    fn wrapper_matches_direct_spqr_oracle() {
        for (len, n) in LENGTHS {
            let source = fill(len, 0x3C);
            let mut wrap = BraidEncoder::encode(&source).unwrap();
            let mut direct = DirectPolyEncoder::encode_bytes(&source).unwrap();

            // Compare systematic + first redundancy block.
            for i in 0..(n as u32 + 4).min(BRAID_MAX_CHUNK_INDEX + 1) {
                let a = wrap.chunk_at(i).unwrap();
                let b = direct.chunk_at(i as u16);
                assert_eq!(a.as_slice(), b.data.as_slice(), "len={len} index={i}");
            }

            // Decode path: wrapper decoder vs direct decoder with same mixed indices.
            let mut indices: Vec<u32> = (0..n as u32 / 2).collect();
            let mut next_redundancy = n as u32;
            while indices.len() < n {
                if next_redundancy > BRAID_MAX_CHUNK_INDEX {
                    panic!(
                        "len={len} n={n}: need {} indices within 0..={BRAID_MAX_CHUNK_INDEX}",
                        n
                    );
                }
                indices.push(next_redundancy);
                next_redundancy += 1;
            }
            indices.reverse();

            let mut wrap_dec = BraidDecoder::new(len).unwrap();
            let mut direct_dec = DirectPolyDecoder::new(len).unwrap();
            for i in &indices {
                let chunk = wrap.chunk_at(*i).unwrap();
                wrap_dec.add_chunk(*i, &chunk).unwrap();
                let idx = u16::try_from(*i).unwrap();
                direct_dec.add_chunk(&DirectChunk {
                    index: idx,
                    data: chunk,
                });
            }
            assert_eq!(wrap_dec.message().unwrap(), source);
            assert_eq!(DirectDecoder::decoded_message(&direct_dec).unwrap(), source);
        }
    }

    #[test]
    fn chunk_at_plen_is_cw() {
        let source = fill(L_EK, 0x42);
        let mut enc = BraidEncoder::encode(&source).unwrap();
        for i in 0..(N_EK as u32 + 3) {
            let chunk = enc.chunk_at(i).unwrap();
            assert_eq!(chunk.len(), CW);
        }
    }

    #[test]
    fn roundtrip_all_lengths_deterministic() {
        for (idx, (len, n)) in LENGTHS.iter().enumerate() {
            let source = fill(*len, (idx as u8).wrapping_mul(17));
            roundtrip_one(&source, *n);
        }
    }

    #[test]
    fn roundtrip_all_lengths_random_fill() {
        for (idx, (len, n)) in LENGTHS.iter().enumerate() {
            let mut source = vec![0u8; *len];
            for (i, b) in source.iter_mut().enumerate() {
                *b = ((i * 7919 + idx * 104729) & 0xFF) as u8;
            }
            roundtrip_one(&source, *n);
        }
    }

    #[test]
    fn first_n_systematic_chunks_reconstruct() {
        for (len, n) in LENGTHS {
            let source = fill(len, 0x55);
            let mut enc = BraidEncoder::encode(&source).unwrap();
            let mut dec = BraidDecoder::new(len).unwrap();
            for i in 0..n as u32 {
                let chunk = enc.chunk_at(i).unwrap();
                dec.add_chunk(i, &chunk).unwrap();
            }
            assert!(dec.has_message());
            assert_eq!(dec.message().unwrap(), source);
        }
    }

    #[test]
    fn next_chunk_sequential_including_redundancy() {
        let source = fill(L_HDR, 0x11);
        let mut enc = BraidEncoder::encode(&source).unwrap();
        // Consume systematic + one redundancy via next_chunk.
        let mut chunks = Vec::new();
        for _ in 0..(N_HDR + 1) {
            chunks.push(enc.next_chunk().unwrap());
        }
        // Reconstruct from indices 1..N_HDR plus redundancy at N_HDR (drop 0).
        let mut dec = BraidDecoder::new(L_HDR).unwrap();
        for i in 1..=N_HDR as u32 {
            dec.add_chunk(i, &chunks[i as usize]).unwrap();
        }
        assert_eq!(dec.message().unwrap(), source);
    }

    #[test]
    fn rejects_bad_chunk_len() {
        let mut dec = BraidDecoder::new(L_HDR).unwrap();
        let err = dec.add_chunk(0, &[0u8; 31]).unwrap_err();
        assert!(matches!(err, SpqrCodecError::BadChunkLen(31)));
    }

    #[test]
    fn rejects_unsupported_length() {
        assert!(matches!(
            BraidEncoder::encode(&[0u8; 64]),
            Err(SpqrCodecError::UnsupportedSourceLen(64))
        ));
        assert!(matches!(
            BraidDecoder::new(64),
            Err(SpqrCodecError::UnsupportedSourceLen(64))
        ));
    }

    fn roundtrip_one(source: &[u8], n: usize) {
        let len = source.len();
        let mut enc = BraidEncoder::encode(source).unwrap();
        assert_eq!(enc.n(), n);
        let mut dec = BraidDecoder::new(len).unwrap();
        for i in 0..n as u32 {
            let chunk = enc.chunk_at(i).unwrap();
            assert_eq!(chunk.len(), CW);
            dec.add_chunk(i, &chunk).unwrap();
        }
        assert!(dec.has_message());
        assert_eq!(dec.message().unwrap(), source);
    }
}
