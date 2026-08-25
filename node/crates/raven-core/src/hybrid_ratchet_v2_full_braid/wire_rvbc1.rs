//! RVBC1 braid chunk wire codec (design §4.1).

use crate::hybrid_ratchet_v2_full_braid::digest::binding_digest;
use crate::hybrid_ratchet_v2_full_braid::wire_util::{
    expect_magic, read_array32, read_bytes, read_u16be, read_u32be, read_u64be, read_u8,
    reject_trailing, write_array32, write_bytes, write_u16be, write_u32be, write_u64be, write_u8,
    WireResult,
};

pub const RVBC1_MAGIC: &[u8; 8] = b"RVBC1\0\0\0";
pub const RVBC1_MIN_LEN: usize = 55;
pub const RVBC1_MAX_LEN: usize = 8247;
pub const RVBC1_HEADER_LEN: usize = 23;
pub const RVBC1_MAX_PAYLOAD: usize = RVBC1_MAX_LEN - RVBC1_HEADER_LEN - 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rvbc1 {
    pub epoch: u64,
    pub chunk_type: u8,
    pub index: u32,
    pub payload: Vec<u8>,
    pub binding_digest: [u8; 32],
}

impl Rvbc1 {
    pub fn encoded_len(&self) -> usize {
        RVBC1_HEADER_LEN + self.payload.len() + 32
    }

    pub fn compute_binding(&self, direction: u8, session_id: &[u8; 32]) -> [u8; 32] {
        binding_digest(
            direction,
            self.epoch,
            self.chunk_type,
            self.index,
            &self.payload,
            session_id,
        )
    }

    pub fn verify_binding(&self, direction: u8, session_id: &[u8; 32]) -> WireResult<()> {
        if self.compute_binding(direction, session_id) != self.binding_digest {
            return Err("binding digest mismatch".into());
        }
        Ok(())
    }
}

pub fn encode_rvbc1(chunk: &Rvbc1) -> WireResult<Vec<u8>> {
    if chunk.payload.len() > RVBC1_MAX_PAYLOAD {
        return Err("rvbc1 payload too large".into());
    }
    let total = chunk.encoded_len();
    if !(RVBC1_MIN_LEN..=RVBC1_MAX_LEN).contains(&total) {
        return Err("rvbc1 length out of range".into());
    }
    let mut out = Vec::with_capacity(total);
    write_bytes(&mut out, RVBC1_MAGIC);
    write_u64be(&mut out, chunk.epoch);
    write_u8(&mut out, chunk.chunk_type);
    write_u32be(&mut out, chunk.index);
    write_u16be(&mut out, chunk.payload.len() as u16);
    write_bytes(&mut out, &chunk.payload);
    write_array32(&mut out, &chunk.binding_digest);
    Ok(out)
}

pub fn decode_rvbc1(data: &[u8]) -> WireResult<Rvbc1> {
    if !(RVBC1_MIN_LEN..=RVBC1_MAX_LEN).contains(&data.len()) {
        return Err("rvbc1 length out of range".into());
    }
    expect_magic(data, RVBC1_MAGIC)?;
    let mut off = 8;
    let epoch = read_u64be(data, &mut off)?;
    let chunk_type = read_u8(data, &mut off)?;
    let index = read_u32be(data, &mut off)?;
    let plen = read_u16be(data, &mut off)? as usize;
    let payload = read_bytes(data, &mut off, plen)?.to_vec();
    let binding_digest = read_array32(data, &mut off)?;
    reject_trailing(data, off)?;
    Ok(Rvbc1 {
        epoch,
        chunk_type,
        index,
        payload,
        binding_digest,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hybrid_ratchet_v2_full_braid::digest::binding_digest;
    use crate::hybrid_ratchet_v2_full_braid::spqr_pin_audit::CW;

    fn sample_chunk(payload_len: usize) -> Rvbc1 {
        let sid = [0xAAu8; 32];
        let payload = vec![0xBB; payload_len];
        let binding = binding_digest(0, 1, 1, 0, &payload, &sid);
        Rvbc1 {
            epoch: 1,
            chunk_type: 1,
            index: 0,
            payload,
            binding_digest: binding,
        }
    }

    #[test]
    fn empty_payload_min_len_55() {
        let chunk = sample_chunk(0);
        let wire = encode_rvbc1(&chunk).unwrap();
        assert_eq!(wire.len(), RVBC1_MIN_LEN);
        assert_eq!(decode_rvbc1(&wire).unwrap(), chunk);
    }

    #[test]
    fn codeword_payload_roundtrip() {
        let chunk = sample_chunk(CW);
        let wire = encode_rvbc1(&chunk).unwrap();
        assert!(wire.len() <= RVBC1_MAX_LEN);
        assert_eq!(decode_rvbc1(&wire).unwrap(), chunk);
    }

    #[test]
    fn reject_trailing_bytes() {
        let chunk = sample_chunk(0);
        let mut wire = encode_rvbc1(&chunk).unwrap();
        wire.push(0);
        assert!(decode_rvbc1(&wire).is_err());
    }

    #[test]
    fn reject_oversize() {
        let chunk = sample_chunk(RVBC1_MAX_PAYLOAD + 1);
        assert!(encode_rvbc1(&chunk).is_err());
    }
}
