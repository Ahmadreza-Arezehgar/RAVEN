//! Shared wire read/write helpers for Full Braid codecs (design §4).

pub type WireResult<T> = Result<T, String>;

pub fn reject_trailing(data: &[u8], consumed: usize) -> WireResult<()> {
    if consumed != data.len() {
        return Err("trailing bytes".into());
    }
    Ok(())
}

pub fn expect_magic(data: &[u8], magic: &[u8; 8]) -> WireResult<()> {
    if data.len() < 8 || &data[..8] != magic {
        return Err("bad magic".into());
    }
    Ok(())
}

pub fn read_u8(data: &[u8], off: &mut usize) -> WireResult<u8> {
    if *off >= data.len() {
        return Err("truncated".into());
    }
    let v = data[*off];
    *off += 1;
    Ok(v)
}

pub fn read_u16be(data: &[u8], off: &mut usize) -> WireResult<u16> {
    let end = off.checked_add(2).ok_or_else(|| "overflow".to_string())?;
    if end > data.len() {
        return Err("truncated".into());
    }
    let v = u16::from_be_bytes(data[*off..end].try_into().unwrap());
    *off = end;
    Ok(v)
}

pub fn read_u32be(data: &[u8], off: &mut usize) -> WireResult<u32> {
    let end = off.checked_add(4).ok_or_else(|| "overflow".to_string())?;
    if end > data.len() {
        return Err("truncated".into());
    }
    let v = u32::from_be_bytes(data[*off..end].try_into().unwrap());
    *off = end;
    Ok(v)
}

pub fn read_u64be(data: &[u8], off: &mut usize) -> WireResult<u64> {
    let end = off.checked_add(8).ok_or_else(|| "overflow".to_string())?;
    if end > data.len() {
        return Err("truncated".into());
    }
    let v = u64::from_be_bytes(data[*off..end].try_into().unwrap());
    *off = end;
    Ok(v)
}

pub fn read_bytes<'a>(data: &'a [u8], off: &mut usize, len: usize) -> WireResult<&'a [u8]> {
    let end = off.checked_add(len).ok_or_else(|| "overflow".to_string())?;
    if end > data.len() {
        return Err("truncated".into());
    }
    let slice = &data[*off..end];
    *off = end;
    Ok(slice)
}

pub fn read_array32(data: &[u8], off: &mut usize) -> WireResult<[u8; 32]> {
    let slice = read_bytes(data, off, 32)?;
    let mut out = [0u8; 32];
    out.copy_from_slice(slice);
    Ok(out)
}

pub fn write_u8(out: &mut Vec<u8>, v: u8) {
    out.push(v);
}

pub fn write_u16be(out: &mut Vec<u8>, v: u16) {
    out.extend_from_slice(&v.to_be_bytes());
}

pub fn write_u32be(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_be_bytes());
}

pub fn write_u64be(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_be_bytes());
}

pub fn write_bytes(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(bytes);
}

pub fn write_array32(out: &mut Vec<u8>, bytes: &[u8; 32]) {
    out.extend_from_slice(bytes);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_primitives() {
        let mut buf = Vec::new();
        write_u8(&mut buf, 0xAB);
        write_u16be(&mut buf, 0x1234);
        write_u32be(&mut buf, 0xDEADBEEF);
        write_u64be(&mut buf, 0x0123_4567_89AB_CDEF);
        let mut off = 0;
        assert_eq!(read_u8(&buf, &mut off).unwrap(), 0xAB);
        assert_eq!(read_u16be(&buf, &mut off).unwrap(), 0x1234);
        assert_eq!(read_u32be(&buf, &mut off).unwrap(), 0xDEADBEEF);
        assert_eq!(read_u64be(&buf, &mut off).unwrap(), 0x0123_4567_89AB_CDEF);
        reject_trailing(&buf, off).unwrap();
    }

    #[test]
    fn reject_trailing_bytes() {
        assert!(reject_trailing(&[1, 2, 3], 1).is_err());
    }
}
