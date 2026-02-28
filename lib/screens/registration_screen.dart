import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:provider/provider.dart';
import 'package:pointycastle/export.dart' as pc;
import '../models/user_model.dart';
import '../services/database_helper.dart';
import '../services/crypto_service.dart';
import '../services/toast_service.dart';
import '../main.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  final _usernameController = TextEditingController();
  final _bioController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  @override
  void dispose() {
    _usernameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      // Generate RSA key pair for E2EE
      final crypto = CryptoService.instance;
      // Generate keypair
      final keyPair = await crypto.generateKeyPair();
      
      // Store keys (cast to RSA types)
      await crypto.storePrivateKey(keyPair.privateKey as pc.RSAPrivateKey);
      await crypto.storePublicKey(keyPair.publicKey as pc.RSAPublicKey);
      
      // Get public key for database
      final publicKeyPem = crypto.publicKeyToPem(keyPair.publicKey as pc.RSAPublicKey);
      
      final user = User(
        id: const Uuid().v4(),
        username: _usernameController.text.trim(),
        bio: _bioController.text.trim().isEmpty 
            ? null 
            : _bioController.text.trim(),
        createdAt: DateTime.now(),
        publicKey: publicKeyPem,
      );

      await DatabaseHelper.instance.insertUser(user);

      if (mounted) {
        // Set user in AppModel and start mesh
        final model = context.read<AppModel>();
        await model.setCurrentUser(user);
        
        // Navigate to home
        Navigator.of(context).pushReplacementNamed('/home');
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError('خطا در ثبت‌نام: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Logo/Icon
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 80,
                    color: Theme.of(context).primaryColor,
                  ),
                  const SizedBox(height: 16),
                  
                  // Title
                  Text(
                    'RAVEN',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  
                  Text(
                    'پیام‌رسان هیبریدی - Mesh + Internet',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[600],
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 48),
                  
                  // Username field
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'نام کاربری',
                      hintText: 'یک نام کاربری انتخاب کنید',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'نام کاربری الزامی است';
                      }
                      if (value.trim().length < 3) {
                        return 'نام کاربری باید حداقل ۳ کاراکتر باشد';
                      }
                      return null;
                    },
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 16),
                  
                  // Bio field (optional)
                  TextFormField(
                    controller: _bioController,
                    decoration: const InputDecoration(
                      labelText: 'بیو (اختیاری)',
                      hintText: 'درباره خودتان بنویسید',
                      prefixIcon: Icon(Icons.info_outline),
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                    textInputAction: TextInputAction.done,
                  ),
                  const SizedBox(height: 24),
                  
                  // Register button
                  FilledButton(
                    onPressed: _isLoading ? null : _register,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text(
                            'شروع کنید',
                            style: TextStyle(fontSize: 16),
                          ),
                  ),
                  const SizedBox(height: 24),
                  
                  // Info text
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.info, color: Colors.blue[700], size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'چگونه کار می‌کند؟',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue[900],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '• پیام‌ها از طریق Bluetooth/WiFi Direct ارسال می‌شوند\n'
                          '• نیازی به اینترنت نیست\n'
                          '• پیام‌ها تا رسیدن به مقصد forward می‌شوند\n'
                          '• اگر یک دستگاه به اینترنت متصل شود، پیام‌ها sync می‌شوند',
                          style: TextStyle(
                            color: Colors.blue[800],
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
