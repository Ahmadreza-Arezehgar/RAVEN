import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/modern_theme.dart';
import '../models/message_model.dart';
import '../widgets/upload_progress_banner.dart'; // For UploadStatus enum
import '../widgets/in_app_browser_sheet.dart';
import '../widgets/raveshot_chip.dart';
import '../screens/pdf_viewer_screen.dart';

/// Modern chat bubble with support for text, image, and file messages.
class ModernChatBubble extends StatelessWidget {
  final bool isMe;
  final String message;
  final DateTime timestamp;
  final String status; // 'sent', 'delivered', 'read'
  final List<String>? reactions;
  
  // Media support
  final MessageType type;
  final String? mediaUrl;
  final String? filename;
  
  // ✅ Reply support
  final String? replyToSenderName;
  final String? replyToTextPreview;
  final MessageType? replyToType;
  
  // ✅ Via badge (wifi/mesh/local)
  final String? via;
  
  // ✅ Upload progress support (for inline uploading file bubble)
  final double? uploadProgress; // 0.0 to 1.0 during upload
  final UploadStatus? uploadStatus; // null = completed, showing normal file bubble
  final VoidCallback? onRetry; // Called when retry button tapped
  
  // ✅ Scheduled message support
  final DateTime? scheduledAtUtc; // When this message will be sent
  final VoidCallback? onEditSchedule; // Edit scheduled time
  final VoidCallback? onCancelSchedule; // Cancel scheduled message
  
  // ✅ Transport-based coloring (internet=blue, mesh=purple)
  final DeliveryAuthority? deliveryAuthority;
  
  const ModernChatBubble({
    super.key,
    required this.isMe,
    required this.message,
    required this.timestamp,
    this.status = 'sent',
    this.reactions,
    this.type = MessageType.text,
    this.mediaUrl,
    this.filename,
    this.replyToSenderName,
    this.replyToTextPreview,
    this.replyToType,
    this.via,
    this.uploadProgress,
    this.uploadStatus,
    this.onRetry,
    this.scheduledAtUtc,
    this.onEditSchedule,
    this.onCancelSchedule,
    this.deliveryAuthority,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: isMe ? 60 : ModernTheme.spacing16,
          right: isMe ? ModernTheme.spacing16 : 60,
          bottom: ModernTheme.spacing8,
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // ✅ Render based on message type
            _buildMessageContent(context),
            
            // Reactions
            if (reactions != null && reactions!.isNotEmpty)
              Container(
                margin: EdgeInsets.only(
                  top: ModernTheme.spacing4,
                  left: isMe ? 0 : ModernTheme.spacing12,
                  right: isMe ? ModernTheme.spacing12 : 0,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: ModernTheme.spacing8,
                  vertical: ModernTheme.spacing4,
                ),
                decoration: BoxDecoration(
                  color: ModernTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(ModernTheme.radiusLarge),
                  boxShadow: ModernTheme.shadowSoft,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: reactions!.map((emoji) => 
                    Padding(
                      padding: EdgeInsets.only(right: ModernTheme.spacing4),
                      child: Text(emoji, style: const TextStyle(fontSize: 14)),
                    )
                  ).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
  
  Widget _buildMessageContent(BuildContext context) {
    // Snap photo → RaveShot pill chip
    if (type == MessageType.snap) {
      return _buildSnapBubble(context);
    }
    
    // Image message
    if (type == MessageType.image && mediaUrl != null) {
      return _buildImageBubble(context);
    }
    
    // File message (including uploading state)
    if (type == MessageType.file && (mediaUrl != null || uploadStatus != null)) {
      return _buildFileBubble(context);
    }
    
    // Default: Text message
    return _buildTextBubble();
  }
  
  /// Snap photo → Liquid Glass "RaveShot" pill chip
  Widget _buildSnapBubble(BuildContext context) {
    return RaveShotChip(
      isMe: isMe,
      timestamp: timestamp,
      statusText: status,
      uploadProgress: uploadProgress,
      uploadStatus: uploadStatus,
      onRetry: onRetry,
      onTap: () {
        if (mediaUrl != null) {
          _openFullImage(context);
        }
      },
    );
  }
  
  /// Image bubble with rounded corners and shadow
  Widget _buildImageBubble(BuildContext context) {
    return GestureDetector(
      onTap: () => _openFullImage(context),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240, maxHeight: 300),
        decoration: BoxDecoration(
          borderRadius: ModernTheme.chatBubbleRadius(isMe: isMe),
          boxShadow: ModernTheme.shadowSoft,
        ),
        child: ClipRRect(
          borderRadius: ModernTheme.chatBubbleRadius(isMe: isMe),
          child: Stack(
            children: [
              Image.network(
                mediaUrl!,
                fit: BoxFit.cover,
                loadingBuilder: (context, child, loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Container(
                    width: 200,
                    height: 150,
                    decoration: BoxDecoration(
                      color: ModernTheme.surfaceVariant,
                      borderRadius: ModernTheme.chatBubbleRadius(isMe: isMe),
                    ),
                    child: Center(
                      child: CircularProgressIndicator(
                        value: loadingProgress.expectedTotalBytes != null
                            ? loadingProgress.cumulativeBytesLoaded /
                                loadingProgress.expectedTotalBytes!
                            : null,
                        color: ModernTheme.accentBlue,
                      ),
                    ),
                  );
                },
                errorBuilder: (context, error, stackTrace) {
                  return Container(
                    width: 200,
                    height: 100,
                    decoration: BoxDecoration(
                      color: ModernTheme.surfaceVariant,
                      borderRadius: ModernTheme.chatBubbleRadius(isMe: isMe),
                    ),
                    child: const Center(
                      child: Icon(Icons.broken_image, color: Colors.grey, size: 40),
                    ),
                  );
                },
              ),
              // Time overlay
              Positioned(
                right: 8,
                bottom: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(timestamp),
                        style: const TextStyle(color: Colors.white, fontSize: 10),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        Icon(_getStatusIcon(), size: 10, color: _getStatusColor()),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  /// File/document bubble with icon and tap to open
  /// Also handles upload progress states (uploading, failed, sent)
  Widget _buildFileBubble(BuildContext context) {
    // Detect if PDF
    final isPdf = mediaUrl?.toLowerCase().endsWith('.pdf') == true ||
                  message.toLowerCase().contains('pdf') ||
                  (filename?.toLowerCase().endsWith('.pdf') ?? false);
    
    // Determine if this is an uploading file vs completed file
    final isUploading = uploadStatus != null;
    final isFailed = uploadStatus == UploadStatus.failed;
    final progress = uploadProgress ?? 0.0;
    
    // Icon and color based on state
    final IconData fileIcon = isPdf ? Icons.picture_as_pdf : Icons.insert_drive_file;
    final Color iconColor = isFailed 
        ? Colors.redAccent 
        : (isPdf ? Colors.red : Colors.blue);
    final Color iconBgColor = isFailed 
        ? Colors.red.withOpacity(0.15) 
        : (isPdf ? Colors.red.withOpacity(0.2) : Colors.blue.withOpacity(0.2));
    
    return GestureDetector(
      onTap: isFailed 
          ? onRetry 
          : (isUploading ? null : () => _openFile(context)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260), // ~70% of typical screen
        padding: EdgeInsets.symmetric(
          horizontal: ModernTheme.spacing12,
          vertical: ModernTheme.spacing12,
        ),
        decoration: BoxDecoration(
          gradient: isMe ? ModernTheme.senderBubbleGradient : ModernTheme.receiverBubbleGradient,
          borderRadius: ModernTheme.chatBubbleRadius(isMe: isMe),
          boxShadow: ModernTheme.shadowSoft,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Main row: icon + filename + retry
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // File icon container
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: isUploading && !isFailed
                      ? Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              value: progress > 0 ? progress : null,
                              valueColor: AlwaysStoppedAnimation<Color>(iconColor),
                            ),
                          ),
                        )
                      : Icon(
                          isFailed ? Icons.error_outline : fileIcon,
                          color: iconColor,
                          size: 22,
                        ),
                ),
                const SizedBox(width: 12),
                // Filename and status
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        filename ?? message,
                        style: ModernTheme.body.copyWith(fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      // Status text row
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _getFileStatusText(isUploading, isFailed, progress),
                            style: ModernTheme.caption.copyWith(
                              color: isFailed 
                                  ? Colors.redAccent.withOpacity(0.9)
                                  : (isMe ? Colors.white70 : ModernTheme.textSecondary),
                              fontSize: 11,
                            ),
                          ),
                          if (!isUploading) ...[
                            const SizedBox(width: 8),
                            Text(
                              _formatTime(timestamp),
                              style: ModernTheme.tiny.copyWith(
                                color: isMe ? Colors.white60 : ModernTheme.textTertiary,
                              ),
                            ),
                            if (isMe) ...[
                              const SizedBox(width: 4),
                              Icon(_getStatusIcon(), size: 12, color: _getStatusColor()),
                            ],
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                // Retry button (only on failure)
                if (isFailed && onRetry != null) ...[
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: onRetry,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.refresh,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            // Progress bar (only during upload)
            if (isUploading) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: isFailed ? 1.0 : progress.clamp(0.0, 1.0),
                  minHeight: 2, // Thin, elegant progress bar
                  backgroundColor: Colors.white.withOpacity(0.1),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isFailed ? Colors.redAccent : ModernTheme.accentBlue,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
  
  /// Get status text for file bubble
  String _getFileStatusText(bool isUploading, bool isFailed, double progress) {
    if (isFailed) return 'Upload failed';
    if (isUploading) return '${(progress * 100).toStringAsFixed(0)}% • Uploading…';
    return 'Tap to open';
  }
  
  /// Standard text bubble with clickable links
  Widget _buildTextBubble() {
    final isScheduled = status == 'scheduled' && scheduledAtUtc != null;
    final isSending = status == 'pending' || status == 'sending';
    
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: ModernTheme.spacing16,
        vertical: ModernTheme.spacing12,
      ),
      decoration: BoxDecoration(
        // ✅ Transport-based coloring: server=blue, mesh=purple
        gradient: isScheduled 
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xFF5C6BC0).withOpacity(0.9),
                  const Color(0xFF7E57C2).withOpacity(0.85),
                ],
              )
            : _getTransportGradient(isSending),
        borderRadius: ModernTheme.chatBubbleRadius(isMe: isMe),
        boxShadow: ModernTheme.shadowSoft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ✅ Scheduled indicator banner
          if (isScheduled) ...[
            _buildScheduledBanner(),
            SizedBox(height: ModernTheme.spacing8),
          ],
          // ✅ Quoted reply block
          if (replyToSenderName != null) ...[
            _buildQuotedReply(),
            SizedBox(height: ModernTheme.spacing8),
          ],
          // ✅ Use SelectableText.rich with clickable links
          _buildLinkifiedText(message),
          SizedBox(height: ModernTheme.spacing4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatTime(timestamp),
                style: ModernTheme.tiny.copyWith(
                  color: isMe 
                      ? Colors.white.withOpacity(0.7)
                      : ModernTheme.textTertiary,
                ),
              ),
              if (isMe && !isScheduled) ...[
                SizedBox(width: ModernTheme.spacing4),
                Icon(
                  _getStatusIcon(),
                  size: 12,
                  color: _getStatusColor(),
                ),
                // ✅ Via badge
                if (via != null && via!.isNotEmpty) ...[
                  SizedBox(width: ModernTheme.spacing4),
                  _buildViaBadge(),
                ],
              ],
            ],
          ),
        ],
      ),
    );
  }
  
  /// ✅ Scheduled message banner with time and edit/cancel buttons
  Widget _buildScheduledBanner() {
    final local = scheduledAtUtc!.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.schedule, size: 14, color: Colors.white70),
          const SizedBox(width: 6),
          Text(
            'Will send at $h:$m',
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (onEditSchedule != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onEditSchedule,
              child: const Icon(Icons.edit, size: 14, color: Colors.white70),
            ),
          ],
          if (onCancelSchedule != null) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: onCancelSchedule,
              child: const Icon(Icons.close, size: 14, color: Colors.white70),
            ),
          ],
        ],
      ),
    );
  }
  
  /// Build quoted reply block
  Widget _buildQuotedReply() {
    // Get icon for reply type
    IconData icon;
    switch (replyToType) {
      case MessageType.voice:
        icon = Icons.mic;
        break;
      case MessageType.image:
        icon = Icons.photo;
        break;
      case MessageType.file:
        icon = Icons.insert_drive_file;
        break;
      default:
        icon = Icons.chat_bubble_outline;
    }
    
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isMe 
            ? Colors.white.withOpacity(0.15)
            : Colors.black.withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(
            color: ModernTheme.accentBlue,
            width: 3,
          ),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: isMe ? Colors.white70 : ModernTheme.textSecondary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  replyToSenderName ?? '',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isMe ? Colors.white : ModernTheme.textPrimary,
                  ),
                ),
                Text(
                  replyToTextPreview ?? '',
                  style: TextStyle(
                    fontSize: 10,
                    color: isMe ? Colors.white70 : ModernTheme.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  /// Regex for detecting URLs
  static final _urlRegex = RegExp(
    r'https?://[^\s<>\[\]()]+|www\.[^\s<>\[\]()]+',
    caseSensitive: false,
  );
  
  /// Build text with clickable links
  Widget _buildLinkifiedText(String text) {
    final matches = _urlRegex.allMatches(text).toList();
    
    // No links? Return simple text
    if (matches.isEmpty) {
      return Text(message, style: ModernTheme.body);
    }
    
    // Build rich text with clickable links
    final spans = <InlineSpan>[];
    int lastEnd = 0;
    
    for (final match in matches) {
      // Add text before link
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: ModernTheme.body,
        ));
      }
      
      // Add clickable link - opens in-app browser
      final url = match.group(0)!;
      spans.add(WidgetSpan(
        child: Builder(
          builder: (context) => GestureDetector(
            onTap: () => _openUrlInApp(context, url),
            child: Text(
              url,
              style: ModernTheme.body.copyWith(
                color: isMe ? Colors.lightBlueAccent : ModernTheme.accentBlue,
                decoration: TextDecoration.underline,
                decorationColor: isMe ? Colors.lightBlueAccent : ModernTheme.accentBlue,
              ),
            ),
          ),
        ),
      ));
      
      lastEnd = match.end;
    }
    
    // Add remaining text after last link
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: ModernTheme.body,
      ));
    }
    
    return Text.rich(TextSpan(children: spans));
  }
  
  /// Open URL in external browser (fallback)
  Future<void> _openUrl(String url) async {
    // Add https:// if missing
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
  
  /// ✅ Open URL in in-app browser (Liquid Glass bottom sheet)
  void _openUrlInApp(BuildContext context, String url) {
    // Add https:// if missing
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    
    InAppBrowserSheet.show(context, url);
  }

  
  void _openFullImage(BuildContext context) {
    if (mediaUrl == null) return;
    
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              child: Image.network(mediaUrl!),
            ),
          ),
        ),
      ),
    );
  }
  
  Future<void> _openFile(BuildContext context) async {
    if (mediaUrl == null) return;
    
    // Check if PDF - open in-app viewer
    final isPdf = mediaUrl!.toLowerCase().endsWith('.pdf') ||
                  (filename?.toLowerCase().endsWith('.pdf') ?? false);
    
    if (isPdf) {
      // Import dynamically to avoid circular dependency
      Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => PDFViewerScreen(
            url: mediaUrl!,
            fileName: filename ?? 'Document.pdf',
          ),
          transitionsBuilder: (_, anim, __, child) {
            final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween(begin: 0.98, end: 1.0).animate(curved),
                child: child,
              ),
            );
          },
        ),
      );
    } else {
      // Other files - open externally
      final uri = Uri.parse(mediaUrl!);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }
  
  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
  
  IconData _getStatusIcon() {
    switch (status) {
      case 'sent':
        return Icons.check;
      case 'delivered':
        return Icons.done_all;
      case 'read':
        return Icons.done_all;
      default:
        return Icons.access_time;
    }
  }
  
  Color _getStatusColor() {
    switch (status) {
      case 'read':
        return ModernTheme.accentBlue;
      case 'delivered':
        return Colors.white.withOpacity(0.7);
      default:
        return Colors.white.withOpacity(0.5);
    }
  }
  
  /// ✅ Via badge showing transport method (WiFi/Mesh)
  Widget _buildViaBadge() {
    final icon = switch (via) {
      'wifi' || 'internet' || 'server' => Icons.wifi,
      'mesh' || 'bluetooth' => Icons.bluetooth,
      'local' => Icons.schedule,
      _ => Icons.help_outline,
    };
    
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, size: 10, color: Colors.white.withOpacity(0.7)),
    );
  }
  
  /// ✅ Get transport-based gradient for bubble
  /// Server/Internet = Blue (iOS style)
  /// Mesh/Bluetooth = Purple (distinctive P2P color)
  Gradient _getTransportGradient(bool isSending) {
    if (!isMe) {
      // Receiver bubbles are always gray
      return ModernTheme.receiverBubbleGradient;
    }
    
    // ✅ Opacity reduction for sending state
    final opacity = isSending ? 0.6 : 1.0;
    
    // Determine color based on delivery authority
    final isMesh = deliveryAuthority == DeliveryAuthority.mesh ||
                   via == 'mesh' || via == 'bluetooth';
    
    if (isMesh) {
      // ✅ Purple gradient for Mesh/Bluetooth P2P
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(const Color(0xFF7C4DFF), Colors.transparent, 1 - opacity)!, // Deep Purple
          Color.lerp(const Color(0xFF651FFF), Colors.transparent, 1 - opacity)!, // Violet
        ],
      );
    } else {
      // ✅ Blue gradient for Server/Internet (default Apple Messages style)
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(const Color(0xFF0A84FF), Colors.transparent, 1 - opacity)!, // Apple Blue
          Color.lerp(const Color(0xFF0066CC), Colors.transparent, 1 - opacity)!, // Deeper Blue
        ],
      );
    }
  }
}
