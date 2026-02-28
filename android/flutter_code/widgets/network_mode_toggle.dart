import 'package:flutter/material.dart';
import '../services/network_mode_service.dart';
import 'package:provider/provider.dart';

/// WiFi/Bluetooth Toggle برای Header
class NetworkModeToggle extends StatelessWidget {
  const NetworkModeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<NetworkModeService>();
    
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(0.10),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ModeButton(
            icon: Icons.wifi,
            label: 'WiFi',
            isActive: service.isWiFiMode,
            onTap: () => service.switchMode(NetworkMode.wifi),
          ),
          const SizedBox(width: 4),
          _ModeButton(
            icon: Icons.bluetooth,
            label: 'BT',
            isActive: service.isBluetoothMode,
            onTap: () => service.switchMode(NetworkMode.bluetooth),
          ),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  
  const _ModeButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isActive 
              ? Colors.white.withOpacity(0.20) 
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: isActive
              ? Border.all(
                  color: Colors.white.withOpacity(0.15),
                  width: 0.5,
                )
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isActive 
                  ? Colors.white 
                  : Colors.white.withOpacity(0.60),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                color: isActive 
                    ? Colors.white 
                    : Colors.white.withOpacity(0.60),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
