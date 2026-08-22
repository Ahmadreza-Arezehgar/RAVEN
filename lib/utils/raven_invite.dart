import 'dart:convert';

/// Raven one-text invite — packs all contact fields into a single string.
///
/// Format: `raven:<address>:<pub_hex>`
/// The fingerprint is derived from pub_hex, never transmitted separately.
///
/// Usage:
///   final invite = RavenInvite.encode(address: addr, pubHex: pubHex);
///   → "raven:rvn1q…:d77c39…"
///
///   final data = RavenInvite.decode(text);  // accepts raw or pasted blocks
///   if (data != null) { /* address, pubHex, fingerprint ready */ }
class RavenInvite {
  RavenInvite._();

  static const String prefix = 'raven:';

  /// Encode the minimum fields into a single shareable text line.
  /// [pubHex] must be exactly 64 hex chars; fingerprint is derived, not stored.
  static String encode({required String address, required String pubHex}) {
    return '$prefix$address:$pubHex';
  }

  /// Try to extract a Raven invite from arbitrary pasted text.
  ///
  /// Accepts:
  ///   * a clean `raven:addr:pub` string
  ///   * a full `ash whoami` block (address + pub_hex lines)
  ///   * any text containing both an rvn1… address and a 64-char hex key
  ///
  /// Returns null when no valid invite is found.
  static RavenInviteData? decode(String input) {
    // Strategy 1 — exact raven: prefix
    if (input.startsWith(prefix)) {
      return _parseColon(input);
    }

    // Strategy 2 — ash whoami block (labeled lines)
    final addr = _extractLabeled(input, 'address');
    final pub = _extractLabeled(input, 'pub_hex');
    if (addr != null && pub != null) {
      return _validate(addr, pub);
    }

    // Strategy 3 — scan for rvn1… and 64-hex anywhere in the text
    final rvnMatch = RegExp(r'(rvn1[0-9a-z]{30,60})').firstMatch(input);
    final hexMatch =
        RegExp(r'\b([0-9a-fA-F]{64})\b').firstMatch(input);
    if (rvnMatch != null && hexMatch != null) {
      return _validate(rvnMatch.group(1)!, hexMatch.group(1)!);
    }

    return null;
  }

  static RavenInviteData? _parseColon(String input) {
    final parts = input.substring(prefix.length).split(':');
    if (parts.length >= 2) {
      return _validate(parts[0], parts[1]);
    }
    return null;
  }

  static String? _extractLabeled(String text, String label) {
    final pattern = RegExp('$label\\s*[:=]?\\s*(\\S+)', caseSensitive: false);
    final m = pattern.firstMatch(text);
    return m?.group(1);
  }

  static RavenInviteData? _validate(String address, String pubHexRaw) {
    final pub = pubHexRaw.trim().toLowerCase();
    final addr = address.trim().toLowerCase();

    if (!addr.startsWith('rvn1') || addr.length < 34 || addr.length > 90) {
      return null;
    }
    if (pub.length != 64 ||
        RegExp(r'^[0-9a-f]+$').hasMatch(pub) == false) {
      return null;
    }

    return RavenInviteData(
      address: addr,
      pubHex: pub,
      fingerprint: deriveShortFingerprint(pub),
    );
  }

  /// Short display fingerprint (3 groups of 4 chars) from pub_hex.
  /// Same derivation as DeviceIdentityService._computeFingerprintFromPem
  /// but from raw hex to avoid needing the PEM.
  static String deriveShortFingerprint(String pubHexLower) {
    // We cannot reproduce the PEM-based SHA256 here without the full PEM,
    // but we can produce a deterministic short tag from the pub_hex itself.
    // This is used ONLY as a visual confirmation tag, not as security pin.
    // Security pinning still uses --verify-fp with the real fingerprint.
    final bytes = utf8.encode(pubHexLower);
    var hash = 0x811c9dc5; // FNV-1a offset basis
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    final h = hash.toRadixString(16).padLeft(8, '0').toUpperCase();
    return '${h.substring(0, 4)}-${h.substring(4, 8)}-INVITE';
  }
}

/// Decoded invite data ready to be pinned as a contact.
class RavenInviteData {
  final String address;
  final String pubHex;
  final String fingerprint; // visual tag only

  const RavenInviteData({
    required this.address,
    required this.pubHex,
    required this.fingerprint,
  });

  @override
  String toString() => 'RavenInvite($address, fp:$fingerprint)';
}
