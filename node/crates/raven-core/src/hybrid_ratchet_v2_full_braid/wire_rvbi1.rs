//! RVBI1 transition input wire codec (design §4.7).

use crate::hybrid_ratchet_v2_full_braid::wire_rvbc1::{decode_rvbc1, RVBC1_MAX_LEN, RVBC1_MIN_LEN};
use crate::hybrid_ratchet_v2_full_braid::wire_rvbm1::{decode_rvbm1, encode_rvbm1, Rvbm1};
use crate::hybrid_ratchet_v2_full_braid::wire_rvch1::{decode_rvch1, encode_rvch1, Rvch1};
use crate::hybrid_ratchet_v2_full_braid::wire_util::{
    expect_magic, read_array32, read_bytes, read_u32be, read_u8, reject_trailing, write_array32,
    write_bytes, write_u16be, write_u32be, write_u8, WireResult,
};

pub const RVBI1_MAGIC: &[u8; 8] = b"RVBI1\0\0\0";
pub const RVBI1_SCHEMA: u16 = 1;

pub const OP_SEND: u8 = 0;
pub const OP_RECEIVE: u8 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rvbi1 {
    pub op: u8,
    pub direction: u8,
    pub ch: Option<Rvch1>,
    pub expected_ch: Option<Rvch1>,
    pub object_digest: Option<[u8; 32]>,
    pub frame: Option<Vec<u8>>,
    pub mutation: Rvbm1,
}

pub fn encode_rvbi1(input: &Rvbi1) -> WireResult<Vec<u8>> {
    validate_rvbi1_contract(input)?;

    let mut out = Vec::new();
    write_bytes(&mut out, RVBI1_MAGIC);
    write_u16be(&mut out, RVBI1_SCHEMA);
    write_u8(&mut out, input.op);
    write_u8(&mut out, input.direction);
    write_u16be(&mut out, 0); // reserved0

    let ch_present = input.ch.is_some() as u8;
    write_u8(&mut out, ch_present);
    write_u8(&mut out, 0); // reserved1
    if let Some(ch) = &input.ch {
        write_bytes(&mut out, &encode_rvch1(ch));
    }

    let expected_present = input.expected_ch.is_some() as u8;
    write_u8(&mut out, expected_present);
    write_u8(&mut out, 0); // reserved2
    if let Some(ch) = &input.expected_ch {
        write_bytes(&mut out, &encode_rvch1(ch));
    }

    let od_present = input.object_digest.is_some() as u8;
    write_u8(&mut out, od_present);
    write_u8(&mut out, 0); // reserved3
    if let Some(d) = &input.object_digest {
        write_array32(&mut out, d);
    }

    if input.op == OP_RECEIVE {
        let frame = input.frame.as_ref().unwrap();
        write_u32be(&mut out, frame.len() as u32);
        write_bytes(&mut out, frame);
    }

    write_bytes(&mut out, &encode_rvbm1(&input.mutation)?);
    Ok(out)
}

pub fn decode_rvbi1(data: &[u8]) -> WireResult<Rvbi1> {
    expect_magic(data, RVBI1_MAGIC)?;
    let mut off = 8;
    let schema = crate::hybrid_ratchet_v2_full_braid::wire_util::read_u16be(data, &mut off)?;
    if schema != RVBI1_SCHEMA {
        return Err("rvbi1 bad schema".into());
    }
    let op = read_u8(data, &mut off)?;
    let direction = read_u8(data, &mut off)?;
    let reserved0 = crate::hybrid_ratchet_v2_full_braid::wire_util::read_u16be(data, &mut off)?;
    if reserved0 != 0 {
        return Err("rvbi1 reserved0".into());
    }

    let ch_present = read_u8(data, &mut off)?;
    let reserved1 = read_u8(data, &mut off)?;
    if reserved1 != 0 {
        return Err("rvbi1 reserved1".into());
    }
    let ch = if ch_present == 1 {
        Some(decode_rvch1(read_bytes(data, &mut off, 68)?)?)
    } else if ch_present == 0 {
        None
    } else {
        return Err("rvbi1 ch_present".into());
    };

    let expected_present = read_u8(data, &mut off)?;
    let reserved2 = read_u8(data, &mut off)?;
    if reserved2 != 0 {
        return Err("rvbi1 reserved2".into());
    }
    let expected_ch = if expected_present == 1 {
        Some(decode_rvch1(read_bytes(data, &mut off, 68)?)?)
    } else if expected_present == 0 {
        None
    } else {
        return Err("rvbi1 expected_ch_present".into());
    };

    let od_present = read_u8(data, &mut off)?;
    let reserved3 = read_u8(data, &mut off)?;
    if reserved3 != 0 {
        return Err("rvbi1 reserved3".into());
    }
    let object_digest = if od_present == 1 {
        Some(read_array32(data, &mut off)?)
    } else if od_present == 0 {
        None
    } else {
        return Err("rvbi1 object_digest_present".into());
    };

    let frame = if op == OP_RECEIVE {
        let frame_len = read_u32be(data, &mut off)? as usize;
        if frame_len == 0 {
            return Err("rvbi1 frame_len zero".into());
        }
        if !(RVBC1_MIN_LEN..=RVBC1_MAX_LEN).contains(&frame_len) {
            return Err("rvbi1 frame_len range".into());
        }
        let frame_bytes = read_bytes(data, &mut off, frame_len)?.to_vec();
        decode_rvbc1(&frame_bytes)?;
        Some(frame_bytes)
    } else {
        None
    };

    let mutation = decode_rvbm1(&data[off..])?;
    let mutation_len = encode_rvbm1(&mutation)?.len();
    off += mutation_len;
    reject_trailing(data, off)?;

    let input = Rvbi1 {
        op,
        direction,
        ch,
        expected_ch,
        object_digest,
        frame,
        mutation,
    };
    validate_rvbi1_contract(&input)?;
    Ok(input)
}

fn validate_rvbi1_contract(input: &Rvbi1) -> WireResult<()> {
    if input.op > OP_RECEIVE {
        return Err("rvbi1 op".into());
    }
    match input.op {
        OP_SEND => {
            if input.ch.is_some()
                || input.expected_ch.is_some()
                || input.object_digest.is_some()
                || input.frame.is_some()
            {
                return Err("rvbi1 send field contract".into());
            }
        }
        OP_RECEIVE => {
            if input.frame.is_none() {
                return Err("rvbi1 receive missing frame".into());
            }
            let needs_aead = input.mutation.needs_aead;
            if needs_aead == 1 {
                if input.ch.is_none() || input.object_digest.is_none() {
                    return Err("rvbi1 receive aead contract".into());
                }
            } else if input.ch.is_some() || input.object_digest.is_none() {
                return Err("rvbi1 receive no-aead contract".into());
            }
        }
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hybrid_ratchet_v2_full_braid::digest::binding_digest;
    use crate::hybrid_ratchet_v2_full_braid::wire_rvbc1::{encode_rvbc1, Rvbc1};

    fn sample_frame() -> Vec<u8> {
        let sid = [0x55u8; 32];
        let payload = vec![0u8; 32];
        let chunk = Rvbc1 {
            epoch: 1,
            chunk_type: 1,
            index: 0,
            payload,
            binding_digest: binding_digest(0, 1, 1, 0, &[0u8; 32], &sid),
        };
        encode_rvbc1(&chunk).unwrap()
    }

    #[test]
    fn send_roundtrip() {
        let input = Rvbi1 {
            op: OP_SEND,
            direction: 0,
            ch: None,
            expected_ch: None,
            object_digest: None,
            frame: None,
            mutation: Rvbm1::no_aead(),
        };
        let wire = encode_rvbi1(&input).unwrap();
        assert_eq!(decode_rvbi1(&wire).unwrap(), input);
    }

    #[test]
    fn receive_frame_len_zero_rejected() {
        let mut out = Vec::new();
        write_bytes(&mut out, RVBI1_MAGIC);
        write_u16be(&mut out, RVBI1_SCHEMA);
        write_u8(&mut out, OP_RECEIVE);
        write_u8(&mut out, 1);
        write_u16be(&mut out, 0);
        write_u8(&mut out, 0);
        write_u8(&mut out, 0);
        write_u8(&mut out, 0);
        write_u8(&mut out, 0);
        write_u8(&mut out, 1);
        write_u8(&mut out, 0);
        write_array32(&mut out, &[0x77; 32]);
        write_u32be(&mut out, 0); // frame_len=0
        write_bytes(&mut out, &encode_rvbm1(&Rvbm1::no_aead()).unwrap());
        assert!(decode_rvbi1(&out).is_err());
    }

    #[test]
    fn receive_valid_frame_roundtrip() {
        let frame = sample_frame();
        assert!(frame.len() >= RVBC1_MIN_LEN);
        let input = Rvbi1 {
            op: OP_RECEIVE,
            direction: 1,
            ch: None,
            expected_ch: None,
            object_digest: Some([0x88; 32]),
            frame: Some(frame),
            mutation: Rvbm1::no_aead(),
        };
        let wire = encode_rvbi1(&input).unwrap();
        assert_eq!(decode_rvbi1(&wire).unwrap(), input);
    }
}
