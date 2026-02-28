import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// ✅ In-App Browser as a Liquid Glass Bottom Sheet
/// Opens URLs inside the app without leaving the chat
class InAppBrowserSheet extends StatefulWidget {
  final String url;
  final String? title;

  const InAppBrowserSheet({
    super.key,
    required this.url,
    this.title,
  });

  /// Show the browser sheet
  static Future<void> show(BuildContext context, String url, {String? title}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => InAppBrowserSheet(url: url, title: title),
    );
  }

  @override
  State<InAppBrowserSheet> createState() => _InAppBrowserSheetState();
}

class _InAppBrowserSheetState extends State<InAppBrowserSheet> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String _currentUrl = '';
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (progress) {
          setState(() => _progress = progress / 100);
        },
        onPageStarted: (url) {
          setState(() {
            _isLoading = true;
            _currentUrl = url;
          });
        },
        onPageFinished: (url) {
          setState(() => _isLoading = false);
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        // ✅ Don't use scrollController - let WebView handle its own scroll
        return Container(
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            color: Colors.black,
          ),
          child: Column(
            children: [
              // ✅ Glass header (blur only on header, NOT on WebView)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.75),
                      border: Border(
                        bottom: BorderSide(color: Colors.white.withOpacity(0.1)),
                      ),
                    ),
                    child: _buildHeader(),
                  ),
                ),
              ),
              
              // Progress bar
              if (_isLoading)
                LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  backgroundColor: Colors.white.withOpacity(0.1),
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                  minHeight: 2,
                ),
              
              // ✅ WebView - no overlay, no blur, gets full gesture control
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(22),
                    bottomRight: Radius.circular(22),
                  ),
                  child: WebViewWidget(controller: _controller),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Row(
        children: [
          // Drag handle
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withOpacity(0.35),
            ),
          ),
          const Spacer(),
          
          // URL/Title display
          Expanded(
            flex: 3,
            child: Text(
              widget.title ?? Uri.parse(_currentUrl).host,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withOpacity(0.7),
                fontSize: 12,
              ),
            ),
          ),
          
          const Spacer(),
          
          // Open in external browser
          IconButton(
            onPressed: _openInExternalBrowser,
            icon: Icon(
              Icons.open_in_new,
              color: Colors.white.withOpacity(0.85),
              size: 20,
            ),
            tooltip: 'Open in Safari',
          ),
          
          // Close button
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: Icon(
              Icons.close,
              color: Colors.white.withOpacity(0.85),
              size: 20,
            ),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Future<void> _openInExternalBrowser() async {
    final uri = Uri.parse(_currentUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (mounted) Navigator.pop(context);
    }
  }
}
