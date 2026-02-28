import 'package:flutter/material.dart';

enum SendMethod { bluetooth, wifi, auto }

class SendMethodSelector extends StatelessWidget {
  final SendMethod selectedMethod;
  final bool bluetoothAvailable;
  final bool wifiAvailable;
  final Function(SendMethod) onMethodChanged;

  const SendMethodSelector({
    super.key,
    required this.selectedMethod,
    required this.bluetoothAvailable,
    required this.wifiAvailable,
    required this.onMethodChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Bluetooth Icon
        IconButton(
          icon: Icon(
            Icons.bluetooth,
            color: bluetoothAvailable 
                ? (selectedMethod == SendMethod.bluetooth ? Colors.blue : Colors.grey)
                : Colors.grey.withOpacity(0.3),
          ),
          onPressed: bluetoothAvailable 
              ? () => onMethodChanged(SendMethod.bluetooth)
              : null,
          tooltip: bluetoothAvailable ? 'Send via Bluetooth' : 'Bluetooth unavailable',
        ),
        
        // WiFi Icon
        IconButton(
          icon: Icon(
            Icons.wifi,
            color: wifiAvailable 
                ? (selectedMethod == SendMethod.wifi ? Colors.green : Colors.grey)
                : Colors.grey.withOpacity(0.3),
          ),
          onPressed: wifiAvailable 
              ? () => onMethodChanged(SendMethod.wifi)
              : null,
          tooltip: wifiAvailable ? 'Send via WiFi' : 'WiFi unavailable (not friends or no connection)',
        ),
        
        // Auto Icon
        IconButton(
          icon: Icon(
            Icons.autorenew,
            color: selectedMethod == SendMethod.auto ? Colors.amber : Colors.grey,
          ),
          onPressed: () => onMethodChanged(SendMethod.auto),
          tooltip: 'Auto-select best method',
        ),
      ],
    );
  }
}
