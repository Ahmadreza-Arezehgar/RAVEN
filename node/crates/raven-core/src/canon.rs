//! Length-prefix helpers matching `protocol/reference/raven_protocol/_canon.py`.

pub const LP_MAX_LEN: usize = 0xFFFF;

pub fn lp(b: &[u8]) -> Result<Vec<u8>, String> {
    if b.len() > LP_MAX_LEN {
        return Err("lp field too long".into());
    }
    let mut out = Vec::with_capacity(2 + b.len());
    out.extend_from_slice(&(b.len() as u16).to_be_bytes());
    out.extend_from_slice(b);
    Ok(out)
}

pub fn u64_be(n: u64) -> [u8; 8] {
    n.to_be_bytes()
}
