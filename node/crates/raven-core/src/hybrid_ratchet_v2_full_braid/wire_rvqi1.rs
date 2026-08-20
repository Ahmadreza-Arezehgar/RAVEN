//! RVQI1 quarantine-index wire codec (design §4.12).

use crate::hybrid_ratchet_v2_full_braid::wire_util::{
    expect_magic, read_array32, read_u32be, read_u64be, read_u8, reject_trailing, write_array32,
    write_bytes, write_u16be, write_u32be, write_u64be, write_u8, WireResult,
};

pub const RVQI1_MAGIC: &[u8; 8] = b"RVQI1\0\0\0";
pub const RVQI1_SCHEMA: u16 = 1;
pub const RVQI1_STATUS_QUARANTINED: u8 = 1;
pub const RVQI1_LEN: usize = 88;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rvqi1 {
    pub transition_id: [u8; 32],
    pub object_digest: [u8; 32],
    pub status: u8,
    pub cas_tag: u64,
}

pub fn encode_rvqi1(record: &Rvqi1) -> WireResult<Vec<u8>> {
    if record.status != RVQI1_STATUS_QUARANTINED {
        return Err("rvqi1 bad status".into());
    }

    let mut out = Vec::with_capacity(RVQI1_LEN);
    write_bytes(&mut out, RVQI1_MAGIC);
    write_u16be(&mut out, RVQI1_SCHEMA);
    write_array32(&mut out, &record.transition_id);
    write_array32(&mut out, &record.object_digest);
    write_u8(&mut out, record.status);
    write_u8(&mut out, 0); // reserved0
    write_u64be(&mut out, record.cas_tag);
    write_u32be(&mut out, 0); // reserved_tail
    debug_assert_eq!(out.len(), RVQI1_LEN);
    Ok(out)
}

pub fn decode_rvqi1(data: &[u8]) -> WireResult<Rvqi1> {
    expect_magic(data, RVQI1_MAGIC)?;
    let mut off = 8;
    let schema = crate::hybrid_ratchet_v2_full_braid::wire_util::read_u16be(data, &mut off)?;
    if schema != RVQI1_SCHEMA {
        return Err("rvqi1 bad schema".into());
    }
    let transition_id = read_array32(data, &mut off)?;
    let object_digest = read_array32(data, &mut off)?;
    let status = read_u8(data, &mut off)?;
    if status != RVQI1_STATUS_QUARANTINED {
        return Err("rvqi1 bad status".into());
    }
    if read_u8(data, &mut off)? != 0 {
        return Err("rvqi1 reserved0".into());
    }
    let cas_tag = read_u64be(data, &mut off)?;
    if read_u32be(data, &mut off)? != 0 {
        return Err("rvqi1 reserved_tail".into());
    }
    reject_trailing(data, off)?;
    Ok(Rvqi1 {
        transition_id,
        object_digest,
        status,
        cas_tag,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Rvqi1 {
        Rvqi1 {
            transition_id: [0x11; 32],
            object_digest: [0x22; 32],
            status: RVQI1_STATUS_QUARANTINED,
            cas_tag: 0x0102_0304_0506_0708,
        }
    }

    #[test]
    fn roundtrip_is_byte_exact() {
        let record = sample();
        let wire = encode_rvqi1(&record).unwrap();

        assert_eq!(wire.len(), RVQI1_LEN);
        assert_eq!(&wire[0..8], b"RVQI1\0\0\0");
        assert_eq!(&wire[8..10], &1u16.to_be_bytes());
        assert_eq!(&wire[10..42], &[0x11; 32]);
        assert_eq!(&wire[42..74], &[0x22; 32]);
        assert_eq!(wire[74], RVQI1_STATUS_QUARANTINED);
        assert_eq!(wire[75], 0);
        assert_eq!(&wire[76..84], &0x0102_0304_0506_0708u64.to_be_bytes());
        assert_eq!(&wire[84..88], &[0; 4]);
        assert_eq!(decode_rvqi1(&wire).unwrap(), record);
    }

    #[test]
    fn rejects_trailing_bytes() {
        let mut wire = encode_rvqi1(&sample()).unwrap();
        wire.push(0);
        assert!(decode_rvqi1(&wire).is_err());
    }
}
