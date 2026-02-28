import 'package:flutter/material.dart';
import '../services/device_identity_service.dart';

/// PairingApprovalDialog - Shows when an unknown peer requests pairing
/// 
/// Displays:
/// - Peer's displayName
/// - Public key fingerprint (formatted)
/// - Security warning about verifying fingerprint
/// 
/// Actions:
/// - Trust: Adds peer to trusted list
/// - Reject: Declines the pairing request
class PairingApprovalDialog extends StatelessWidget {
  final String fingerprint;
  final String peerName;
  final String publicKey;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const PairingApprovalDialog({
    super.key,
    required this.fingerprint,
    required this.peerName,
    required this.publicKey,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final deviceIdentity = DeviceIdentityService.instance;
    final formattedFingerprint = deviceIdentity.formatFingerprintForDisplay(fingerprint);
    final shortFingerprint = deviceIdentity.getShortFingerprint(fingerprint);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.security, color: Colors.amber),
          const SizedBox(width: 8),
          const Text('Pairing Request'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Peer info
            Text(
              'Device "$peerName" wants to connect',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            
            // Fingerprint display
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[400]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Device Fingerprint:',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    formattedFingerprint,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // Security warning
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber[300]!),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning, color: Colors.amber, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Security Verification',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Verify this fingerprint matches on the other device before trusting. Compare the first 8 characters: $shortFingerprint',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            
            // Tips
            const Text(
              'How to verify:',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '1. Ask the other person to show their device fingerprint\n'
              '2. Compare the first 8 characters\n'
              '3. If they match, tap "Trust Device"',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      actions: [
        // Reject button
        TextButton(
          onPressed: onReject,
          child: const Text(
            'Reject',
            style: TextStyle(color: Colors.red),
          ),
        ),
        
        // Trust button
        FilledButton.icon(
          onPressed: onApprove,
          icon: const Icon(Icons.verified_user),
          label: const Text('Trust Device'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.green,
          ),
        ),
      ],
    );
  }
}

/// Helper function to show the pairing dialog
Future<bool?> showPairingApprovalDialog(
  BuildContext context, {
  required String fingerprint,
  required String peerName,
  required String publicKey,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false, // Must make a choice
    builder: (context) => PairingApprovalDialog(
      fingerprint: fingerprint,
      peerName: peerName,
      publicKey: publicKey,
      onApprove: () => Navigator.of(context).pop(true),
      onReject: () => Navigator.of(context).pop(false),
    ),
  );
}
