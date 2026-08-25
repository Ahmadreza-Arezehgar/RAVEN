# Contributing to RAVEN

Thank you for your interest in contributing to RAVEN! This document provides guidelines for contributing to the project.

## Code of Conduct

- Be respectful and constructive in all communications
- Focus on the code, not the person
- Welcome newcomers and help them get started

## How to Contribute

### Reporting Bugs

1. Search existing issues to avoid duplicates
2. Use the bug report template
3. Include steps to reproduce, expected vs actual behavior
4. Include device/OS version if relevant

### Suggesting Features

1. Open an issue with the `[Feature Request]` prefix
2. Describe the use case and expected behavior
3. Explain why this would benefit RAVEN users

### Security Issues

**Do NOT open public issues for security vulnerabilities.**
See [SECURITY.md](SECURITY.md) for responsible disclosure guidelines.

### Code Contributions

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Make your changes
4. Write/update tests if applicable
5. Ensure code follows existing style conventions
6. Submit a Pull Request with a clear description

## Development Setup

### Serverless node and terminal (Rust)

```bash
cd node
cargo test -p raven-core -p raven-node -p ash -p raven-swarm
cargo test -p raven-core --test network_sim_1000
cargo run -p ash -- --help
```

Platform installation notes live in [`node/INSTALL_Linux.md`](node/INSTALL_Linux.md),
[`node/INSTALL_macOS.md`](node/INSTALL_macOS.md), and
[`node/INSTALL_Windows.md`](node/INSTALL_Windows.md). Protocol changes must update
the deterministic vectors under `shared-vectors/rvn1/` and pass the Python,
Rust, and Swift parity tests. Security-sensitive experimental features must
remain disabled by default until their documented activation gate is complete.

### Legacy application server (security maintenance only)

The FastAPI application is not part of the new serverless text-message path.
Do not add a mandatory message, identity, lookup, or routing dependency to it.
Use this setup only for scoped maintenance of legacy application features:

```bash
cd server
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env  # Fill in your values
uvicorn main:app --reload
```

### iOS (Swift)

1. Open `ios-native/RAVEN/RAVEN.xcodeproj` in Xcode
2. Build and run on simulator or device

## License

By contributing, you agree that your contributions will be licensed under the AGPL-3.0 License.
Brand names and visual assets are governed separately by
[`TRADEMARK.md`](TRADEMARK.md) and [`ASSET_LICENSE.md`](ASSET_LICENSE.md).
