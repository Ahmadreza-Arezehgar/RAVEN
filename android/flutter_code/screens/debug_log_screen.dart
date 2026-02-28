import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:hybrid_messenger/main.dart'; // for AppModel
import 'package:flutter/services.dart';
import '../services/toast_service.dart';

class DebugLogScreen extends StatelessWidget {
  const DebugLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Watch logs
    final logs = context.watch<AppModel>().logs;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Debug Console"),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () {
              final text = logs.join("\n");
              Clipboard.setData(ClipboardData(text: text));
              ToastService.showSuccess("Logs copied!");
            },
          )
        ],
      ),
      body: Container(
        color: Colors.black,
        child: ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: logs.length,
          itemBuilder: (_, i) {
            return Text(
              logs[i],
              style: const TextStyle(color: Colors.greenAccent, fontFamily: 'Courier', fontSize: 12),
            );
          },
        ),
      ),
    );
  }
}
