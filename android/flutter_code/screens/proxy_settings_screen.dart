import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import '../services/toast_service.dart';

/// Proxy Settings Screen
/// Note: This proxy only applies to this app's requests, not system-wide
class ProxySettingsScreen extends StatefulWidget {
  const ProxySettingsScreen({super.key});

  @override
  State<ProxySettingsScreen> createState() => _ProxySettingsScreenState();
}

class _ProxySettingsScreenState extends State<ProxySettingsScreen> {
  final _hostController = TextEditingController();
  final _portController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _secureStorage = const FlutterSecureStorage();
  
  bool _isEnabled = false;
  bool _isLoading = true;
  bool _isTesting = false;
  String? _testResult;
  
  @override
  void initState() {
    super.initState();
    _loadSettings();
  }
  
  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
  
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isEnabled = prefs.getBool('proxy_enabled') ?? false;
    _hostController.text = prefs.getString('proxy_host') ?? '';
    _portController.text = prefs.getString('proxy_port') ?? '';
    _usernameController.text = await _secureStorage.read(key: 'proxy_username') ?? '';
    _passwordController.text = await _secureStorage.read(key: 'proxy_password') ?? '';
    
    setState(() => _isLoading = false);
  }
  
  Future<void> _saveSettings() async {
    HapticFeedback.mediumImpact();
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('proxy_enabled', _isEnabled);
    await prefs.setString('proxy_host', _hostController.text.trim());
    await prefs.setString('proxy_port', _portController.text.trim());
    
    // Store credentials securely
    await _secureStorage.write(key: 'proxy_username', value: _usernameController.text.trim());
    await _secureStorage.write(key: 'proxy_password', value: _passwordController.text.trim());
    
    if (mounted) {
      ToastService.showSuccess('Proxy settings saved');
    }
  }
  
  Future<void> _testConnection() async {
    if (_hostController.text.isEmpty || _portController.text.isEmpty) {
      setState(() => _testResult = '❌ Please enter host and port');
      return;
    }
    
    HapticFeedback.lightImpact();
    setState(() {
      _isTesting = true;
      _testResult = null;
    });
    
    try {
      final dio = Dio();
      final host = _hostController.text.trim();
      final port = int.tryParse(_portController.text.trim()) ?? 0;
      
      // Apply proxy to Dio
      final adapter = dio.httpClientAdapter as IOHttpClientAdapter;
      adapter.createHttpClient = () {
        final client = HttpClient();
        client.findProxy = (uri) => "PROXY $host:$port;";
        client.badCertificateCallback = (cert, host, port) => false;
        return client;
      };
      
      // Test with a simple request
      final response = await dio.get(
        'https://www.google.com',
        options: Options(receiveTimeout: const Duration(seconds: 10)),
      );
      
      if (response.statusCode == 200) {
        HapticFeedback.heavyImpact();
        setState(() => _testResult = '✅ Connection successful!');
      } else {
        setState(() => _testResult = '⚠️ Status: ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _testResult = '❌ Failed: ${e.toString().substring(0, 50)}...');
    } finally {
      setState(() => _isTesting = false);
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Proxy Settings', style: TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          TextButton(
            onPressed: _saveSettings,
            child: const Text('Save', style: TextStyle(color: Color(0xFF0A84FF))),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Warning banner
                _buildWarningBanner(),
                
                const SizedBox(height: 20),
                
                // Enable toggle
                _buildGlassCard(
                  child: Row(
                    children: [
                      const Icon(Icons.power_settings_new, color: Colors.white70),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Enable Proxy', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
                            Text('Route app traffic through proxy', style: TextStyle(color: Colors.white54, fontSize: 13)),
                          ],
                        ),
                      ),
                      Switch.adaptive(
                        value: _isEnabled,
                        onChanged: (v) {
                          HapticFeedback.selectionClick();
                          setState(() => _isEnabled = v);
                        },
                        activeColor: const Color(0xFF34C759),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 20),
                
                // Host & Port
                _buildSectionHeader('Server'),
                const SizedBox(height: 10),
                _buildGlassCard(
                  child: Column(
                    children: [
                      _buildTextField(
                        controller: _hostController,
                        label: 'Host',
                        hint: 'proxy.example.com',
                        icon: Icons.dns_outlined,
                      ),
                      Divider(color: Colors.white.withOpacity(0.1), height: 1),
                      _buildTextField(
                        controller: _portController,
                        label: 'Port',
                        hint: '8080',
                        icon: Icons.numbers,
                        keyboardType: TextInputType.number,
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 20),
                
                // Authentication (optional)
                _buildSectionHeader('Authentication (Optional)'),
                const SizedBox(height: 10),
                _buildGlassCard(
                  child: Column(
                    children: [
                      _buildTextField(
                        controller: _usernameController,
                        label: 'Username',
                        hint: 'Optional',
                        icon: Icons.person_outline,
                      ),
                      Divider(color: Colors.white.withOpacity(0.1), height: 1),
                      _buildTextField(
                        controller: _passwordController,
                        label: 'Password',
                        hint: 'Optional',
                        icon: Icons.lock_outline,
                        obscureText: true,
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 24),
                
                // Test button
                GestureDetector(
                  onTap: _isTesting ? null : _testConnection,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A84FF).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF0A84FF).withOpacity(0.4)),
                    ),
                    child: Center(
                      child: _isTesting
                          ? const SizedBox(
                              width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0A84FF)),
                            )
                          : const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.speed, color: Color(0xFF0A84FF), size: 20),
                                SizedBox(width: 8),
                                Text(
                                  'Test Connection',
                                  style: TextStyle(color: Color(0xFF0A84FF), fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
                
                // Test result
                if (_testResult != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _testResult!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _testResult!.startsWith('✅') ? const Color(0xFF34C759) : Colors.red,
                      fontSize: 14,
                    ),
                  ),
                ],
                
                const SizedBox(height: 40),
              ],
            ),
    );
  }
  
  Widget _buildWarningBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.orange, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'This proxy only applies to RAVEN\'s requests. It does not change system-wide network settings.',
              style: TextStyle(color: Colors.orange.shade200, fontSize: 13, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
  
  Widget _buildSectionHeader(String title) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        color: Colors.white.withOpacity(0.5),
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 1,
      ),
    );
  }
  
  Widget _buildGlassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: child,
        ),
      ),
    );
  }
  
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    bool obscureText = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: Colors.white54, size: 20),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          const Spacer(),
          SizedBox(
            width: 180,
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              obscureText: obscureText,
              textAlign: TextAlign.right,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}


/// Apply proxy to a Dio instance
/// Call this when making API requests if proxy is enabled
Future<void> applyProxyToDio(Dio dio) async {
  final prefs = await SharedPreferences.getInstance();
  final enabled = prefs.getBool('proxy_enabled') ?? false;
  
  if (!enabled) return;
  
  final host = prefs.getString('proxy_host') ?? '';
  final port = prefs.getString('proxy_port') ?? '';
  
  if (host.isEmpty || port.isEmpty) return;
  
  final adapter = dio.httpClientAdapter as IOHttpClientAdapter;
  adapter.createHttpClient = () {
    final client = HttpClient();
    client.findProxy = (uri) => "PROXY $host:$port;";
    client.badCertificateCallback = (cert, host, port) => false; // Secure: reject bad certs
    return client;
  };
}
