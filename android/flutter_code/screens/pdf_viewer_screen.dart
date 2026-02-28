import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:share_plus/share_plus.dart';
import 'dart:ui';

/// In-app PDF Viewer with Liquid Glass UI
/// 
/// Features:
/// - Download & cache PDFs locally
/// - Real progress indicator
/// - Zoom/pan gestures
/// - Forward to chat
/// - Share via system sheet
class PDFViewerScreen extends StatefulWidget {
  final String url;
  final String fileName;
  final String? messageId;
  final void Function(String filePath, String fileName)? onForward;

  const PDFViewerScreen({
    super.key,
    required this.url,
    required this.fileName,
    this.messageId,
    this.onForward,
  });

  @override
  State<PDFViewerScreen> createState() => _PDFViewerScreenState();
}

class _PDFViewerScreenState extends State<PDFViewerScreen> {
  String? _localPath;
  double _progress = 0;
  bool _downloading = true;
  bool _failed = false;
  String? _errorMessage;
  
  final PdfViewerController _pdfController = PdfViewerController();
  int _currentPage = 1;
  int _totalPages = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _pdfController.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    setState(() {
      _downloading = true;
      _failed = false;
      _errorMessage = null;
    });

    try {
      final dir = await getApplicationDocumentsDirectory();
      final safeName = widget.fileName.replaceAll(RegExp(r'[^\w\-. ]'), '_');
      final cacheKey = widget.messageId ?? widget.url.hashCode.toString();
      final file = File('${dir.path}/pdf_cache_${cacheKey}_$safeName');

      // Check if already cached
      if (await file.exists() && await file.length() > 0) {
        setState(() {
          _localPath = file.path;
          _downloading = false;
          _progress = 1.0;
        });
        return;
      }

      // Download with progress
      final dio = Dio();
      await dio.download(
        widget.url,
        file.path,
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _progress = received / total);
          }
        },
      );

      if (mounted) {
        setState(() {
          _localPath = file.path;
          _downloading = false;
          _progress = 1.0;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloading = false;
          _failed = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _shareFile() async {
    if (_localPath == null) return;
    
    try {
      await Share.shareXFiles(
        [XFile(_localPath!)],
        text: widget.fileName,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Share failed: $e')),
        );
      }
    }
  }

  void _forwardFile() {
    if (_localPath == null || widget.onForward == null) return;
    widget.onForward!(_localPath!, widget.fileName);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _buildGlassAppBar(),
      body: _buildBody(),
    );
  }

  PreferredSizeWidget _buildGlassAppBar() {
    return PreferredSize(
      preferredSize: const Size.fromHeight(56),
      child: ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withOpacity(0.2),
                  width: 0.5,
                ),
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    // Back button
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios, color: Colors.white, size: 20),
                      onPressed: () => Navigator.pop(context),
                    ),
                    
                    // Title & Page info
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.fileName,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (_totalPages > 0)
                            Text(
                              'Page $_currentPage of $_totalPages',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.7),
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                    
                    // Forward button
                    if (widget.onForward != null && !_downloading && !_failed)
                      IconButton(
                        icon: const Icon(Icons.forward, color: Colors.white),
                        onPressed: _forwardFile,
                        tooltip: 'Forward',
                      ),
                    
                    // Share button
                    if (!_downloading && !_failed)
                      IconButton(
                        icon: const Icon(Icons.ios_share, color: Colors.white),
                        onPressed: _shareFile,
                        tooltip: 'Share',
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_downloading) {
      return _buildDownloadingState();
    }
    
    if (_failed) {
      return _buildFailedState();
    }
    
    if (_localPath == null) {
      return const Center(
        child: Text(
          'Could not open PDF',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    
    return SfPdfViewer.file(
      File(_localPath!),
      controller: _pdfController,
      canShowScrollHead: true,
      canShowScrollStatus: true,
      pageLayoutMode: PdfPageLayoutMode.continuous,
      onDocumentLoaded: (details) {
        setState(() {
          _totalPages = details.document.pages.count;
        });
      },
      onPageChanged: (details) {
        setState(() {
          _currentPage = details.newPageNumber;
        });
      },
    );
  }

  Widget _buildDownloadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Circular progress with percentage
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 80,
                height: 80,
                child: CircularProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  strokeWidth: 3,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                  backgroundColor: Colors.white.withOpacity(0.2),
                ),
              ),
              Text(
                '${(_progress * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Downloading PDF...',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.fileName,
            style: TextStyle(
              color: Colors.white.withOpacity(0.5),
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildFailedState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.error_outline,
            color: Colors.redAccent,
            size: 64,
          ),
          const SizedBox(height: 16),
          const Text(
            'Download Failed',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _errorMessage ?? 'Unknown error',
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _prepare,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.2),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
