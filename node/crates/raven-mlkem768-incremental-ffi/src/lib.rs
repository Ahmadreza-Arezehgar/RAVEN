//! Lab-only C ABI for incremental ML-KEM-768.
//!
//! Every buffer is caller-owned. Each pointer is paired with an explicit
//! `usize` length that Raven checks at runtime before any fixed-size cast.
//! Mismatched lengths return [`RAVEN_MLKEM768_ERROR_INVALID_LENGTH`].
//! On error or caught panic, every non-null output is zeroed for
//! `min(provided_len, expected_len)` bytes (never past the caller buffer).
//!
//! **Release and App Store builds must not link this crate.**

#![forbid(unsafe_op_in_unsafe_fn)]

#[cfg(not(debug_assertions))]
compile_error!(
    "raven-mlkem768-incremental-ffi is lab-only and must not be linked in Release/App Store builds"
);

use core::ffi::c_int;
use core::ptr;
use raven_core::mlkem768_incremental::{
    self as mlkem, DkCompressed, EncapsState, COINS_LEN, CT1_LEN, CT2_LEN, DK_LEN, EK_VECTOR_LEN,
    HEADER_LEN, SEED_LEN, SS_LEN, STATE_LEN,
};
use std::panic::{catch_unwind, AssertUnwindSafe};

/// Operation completed successfully.
pub const RAVEN_MLKEM768_SUCCESS: c_int = 0;

/// At least one required pointer was null.
pub const RAVEN_MLKEM768_ERROR_NULL_POINTER: c_int = 1;

/// The supplied public-key material or encapsulation input was rejected.
pub const RAVEN_MLKEM768_ERROR_INVALID_INPUT: c_int = 2;

/// An internal panic was caught at the FFI boundary.
pub const RAVEN_MLKEM768_ERROR_PANIC: c_int = 3;

/// A buffer length did not match the normative fixed size.
pub const RAVEN_MLKEM768_ERROR_INVALID_LENGTH: c_int = 4;

#[no_mangle]
pub extern "C" fn raven_mlkem768_len_seed() -> usize {
    SEED_LEN
}
#[no_mangle]
pub extern "C" fn raven_mlkem768_len_coins() -> usize {
    COINS_LEN
}
#[no_mangle]
pub extern "C" fn raven_mlkem768_len_dk() -> usize {
    DK_LEN
}
#[no_mangle]
pub extern "C" fn raven_mlkem768_len_header() -> usize {
    HEADER_LEN
}
#[no_mangle]
pub extern "C" fn raven_mlkem768_len_ek_vector() -> usize {
    EK_VECTOR_LEN
}
#[no_mangle]
pub extern "C" fn raven_mlkem768_len_state() -> usize {
    STATE_LEN
}
#[no_mangle]
pub extern "C" fn raven_mlkem768_len_ct1() -> usize {
    CT1_LEN
}
#[no_mangle]
pub extern "C" fn raven_mlkem768_len_ct2() -> usize {
    CT2_LEN
}
#[no_mangle]
pub extern "C" fn raven_mlkem768_len_ss() -> usize {
    SS_LEN
}

#[derive(Clone, Copy)]
struct OutBuf {
    ptr: *mut u8,
    len: usize,
    expected: usize,
}

/// Zero `min(len, expected)` bytes when `ptr` is non-null (never past caller buffer).
unsafe fn zero_out(out: OutBuf) {
    if out.ptr.is_null() || out.len == 0 {
        return;
    }
    let n = out.len.min(out.expected);
    // SAFETY: caller supplied a writable region of `out.len` bytes.
    unsafe { ptr::write_bytes(out.ptr, 0, n) };
}

unsafe fn zero_outs(outs: &[OutBuf]) {
    for out in outs {
        // SAFETY: each entry follows the OutBuf contract used by entry points.
        unsafe { zero_out(*out) };
    }
}

fn lengths_ok(pairs: &[(usize, usize)]) -> bool {
    pairs.iter().all(|(got, expected)| *got == *expected)
}

/// Borrow a fixed-size input after null and length checks succeeded.
///
/// # Safety
///
/// `input` must point to `N` readable bytes for the duration of the borrow.
unsafe fn fixed_input<'a, const N: usize>(input: *const u8) -> &'a [u8; N] {
    // SAFETY: Null/length already validated by the public entry point.
    unsafe { &*input.cast::<[u8; N]>() }
}

/// Copy bytes to a caller-owned output buffer of matching length.
///
/// # Safety
///
/// `output` must point to `input.len()` writable bytes.
unsafe fn copy_output(input: &[u8], output: *mut u8) {
    unsafe { ptr::copy(input.as_ptr(), output, input.len()) };
}

/// Generate and split an incremental ML-KEM-768 key pair.
///
/// # Safety
///
/// Non-null pointers must address readable/writable buffers of the supplied
/// lengths for the duration of the call. Lengths must equal the normative sizes.
#[no_mangle]
pub unsafe extern "C" fn raven_mlkem768_keygen_split(
    seed: *const u8,
    seed_len: usize,
    dk_out: *mut u8,
    dk_out_len: usize,
    header_out: *mut u8,
    header_out_len: usize,
    vector_out: *mut u8,
    vector_out_len: usize,
) -> c_int {
    let outs = [
        OutBuf {
            ptr: dk_out,
            len: dk_out_len,
            expected: DK_LEN,
        },
        OutBuf {
            ptr: header_out,
            len: header_out_len,
            expected: HEADER_LEN,
        },
        OutBuf {
            ptr: vector_out,
            len: vector_out_len,
            expected: EK_VECTOR_LEN,
        },
    ];
    if seed.is_null() || dk_out.is_null() || header_out.is_null() || vector_out.is_null() {
        // SAFETY: zero only within provided lengths.
        unsafe { zero_outs(&outs) };
        return RAVEN_MLKEM768_ERROR_NULL_POINTER;
    }
    if !lengths_ok(&[
        (seed_len, SEED_LEN),
        (dk_out_len, DK_LEN),
        (header_out_len, HEADER_LEN),
        (vector_out_len, EK_VECTOR_LEN),
    ]) {
        unsafe { zero_outs(&outs) };
        return RAVEN_MLKEM768_ERROR_INVALID_LENGTH;
    }

    match catch_unwind(AssertUnwindSafe(|| {
        let (dk, header, vector) = {
            // SAFETY: null/length validated.
            let seed = unsafe { fixed_input::<SEED_LEN>(seed) };
            mlkem::keygen_split(seed)
        };
        // SAFETY: null/length validated for outputs.
        unsafe {
            copy_output(dk.as_ref(), dk_out);
            copy_output(&header, header_out);
            copy_output(&vector, vector_out);
        }
        RAVEN_MLKEM768_SUCCESS
    })) {
        Ok(RAVEN_MLKEM768_SUCCESS) => RAVEN_MLKEM768_SUCCESS,
        Ok(code) => {
            unsafe { zero_outs(&outs) };
            code
        }
        Err(_) => {
            unsafe { zero_outs(&outs) };
            RAVEN_MLKEM768_ERROR_PANIC
        }
    }
}

/// Validate an incremental ML-KEM-768 public-key split.
///
/// # Safety
///
/// Non-null pointers must address readable buffers of the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn raven_mlkem768_validate(
    header: *const u8,
    header_len: usize,
    vector: *const u8,
    vector_len: usize,
) -> c_int {
    if header.is_null() || vector.is_null() {
        return RAVEN_MLKEM768_ERROR_NULL_POINTER;
    }
    if !lengths_ok(&[(header_len, HEADER_LEN), (vector_len, EK_VECTOR_LEN)]) {
        return RAVEN_MLKEM768_ERROR_INVALID_LENGTH;
    }

    match catch_unwind(AssertUnwindSafe(|| {
        let result = unsafe {
            mlkem::validate(
                fixed_input::<HEADER_LEN>(header),
                fixed_input::<EK_VECTOR_LEN>(vector),
            )
        };
        match result {
            Ok(()) => RAVEN_MLKEM768_SUCCESS,
            Err(_) => RAVEN_MLKEM768_ERROR_INVALID_INPUT,
        }
    })) {
        Ok(code) => code,
        Err(_) => RAVEN_MLKEM768_ERROR_PANIC,
    }
}

/// Produce retained state, the first ciphertext chunk, and a shared secret.
///
/// # Safety
///
/// Non-null pointers must address readable/writable buffers of the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn raven_mlkem768_encaps1(
    header: *const u8,
    header_len: usize,
    coins: *const u8,
    coins_len: usize,
    state_out: *mut u8,
    state_out_len: usize,
    ct1_out: *mut u8,
    ct1_out_len: usize,
    ss_out: *mut u8,
    ss_out_len: usize,
) -> c_int {
    let outs = [
        OutBuf {
            ptr: state_out,
            len: state_out_len,
            expected: STATE_LEN,
        },
        OutBuf {
            ptr: ct1_out,
            len: ct1_out_len,
            expected: CT1_LEN,
        },
        OutBuf {
            ptr: ss_out,
            len: ss_out_len,
            expected: SS_LEN,
        },
    ];
    if header.is_null()
        || coins.is_null()
        || state_out.is_null()
        || ct1_out.is_null()
        || ss_out.is_null()
    {
        unsafe { zero_outs(&outs) };
        return RAVEN_MLKEM768_ERROR_NULL_POINTER;
    }
    if !lengths_ok(&[
        (header_len, HEADER_LEN),
        (coins_len, COINS_LEN),
        (state_out_len, STATE_LEN),
        (ct1_out_len, CT1_LEN),
        (ss_out_len, SS_LEN),
    ]) {
        unsafe { zero_outs(&outs) };
        return RAVEN_MLKEM768_ERROR_INVALID_LENGTH;
    }

    match catch_unwind(AssertUnwindSafe(|| {
        let result = {
            let (header, coins) = unsafe {
                (
                    fixed_input::<HEADER_LEN>(header),
                    fixed_input::<COINS_LEN>(coins),
                )
            };
            mlkem::encaps1(header, coins)
        };
        let (state, ct1, shared_secret) = match result {
            Ok(output) => output,
            Err(_) => return RAVEN_MLKEM768_ERROR_INVALID_INPUT,
        };
        unsafe {
            copy_output(state.as_ref(), state_out);
            copy_output(&ct1, ct1_out);
            copy_output(shared_secret.as_ref(), ss_out);
        }
        RAVEN_MLKEM768_SUCCESS
    })) {
        Ok(RAVEN_MLKEM768_SUCCESS) => RAVEN_MLKEM768_SUCCESS,
        Ok(code) => {
            unsafe { zero_outs(&outs) };
            code
        }
        Err(_) => {
            unsafe { zero_outs(&outs) };
            RAVEN_MLKEM768_ERROR_PANIC
        }
    }
}

/// Validate the public-key split and produce the second ciphertext chunk.
///
/// # Safety
///
/// Non-null pointers must address readable/writable buffers of the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn raven_mlkem768_encaps2(
    state: *const u8,
    state_len: usize,
    header: *const u8,
    header_len: usize,
    vector: *const u8,
    vector_len: usize,
    ct2_out: *mut u8,
    ct2_out_len: usize,
) -> c_int {
    let outs = [OutBuf {
        ptr: ct2_out,
        len: ct2_out_len,
        expected: CT2_LEN,
    }];
    if state.is_null() || header.is_null() || vector.is_null() || ct2_out.is_null() {
        unsafe { zero_outs(&outs) };
        return RAVEN_MLKEM768_ERROR_NULL_POINTER;
    }
    if !lengths_ok(&[
        (state_len, STATE_LEN),
        (header_len, HEADER_LEN),
        (vector_len, EK_VECTOR_LEN),
        (ct2_out_len, CT2_LEN),
    ]) {
        unsafe { zero_outs(&outs) };
        return RAVEN_MLKEM768_ERROR_INVALID_LENGTH;
    }

    match catch_unwind(AssertUnwindSafe(|| {
        let result = {
            let (state, header, vector) = unsafe {
                (
                    fixed_input::<STATE_LEN>(state),
                    fixed_input::<HEADER_LEN>(header),
                    fixed_input::<EK_VECTOR_LEN>(vector),
                )
            };
            let state = EncapsState::from_bytes(state);
            mlkem::encaps2(&state, header, vector)
        };
        let ct2 = match result {
            Ok(ct2) => ct2,
            Err(_) => return RAVEN_MLKEM768_ERROR_INVALID_INPUT,
        };
        unsafe { copy_output(&ct2, ct2_out) };
        RAVEN_MLKEM768_SUCCESS
    })) {
        Ok(RAVEN_MLKEM768_SUCCESS) => RAVEN_MLKEM768_SUCCESS,
        Ok(code) => {
            unsafe { zero_outs(&outs) };
            code
        }
        Err(_) => {
            unsafe { zero_outs(&outs) };
            RAVEN_MLKEM768_ERROR_PANIC
        }
    }
}

/// Decapsulate two incremental ML-KEM-768 ciphertext chunks.
///
/// ML-KEM implicit rejection means any fixed-size ciphertext returns a secret;
/// upstream AEAD/protocol success is what authenticates it.
///
/// # Safety
///
/// Non-null pointers must address readable/writable buffers of the supplied lengths.
#[no_mangle]
pub unsafe extern "C" fn raven_mlkem768_decaps(
    dk: *const u8,
    dk_len: usize,
    ct1: *const u8,
    ct1_len: usize,
    ct2: *const u8,
    ct2_len: usize,
    ss_out: *mut u8,
    ss_out_len: usize,
) -> c_int {
    let outs = [OutBuf {
        ptr: ss_out,
        len: ss_out_len,
        expected: SS_LEN,
    }];
    if dk.is_null() || ct1.is_null() || ct2.is_null() || ss_out.is_null() {
        unsafe { zero_outs(&outs) };
        return RAVEN_MLKEM768_ERROR_NULL_POINTER;
    }
    if !lengths_ok(&[
        (dk_len, DK_LEN),
        (ct1_len, CT1_LEN),
        (ct2_len, CT2_LEN),
        (ss_out_len, SS_LEN),
    ]) {
        unsafe { zero_outs(&outs) };
        return RAVEN_MLKEM768_ERROR_INVALID_LENGTH;
    }

    match catch_unwind(AssertUnwindSafe(|| {
        let shared_secret = {
            let (dk, ct1, ct2) = unsafe {
                (
                    fixed_input::<DK_LEN>(dk),
                    fixed_input::<CT1_LEN>(ct1),
                    fixed_input::<CT2_LEN>(ct2),
                )
            };
            let dk = DkCompressed::from_bytes(dk);
            mlkem::decaps(&dk, ct1, ct2)
        };
        unsafe { copy_output(shared_secret.as_ref(), ss_out) };
        RAVEN_MLKEM768_SUCCESS
    })) {
        Ok(RAVEN_MLKEM768_SUCCESS) => RAVEN_MLKEM768_SUCCESS,
        Ok(code) => {
            unsafe { zero_outs(&outs) };
            code
        }
        Err(_) => {
            unsafe { zero_outs(&outs) };
            RAVEN_MLKEM768_ERROR_PANIC
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr::{null, null_mut};

    #[test]
    fn exported_length_accessors_match_raven_core() {
        assert_eq!(raven_mlkem768_len_seed(), SEED_LEN);
        assert_eq!(raven_mlkem768_len_coins(), COINS_LEN);
        assert_eq!(raven_mlkem768_len_dk(), DK_LEN);
        assert_eq!(raven_mlkem768_len_header(), HEADER_LEN);
        assert_eq!(raven_mlkem768_len_ek_vector(), EK_VECTOR_LEN);
        assert_eq!(raven_mlkem768_len_state(), STATE_LEN);
        assert_eq!(raven_mlkem768_len_ct1(), CT1_LEN);
        assert_eq!(raven_mlkem768_len_ct2(), CT2_LEN);
        assert_eq!(raven_mlkem768_len_ss(), SS_LEN);

        let header = include_str!("../include/raven_mlkem768_incremental.h");
        for (name, value) in [
            ("RAVEN_MLKEM768_SEED_LEN", SEED_LEN),
            ("RAVEN_MLKEM768_COINS_LEN", COINS_LEN),
            ("RAVEN_MLKEM768_DK_LEN", DK_LEN),
            ("RAVEN_MLKEM768_HEADER_LEN", HEADER_LEN),
            ("RAVEN_MLKEM768_EK_VECTOR_LEN", EK_VECTOR_LEN),
            ("RAVEN_MLKEM768_STATE_LEN", STATE_LEN),
            ("RAVEN_MLKEM768_CT1_LEN", CT1_LEN),
            ("RAVEN_MLKEM768_CT2_LEN", CT2_LEN),
            ("RAVEN_MLKEM768_SS_LEN", SS_LEN),
        ] {
            let needle = format!("#define {name} {value}");
            assert!(
                header.contains(&needle),
                "C header missing `{needle}`"
            );
        }
    }

    #[test]
    fn c_abi_roundtrip_uses_caller_owned_buffers() {
        let seed: [u8; 64] = core::array::from_fn(|index| index as u8);
        let coins = [7u8; 32];
        let mut dk = [0u8; 2400];
        let mut header = [0u8; 64];
        let mut vector = [0u8; 1152];
        let mut state = [0u8; 2080];
        let mut ct1 = [0u8; 960];
        let mut ct2 = [0u8; 128];
        let mut encapsulated_ss = [0u8; 32];
        let mut decapsulated_ss = [0u8; 32];

        unsafe {
            assert_eq!(
                raven_mlkem768_keygen_split(
                    seed.as_ptr(),
                    seed.len(),
                    dk.as_mut_ptr(),
                    dk.len(),
                    header.as_mut_ptr(),
                    header.len(),
                    vector.as_mut_ptr(),
                    vector.len(),
                ),
                RAVEN_MLKEM768_SUCCESS
            );
            assert_eq!(
                raven_mlkem768_validate(header.as_ptr(), header.len(), vector.as_ptr(), vector.len()),
                RAVEN_MLKEM768_SUCCESS
            );
            assert_eq!(
                raven_mlkem768_encaps1(
                    header.as_ptr(),
                    header.len(),
                    coins.as_ptr(),
                    coins.len(),
                    state.as_mut_ptr(),
                    state.len(),
                    ct1.as_mut_ptr(),
                    ct1.len(),
                    encapsulated_ss.as_mut_ptr(),
                    encapsulated_ss.len(),
                ),
                RAVEN_MLKEM768_SUCCESS
            );
            assert_eq!(
                raven_mlkem768_encaps2(
                    state.as_ptr(),
                    state.len(),
                    header.as_ptr(),
                    header.len(),
                    vector.as_ptr(),
                    vector.len(),
                    ct2.as_mut_ptr(),
                    ct2.len(),
                ),
                RAVEN_MLKEM768_SUCCESS
            );
            assert_eq!(
                raven_mlkem768_decaps(
                    dk.as_ptr(),
                    dk.len(),
                    ct1.as_ptr(),
                    ct1.len(),
                    ct2.as_ptr(),
                    ct2.len(),
                    decapsulated_ss.as_mut_ptr(),
                    decapsulated_ss.len(),
                ),
                RAVEN_MLKEM768_SUCCESS
            );
        }
        assert_eq!(encapsulated_ss, decapsulated_ss);
    }

    #[test]
    fn each_c_abi_entry_rejects_a_null_pointer() {
        unsafe {
            assert_eq!(
                raven_mlkem768_keygen_split(
                    null(),
                    SEED_LEN,
                    null_mut(),
                    DK_LEN,
                    null_mut(),
                    HEADER_LEN,
                    null_mut(),
                    EK_VECTOR_LEN,
                ),
                RAVEN_MLKEM768_ERROR_NULL_POINTER
            );
            assert_eq!(
                raven_mlkem768_validate(null(), HEADER_LEN, null(), EK_VECTOR_LEN),
                RAVEN_MLKEM768_ERROR_NULL_POINTER
            );
            assert_eq!(
                raven_mlkem768_encaps1(
                    null(),
                    HEADER_LEN,
                    null(),
                    COINS_LEN,
                    null_mut(),
                    STATE_LEN,
                    null_mut(),
                    CT1_LEN,
                    null_mut(),
                    SS_LEN,
                ),
                RAVEN_MLKEM768_ERROR_NULL_POINTER
            );
            assert_eq!(
                raven_mlkem768_encaps2(
                    null(),
                    STATE_LEN,
                    null(),
                    HEADER_LEN,
                    null(),
                    EK_VECTOR_LEN,
                    null_mut(),
                    CT2_LEN,
                ),
                RAVEN_MLKEM768_ERROR_NULL_POINTER
            );
            assert_eq!(
                raven_mlkem768_decaps(
                    null(),
                    DK_LEN,
                    null(),
                    CT1_LEN,
                    null(),
                    CT2_LEN,
                    null_mut(),
                    SS_LEN,
                ),
                RAVEN_MLKEM768_ERROR_NULL_POINTER
            );
        }
    }

    #[test]
    fn short_and_long_lengths_are_rejected_and_outputs_zeroed() {
        let seed: [u8; SEED_LEN] = [1; SEED_LEN];
        let mut dk = [0xAAu8; DK_LEN];
        let mut header = [0xBBu8; HEADER_LEN];
        let mut vector = [0xCCu8; EK_VECTOR_LEN];

        unsafe {
            assert_eq!(
                raven_mlkem768_keygen_split(
                    seed.as_ptr(),
                    SEED_LEN - 1,
                    dk.as_mut_ptr(),
                    DK_LEN,
                    header.as_mut_ptr(),
                    HEADER_LEN,
                    vector.as_mut_ptr(),
                    EK_VECTOR_LEN,
                ),
                RAVEN_MLKEM768_ERROR_INVALID_LENGTH
            );
        }
        assert!(dk.iter().all(|&b| b == 0));
        assert!(header.iter().all(|&b| b == 0));
        assert!(vector.iter().all(|&b| b == 0));

        let mut dk_long = [0xAAu8; DK_LEN + 8];
        header.fill(0xBB);
        vector.fill(0xCC);
        unsafe {
            assert_eq!(
                raven_mlkem768_keygen_split(
                    seed.as_ptr(),
                    SEED_LEN,
                    dk_long.as_mut_ptr(),
                    DK_LEN + 8,
                    header.as_mut_ptr(),
                    HEADER_LEN,
                    vector.as_mut_ptr(),
                    EK_VECTOR_LEN,
                ),
                RAVEN_MLKEM768_ERROR_INVALID_LENGTH
            );
        }
        // Long length: zero only expected DK_LEN bytes; trailing caller bytes untouched.
        assert!(dk_long[..DK_LEN].iter().all(|&b| b == 0));
        assert!(dk_long[DK_LEN..].iter().all(|&b| b == 0xAA));
        assert!(header.iter().all(|&b| b == 0));
        assert!(vector.iter().all(|&b| b == 0));

        let header_in = [0u8; HEADER_LEN];
        let vector_in = [0u8; EK_VECTOR_LEN];
        unsafe {
            assert_eq!(
                raven_mlkem768_validate(
                    header_in.as_ptr(),
                    HEADER_LEN + 1,
                    vector_in.as_ptr(),
                    EK_VECTOR_LEN,
                ),
                RAVEN_MLKEM768_ERROR_INVALID_LENGTH
            );
            assert_eq!(
                raven_mlkem768_validate(
                    header_in.as_ptr(),
                    HEADER_LEN,
                    vector_in.as_ptr(),
                    EK_VECTOR_LEN - 1,
                ),
                RAVEN_MLKEM768_ERROR_INVALID_LENGTH
            );
        }

        let coins = [7u8; COINS_LEN];
        let mut state = [0xDDu8; STATE_LEN];
        let mut ct1 = [0xEEu8; CT1_LEN];
        let mut ss = [0xFFu8; SS_LEN];
        unsafe {
            assert_eq!(
                raven_mlkem768_encaps1(
                    header_in.as_ptr(),
                    HEADER_LEN,
                    coins.as_ptr(),
                    COINS_LEN - 1,
                    state.as_mut_ptr(),
                    STATE_LEN,
                    ct1.as_mut_ptr(),
                    CT1_LEN,
                    ss.as_mut_ptr(),
                    SS_LEN,
                ),
                RAVEN_MLKEM768_ERROR_INVALID_LENGTH
            );
        }
        assert!(state.iter().all(|&b| b == 0));
        assert!(ct1.iter().all(|&b| b == 0));
        assert!(ss.iter().all(|&b| b == 0));

        let state_in = [0u8; STATE_LEN];
        let mut ct2 = [0x11u8; CT2_LEN];
        unsafe {
            assert_eq!(
                raven_mlkem768_encaps2(
                    state_in.as_ptr(),
                    STATE_LEN,
                    header_in.as_ptr(),
                    HEADER_LEN,
                    vector_in.as_ptr(),
                    EK_VECTOR_LEN,
                    ct2.as_mut_ptr(),
                    CT2_LEN + 8,
                ),
                RAVEN_MLKEM768_ERROR_INVALID_LENGTH
            );
        }
        assert!(ct2[..CT2_LEN].iter().all(|&b| b == 0));

        let dk_in = [0u8; DK_LEN];
        let ct1_in = [0u8; CT1_LEN];
        let ct2_in = [0u8; CT2_LEN];
        ss.fill(0xFF);
        unsafe {
            assert_eq!(
                raven_mlkem768_decaps(
                    dk_in.as_ptr(),
                    DK_LEN,
                    ct1_in.as_ptr(),
                    CT1_LEN,
                    ct2_in.as_ptr(),
                    CT2_LEN,
                    ss.as_mut_ptr(),
                    SS_LEN - 1,
                ),
                RAVEN_MLKEM768_ERROR_INVALID_LENGTH
            );
        }
        assert!(ss[..SS_LEN - 1].iter().all(|&b| b == 0));
    }

    #[test]
    fn encaps2_invalid_input_zeroes_ct2_output() {
        let seed: [u8; SEED_LEN] = core::array::from_fn(|i| i as u8);
        let coins = [7u8; COINS_LEN];
        let mut dk = [0u8; DK_LEN];
        let mut header = [0u8; HEADER_LEN];
        let mut vector = [0u8; EK_VECTOR_LEN];
        let mut state = [0u8; STATE_LEN];
        let mut ct1 = [0u8; CT1_LEN];
        let mut ss = [0u8; SS_LEN];
        let mut ct2 = [0x5Au8; CT2_LEN];

        unsafe {
            assert_eq!(
                raven_mlkem768_keygen_split(
                    seed.as_ptr(),
                    SEED_LEN,
                    dk.as_mut_ptr(),
                    DK_LEN,
                    header.as_mut_ptr(),
                    HEADER_LEN,
                    vector.as_mut_ptr(),
                    EK_VECTOR_LEN,
                ),
                RAVEN_MLKEM768_SUCCESS
            );
            assert_eq!(
                raven_mlkem768_encaps1(
                    header.as_ptr(),
                    HEADER_LEN,
                    coins.as_ptr(),
                    COINS_LEN,
                    state.as_mut_ptr(),
                    STATE_LEN,
                    ct1.as_mut_ptr(),
                    CT1_LEN,
                    ss.as_mut_ptr(),
                    SS_LEN,
                ),
                RAVEN_MLKEM768_SUCCESS
            );
            vector[0] ^= 1;
            assert_eq!(
                raven_mlkem768_encaps2(
                    state.as_ptr(),
                    STATE_LEN,
                    header.as_ptr(),
                    HEADER_LEN,
                    vector.as_ptr(),
                    EK_VECTOR_LEN,
                    ct2.as_mut_ptr(),
                    CT2_LEN,
                ),
                RAVEN_MLKEM768_ERROR_INVALID_INPUT
            );
        }
        assert!(ct2.iter().all(|&b| b == 0));
    }
}
