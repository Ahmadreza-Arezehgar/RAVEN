//! RVOR1 immutable output record wire codec (design §4.11).

use crate::hybrid_ratchet_v2_full_braid::constants::{BRAID_MAX_RVOR_RECORD_BYTES, MAX_RVBO1};
use crate::hybrid_ratchet_v2_full_braid::wire_rvbo1::decode_rvbo1;
use crate::hybrid_ratchet_v2_full_braid::wire_util::{
    expect_magic, read_array32, read_bytes, read_u32be, read_u64be, reject_trailing, write_array32,
    write_bytes, write_u16be, write_u32be, write_u64be, WireResult,
};

pub const RVOR1_MAGIC: &[u8; 8] = b"RVOR1\0\0\0";
pub const RVOR1_SCHEMA: u16 = 1;
pub const RVOR1_HEADER_LEN: usize = 196;
pub const RVOR1_FLAG_REPAIR: u16 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rvor1 {
    pub transition_id: [u8; 32],
    pub object_digest: [u8; 32],
    pub execution_digest: [u8; 32],
    pub input_digest: [u8; 32],
    pub output_digest: [u8; 32],
    pub retention_origin_ms: u64,
    pub retention_expiry_ms: u64,
    pub flags: u16,
    pub outputs_bytes: Vec<u8>,
}

impl Rvor1 {
    pub fn encoded_len(&self) -> usize {
        RVOR1_HEADER_LEN + self.outputs_bytes.len()
    }
}

pub fn encode_rvor1(record: &Rvor1) -> WireResult<Vec<u8>> {
    if record.outputs_bytes.len() > MAX_RVBO1 {
        return Err("rvor1 outputs too large".into());
    }
    decode_rvbo1(&record.outputs_bytes)?;
    let total = record.encoded_len();
    if total > BRAID_MAX_RVOR_RECORD_BYTES {
        return Err("rvor1 record too large".into());
    }
    let mut out = Vec::with_capacity(total);
    write_bytes(&mut out, RVOR1_MAGIC);
    write_u16be(&mut out, RVOR1_SCHEMA);
    write_array32(&mut out, &record.transition_id);
    write_array32(&mut out, &record.object_digest);
    write_array32(&mut out, &record.execution_digest);
    write_array32(&mut out, &record.input_digest);
    write_array32(&mut out, &record.output_digest);
    write_u64be(&mut out, record.retention_origin_ms);
    write_u64be(&mut out, record.retention_expiry_ms);
    write_u16be(&mut out, record.flags);
    write_u32be(&mut out, record.outputs_bytes.len() as u32);
    write_bytes(&mut out, &record.outputs_bytes);
    write_u32be(&mut out, 0); // reserved_tail
    Ok(out)
}

pub fn decode_rvor1(data: &[u8]) -> WireResult<Rvor1> {
    if data.len() > BRAID_MAX_RVOR_RECORD_BYTES {
        return Err("rvor1 record too large".into());
    }
    expect_magic(data, RVOR1_MAGIC)?;
    let mut off = 8;
    let schema = crate::hybrid_ratchet_v2_full_braid::wire_util::read_u16be(data, &mut off)?;
    if schema != RVOR1_SCHEMA {
        return Err("rvor1 bad schema".into());
    }
    let transition_id = read_array32(data, &mut off)?;
    let object_digest = read_array32(data, &mut off)?;
    let execution_digest = read_array32(data, &mut off)?;
    let input_digest = read_array32(data, &mut off)?;
    let output_digest = read_array32(data, &mut off)?;
    let retention_origin_ms = read_u64be(data, &mut off)?;
    let retention_expiry_ms = read_u64be(data, &mut off)?;
    let flags = crate::hybrid_ratchet_v2_full_braid::wire_util::read_u16be(data, &mut off)?;
    let outputs_len = read_u32be(data, &mut off)? as usize;
    if outputs_len > MAX_RVBO1 {
        return Err("rvor1 outputs_len".into());
    }
    let outputs_bytes = read_bytes(data, &mut off, outputs_len)?.to_vec();
    let reserved_tail = read_u32be(data, &mut off)?;
    if reserved_tail != 0 {
        return Err("rvor1 reserved_tail".into());
    }
    reject_trailing(data, off)?;
    decode_rvbo1(&outputs_bytes)?;
    Ok(Rvor1 {
        transition_id,
        object_digest,
        execution_digest,
        input_digest,
        output_digest,
        retention_origin_ms,
        retention_expiry_ms,
        flags,
        outputs_bytes,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hybrid_ratchet_v2_full_braid::wire_rvbo1::encode_empty_rvbo1;

    #[test]
    fn roundtrip_empty_outputs() {
        let outputs = encode_empty_rvbo1();
        let record = Rvor1 {
            transition_id: [0x11; 32],
            object_digest: [0x22; 32],
            execution_digest: [0x33; 32],
            input_digest: [0x44; 32],
            output_digest: [0x55; 32],
            retention_origin_ms: 1,
            retention_expiry_ms: 2,
            flags: 0,
            outputs_bytes: outputs,
        };
        let wire = encode_rvor1(&record).unwrap();
        assert_eq!(wire.len(), RVOR1_HEADER_LEN + EMPTY_RVBO1_LEN);
        assert_eq!(decode_rvor1(&wire).unwrap(), record);
    }

    #[test]
    fn max_record_budget() {
        assert_eq!(BRAID_MAX_RVOR_RECORD_BYTES, 196 + MAX_RVBO1);
    }

    #[test]
    fn reject_trailing() {
        let record = Rvor1 {
            transition_id: [0; 32],
            object_digest: [0; 32],
            execution_digest: [0; 32],
            input_digest: [0; 32],
            output_digest: [0; 32],
            retention_origin_ms: 0,
            retention_expiry_ms: 0,
            flags: 0,
            outputs_bytes: encode_empty_rvbo1(),
        };
        let mut wire = encode_rvor1(&record).unwrap();
        wire.push(0);
        assert!(decode_rvor1(&wire).is_err());
    }

    use crate::hybrid_ratchet_v2_full_braid::constants::EMPTY_RVBO1_LEN;
}
