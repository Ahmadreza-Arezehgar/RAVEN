import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';
import '../models/contact_model.dart';
import '../main.dart';
import '../services/toast_service.dart';
import 'package:hybrid_messenger/widgets/glass_container.dart';

class QrScreen extends StatelessWidget {
  const QrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Scan & Share"),
          bottom: const TabBar(
            tabs: [
              Tab(text: "My Code", icon: Icon(Icons.qr_code)),
              Tab(text: "Scan", icon: Icon(Icons.camera_alt)),
            ],
            indicatorColor: Colors.white,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
          ),
        ),
        body: const TabBarView(
          children: [
            MyQrTab(),
            ScanQrTab(),
          ],
        ),
      ),
    );
  }
}

class MyQrTab extends StatelessWidget {
  const MyQrTab({super.key});

  @override
  Widget build(BuildContext context) {
    final user = context.read<AppModel>().currentUser;
    if (user == null) return const SizedBox();

    final data = jsonEncode({
      'id': user.id,
      'name': user.username,
      'type': 'friend_invite'
    });

    return Center(
      child: GlassContainer(
        padding: const EdgeInsets.all(32),
        color: Colors.white,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: data,
              version: QrVersions.auto,
              size: 200.0,
              backgroundColor: Colors.white,
            ),
            const SizedBox(height: 16),
            Text(user.username, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const Text("Scan to add me as a friend"),
          ],
        ),
      ),
    );
  }
}

class ScanQrTab extends StatefulWidget {
  const ScanQrTab({super.key});

  @override
  State<ScanQrTab> createState() => _ScanQrTabState();
}

class _ScanQrTabState extends State<ScanQrTab> {
  bool _found = false;

  @override
  Widget build(BuildContext context) {
    return MobileScanner(
      onDetect: (capture) async {
        if (_found) return;
        final List<Barcode> barcodes = capture.barcodes;
        for (final barcode in barcodes) {
           if (barcode.rawValue != null) {
             final code = barcode.rawValue!;
             try {
                final json = jsonDecode(code);
                if (json['type'] == 'friend_invite') {
                   _found = true;
                   final model = context.read<AppModel>();
                   
                   // Add contact to database
                   final contact = Contact(
                     id: Uuid().v4(),
                     userId: json['id'],
                     username: json['name'],
                     addedAt: DateTime.now(),
                     status: 0, // Stranger initially
                   );
                   
                   await model.addContact(contact);
                   model.startChatWith(json['id'], json['name']);
                   
                   ToastService.showSuccess("Added ${json['name']}! Send messages to become friends.");
                   Navigator.pop(context);
                }
             } catch(e) {
               // ignore
             }
           }
        }
      },
    );
  }
}
