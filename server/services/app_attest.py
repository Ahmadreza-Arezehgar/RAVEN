"""
Apple App Attest — server-side attestation verification.

🔴 v1.8 (2026-05-21) — feature #3: App Attest device enrolment.

Verifies a DCAppAttestService attestation object per Apple's
"Validating Apps That Connect to Your Server". A passing attestation
proves the request came from a genuine, unmodified RAVEN build running
on real Apple hardware — the private key lives in the Secure Enclave
and never leaves the device. The caller stores the returned public key
+ key id so future requests can be checked with App Attest assertions.

This module is verification ONLY — no I/O, no DB, no networking. The
`root_ca_pem` argument is injectable so tests can drive the entire
verification path with a synthetic certificate chain; production uses
the pinned Apple App Attest Root CA below.
"""
import hashlib
import hmac
from dataclasses import dataclass
from typing import Optional

import cbor2
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

# Pinned trust anchor — Apple App Attestation Root CA. Source:
# https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
APPLE_APP_ATTEST_ROOT_CA = """-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----
"""

# OID of the nonce extension Apple embeds in the attestation leaf cert.
_NONCE_OID = "1.2.840.113635.100.8.2"

# App Attest AAGUIDs (16 bytes) — production vs the development sandbox.
_AAGUID_PROD = b"appattest\x00\x00\x00\x00\x00\x00\x00"
_AAGUID_DEV = b"appattestdevelop"


class AttestationError(Exception):
    """Raised when an attestation object fails any verification step."""


@dataclass
class VerifiedAttestation:
    """The trusted outcome of `verify_attestation`."""
    key_id: bytes            # SHA-256 of the attested public key
    public_key_pem: str      # the device's hardware-backed public key (PEM)
    environment: str         # "production" | "development"
    receipt: bytes           # Apple App Attest receipt (opaque; store as-is)
    sign_count: int          # always 0 for a fresh attestation


def _verify_cert_signed_by(cert: x509.Certificate, issuer: x509.Certificate) -> None:
    """Raise AttestationError unless `cert` was signed by `issuer`."""
    issuer_key = issuer.public_key()
    if not isinstance(issuer_key, ec.EllipticCurvePublicKey):
        raise AttestationError("certificate issuer key is not EC")
    try:
        issuer_key.verify(
            cert.signature,
            cert.tbs_certificate_bytes,
            ec.ECDSA(cert.signature_hash_algorithm),
        )
    except InvalidSignature:
        raise AttestationError("certificate chain signature is invalid")
    except Exception as e:  # malformed cert / missing hash algorithm / …
        raise AttestationError(f"certificate chain verification failed: {e}")


def _extract_nonce(leaf: x509.Certificate) -> bytes:
    """Pull the 32-byte nonce from the leaf cert's App Attest extension.
    Apple DER-encodes it as `SEQUENCE { [1] { OCTET STRING nonce } }`,
    i.e. exactly `30 24 A1 22 04 20 <32 bytes>`."""
    try:
        ext = leaf.extensions.get_extension_for_oid(
            x509.ObjectIdentifier(_NONCE_OID))
    except x509.ExtensionNotFound:
        raise AttestationError("attestation leaf is missing the nonce extension")
    der = bytes(ext.value.value)  # raw DER of an UnrecognizedExtension
    # Some toolchains hand the value back still wrapped in its outer
    # OCTET STRING — strip one such wrapper if present. Parsing is
    # fail-closed: a wrong extraction just fails the nonce compare.
    if len(der) >= 2 and der[0] == 0x04 and der[1] == len(der) - 2:
        der = der[2:]
    # Expect SEQUENCE { [1] { OCTET STRING <32-byte nonce> } }:
    #   30 24 A1 22 04 20 <32 bytes>
    if (len(der) != 38 or der[0] != 0x30 or der[2] != 0xA1
            or der[4] != 0x04 or der[5] != 0x20):
        raise AttestationError("attestation nonce extension is malformed")
    return der[6:38]


def _parse_auth_data(auth_data: bytes):
    """Decompose the attestation `authData`. Returns
    (rp_id_hash, sign_count, aaguid, credential_id)."""
    if len(auth_data) < 55:
        raise AttestationError("authData is too short")
    rp_id_hash = auth_data[0:32]
    sign_count = int.from_bytes(auth_data[33:37], "big")
    aaguid = auth_data[37:53]
    cred_id_len = int.from_bytes(auth_data[53:55], "big")
    cred_id = auth_data[55:55 + cred_id_len]
    if len(cred_id) != cred_id_len:
        raise AttestationError("authData credentialId is truncated")
    return rp_id_hash, sign_count, aaguid, cred_id


def verify_attestation(
    *,
    key_id: bytes,
    attestation: bytes,
    challenge: bytes,
    team_id: str,
    bundle_id: str,
    root_ca_pem: Optional[str] = None,
    allow_development: bool = True,
) -> VerifiedAttestation:
    """Verify an Apple App Attest attestation object.

    Args:
      key_id:      the App Attest key id the client generated (raw bytes).
      attestation: the CBOR attestation object returned by `attestKey`.
      challenge:   the exact challenge bytes the server issued.
      team_id / bundle_id: this app's Apple Team ID and bundle id.
      root_ca_pem: trust anchor; defaults to the pinned Apple root.
      allow_development: accept sandbox ("development") attestations.

    Returns a `VerifiedAttestation` on success; raises
    `AttestationError` on ANY failure (fails closed).
    """
    root_pem = root_ca_pem or APPLE_APP_ATTEST_ROOT_CA

    # ---- 1. CBOR-decode the attestation object ----
    try:
        obj = cbor2.loads(attestation)
    except Exception:
        raise AttestationError("attestation is not valid CBOR")
    if not isinstance(obj, dict):
        raise AttestationError("attestation is not a CBOR map")
    if obj.get("fmt") != "apple-appattest":
        raise AttestationError("unexpected attestation format")
    att_stmt = obj.get("attStmt")
    auth_data = obj.get("authData")
    if not isinstance(att_stmt, dict):
        raise AttestationError("attestation attStmt is missing")
    if not isinstance(auth_data, (bytes, bytearray)):
        raise AttestationError("attestation authData is missing")
    auth_data = bytes(auth_data)
    x5c = att_stmt.get("x5c")
    if not isinstance(x5c, list) or len(x5c) < 2:
        raise AttestationError("x5c must contain a leaf + intermediate cert")
    receipt = att_stmt.get("receipt") or b""
    if not isinstance(receipt, (bytes, bytearray)):
        receipt = b""

    # ---- 2. Parse the certificates ----
    try:
        leaf = x509.load_der_x509_certificate(bytes(x5c[0]))
        intermediate = x509.load_der_x509_certificate(bytes(x5c[1]))
        root = x509.load_pem_x509_certificate(root_pem.encode())
    except Exception:
        raise AttestationError("could not parse attestation certificates")

    # ---- 3. Verify the chain: leaf <- intermediate <- pinned root ----
    _verify_cert_signed_by(leaf, intermediate)
    _verify_cert_signed_by(intermediate, root)

    # ---- 4. Recompute the expected nonce ----
    client_data_hash = hashlib.sha256(challenge).digest()
    expected_nonce = hashlib.sha256(auth_data + client_data_hash).digest()

    # ---- 5. The leaf cert must carry exactly that nonce ----
    if not hmac.compare_digest(_extract_nonce(leaf), expected_nonce):
        raise AttestationError("attestation nonce does not match the challenge")

    # ---- 6. keyId must be SHA-256 of the attested public key ----
    leaf_key = leaf.public_key()
    if not isinstance(leaf_key, ec.EllipticCurvePublicKey):
        raise AttestationError("attested key is not an EC public key")
    pub_point = leaf_key.public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint,
    )
    if not hmac.compare_digest(hashlib.sha256(pub_point).digest(), key_id):
        raise AttestationError("keyId does not match the attested public key")

    # ---- 7-10. authData checks ----
    rp_id_hash, sign_count, aaguid, cred_id = _parse_auth_data(auth_data)

    expected_rp = hashlib.sha256(f"{team_id}.{bundle_id}".encode()).digest()
    if not hmac.compare_digest(rp_id_hash, expected_rp):
        raise AttestationError("rpId hash mismatch — attestation is for a different app")

    if sign_count != 0:
        raise AttestationError("a fresh attestation must have signCount 0")

    if aaguid == _AAGUID_PROD:
        environment = "production"
    elif aaguid == _AAGUID_DEV:
        if not allow_development:
            raise AttestationError("development attestations are not accepted")
        environment = "development"
    else:
        raise AttestationError("unrecognized App Attest environment (aaguid)")

    if not hmac.compare_digest(cred_id, key_id):
        raise AttestationError("authData credentialId does not match keyId")

    # ---- 11. Trusted ----
    public_key_pem = leaf_key.public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    ).decode()
    return VerifiedAttestation(
        key_id=key_id,
        public_key_pem=public_key_pem,
        environment=environment,
        receipt=bytes(receipt),
        sign_count=sign_count,
    )
