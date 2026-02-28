# Security Policy

## Reporting a Vulnerability

We take security seriously at RAVEN. If you discover a security vulnerability, please report it responsibly.

### How to Report

- **Email**: security@hybridmessenger.com
- **Subject**: `[SECURITY] Brief description`
- **Do NOT** open a public GitHub issue for security vulnerabilities

### What to Include

1. Description of the vulnerability
2. Steps to reproduce
3. Potential impact
4. Suggested fix (if any)

### Response Timeline

| Action | Timeline |
|--------|----------|
| Acknowledgment | Within 48 hours |
| Initial Assessment | Within 5 business days |
| Fix & Disclosure | Within 30 days |

### Scope

The following are in scope:
- End-to-end encryption implementation (`MeshCryptoService`)
- Mesh networking protocol (`BLEMeshEngine`, `MeshEnvelope`)
- Authentication & authorization (`auth.py`, JWT handling)
- Local data storage encryption (`DatabaseService`, `KeychainService`)
- Server API endpoints (`server/routers/`)

### Out of Scope

- Social engineering attacks
- Denial of service attacks
- Issues in third-party dependencies (report to upstream)

## Security Architecture

RAVEN uses multiple layers of security:

- **AES-256** for message encryption
- **Ed25519** for message signing
- **HMAC** for message authentication
- **iOS Keychain** for secure key storage
- **TLS 1.3** for server communication
- **Spray-and-Wait DTN** for mesh message routing

## Acknowledgments

We appreciate responsible disclosure and will credit security researchers who report valid vulnerabilities (with permission).
