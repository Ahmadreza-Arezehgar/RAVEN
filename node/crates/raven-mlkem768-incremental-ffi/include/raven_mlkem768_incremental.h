#ifndef RAVEN_MLKEM768_INCREMENTAL_H
#define RAVEN_MLKEM768_INCREMENTAL_H

#include <stddef.h>
#include <stdint.h>

/*
 * LAB ONLY. Release and App Store builds must not link this crate.
 *
 * Length-explicit ABI: every buffer is pointer + size_t length. Raven checks
 * lengths at runtime and returns RAVEN_MLKEM768_ERROR_INVALID_LENGTH on
 * mismatch before any fixed-size cast. On error or caught panic, non-null
 * outputs are zeroed for min(provided_len, expected_len) bytes.
 *
 * Distinct output parameters must not overlap if all outputs are to be kept.
 * The ABI never transfers heap ownership of secret material.
 */

#ifdef __cplusplus
extern "C" {
#endif

/* Canonical fixed buffer lengths (§9.4). Keep in sync with raven-core. */
#define RAVEN_MLKEM768_SEED_LEN 64
#define RAVEN_MLKEM768_COINS_LEN 32
#define RAVEN_MLKEM768_DK_LEN 2400
#define RAVEN_MLKEM768_HEADER_LEN 64
#define RAVEN_MLKEM768_EK_VECTOR_LEN 1152
#define RAVEN_MLKEM768_STATE_LEN 2080
#define RAVEN_MLKEM768_CT1_LEN 960
#define RAVEN_MLKEM768_CT2_LEN 128
#define RAVEN_MLKEM768_SS_LEN 32

enum {
    RAVEN_MLKEM768_SUCCESS = 0,
    RAVEN_MLKEM768_ERROR_NULL_POINTER = 1,
    RAVEN_MLKEM768_ERROR_INVALID_INPUT = 2,
    RAVEN_MLKEM768_ERROR_PANIC = 3,
    RAVEN_MLKEM768_ERROR_INVALID_LENGTH = 4
};

/* Runtime accessors returning the same values as the macros above. */
size_t raven_mlkem768_len_seed(void);
size_t raven_mlkem768_len_coins(void);
size_t raven_mlkem768_len_dk(void);
size_t raven_mlkem768_len_header(void);
size_t raven_mlkem768_len_ek_vector(void);
size_t raven_mlkem768_len_state(void);
size_t raven_mlkem768_len_ct1(void);
size_t raven_mlkem768_len_ct2(void);
size_t raven_mlkem768_len_ss(void);

int raven_mlkem768_keygen_split(
    const uint8_t *seed,
    size_t seed_len,
    uint8_t *dk_out,
    size_t dk_out_len,
    uint8_t *header_out,
    size_t header_out_len,
    uint8_t *vector_out,
    size_t vector_out_len);

int raven_mlkem768_validate(
    const uint8_t *header,
    size_t header_len,
    const uint8_t *vector,
    size_t vector_len);

int raven_mlkem768_encaps1(
    const uint8_t *header,
    size_t header_len,
    const uint8_t *coins,
    size_t coins_len,
    uint8_t *state_out,
    size_t state_out_len,
    uint8_t *ct1_out,
    size_t ct1_out_len,
    uint8_t *ss_out,
    size_t ss_out_len);

int raven_mlkem768_encaps2(
    const uint8_t *state,
    size_t state_len,
    const uint8_t *header,
    size_t header_len,
    const uint8_t *vector,
    size_t vector_len,
    uint8_t *ct2_out,
    size_t ct2_out_len);

int raven_mlkem768_decaps(
    const uint8_t *dk,
    size_t dk_len,
    const uint8_t *ct1,
    size_t ct1_len,
    const uint8_t *ct2,
    size_t ct2_len,
    uint8_t *ss_out,
    size_t ss_out_len);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* RAVEN_MLKEM768_INCREMENTAL_H */
