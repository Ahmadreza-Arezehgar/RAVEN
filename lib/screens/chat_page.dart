import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:hybrid_messenger/main.dart';
import 'package:hybrid_messenger/services/api_service.dart';
import 'package:hybrid_messenger/services/toast_service.dart';
import 'package:hybrid_messenger/models/message_model.dart';
import 'package:hybrid_messenger/theme/modern_theme.dart';
import 'package:hybrid_messenger/widgets/modern_chat_bubble.dart';
import 'package:hybrid_messenger/widgets/liquid_glass_composer.dart';
import 'package:hybrid_messenger/widgets/voice_message_bubble.dart';
import 'package:hybrid_messenger/widgets/chat_connection_banner.dart';
import 'package:hybrid_messenger/widgets/attachment_picker_panel.dart';
import 'package:hybrid_messenger/widgets/reply_preview_bar.dart';
import 'package:hybrid_messenger/widgets/upload_progress_banner.dart';
import 'package:hybrid_messenger/widgets/schedule_picker_sheet.dart';
import 'package:hybrid_messenger/services/database_helper.dart';
import 'package:hybrid_messenger/services/voice_queue_controller.dart';  // ✅ For VoiceQueueItem
import 'package:hybrid_messenger/widgets/liquid_glass_chat_header.dart';
import 'package:hybrid_messenger/screens/chat_details_page.dart';
import 'package:hybrid_messenger/services/nickname_service.dart';
import 'package:hybrid_messenger/widgets/nickname_dialog.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _attachButtonKey = GlobalKey();  // For attachment picker anchor
  final ImagePicker _imagePicker = ImagePicker();
  
  // Reply state
  ChatMessage? _replyingTo;
  
  // ✅ Professional scroll behavior state
  bool _isNearBottom = true;
  int _unseenCount = 0;
  int _lastMessageCount = 0;
  
  // ✅ Upload progress state
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String _uploadFilename = '';
  UploadStatus _uploadStatus = UploadStatus.uploading;
  File? _pendingUploadFile;
  String? _pendingUploadMimeType;

  @override
  void initState() {
    super.initState();
    
    // ✅ Listen to scroll changes for smart auto-scroll
    _scrollController.addListener(_onScroll);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToBottom();
      // ✅ Start live refresh for this chat
      final model = context.read<AppModel>();
      model.startLiveChat(model.currentChatId);
      model.emitChatUpdate(); // ✅ Emit initial messages to stream
      _lastMessageCount = model.messages.length;
    });
  }
  
  @override
  void dispose() {
    // ✅ Stop live refresh when leaving chat
    try {
      context.read<AppModel>().stopLiveChat();
    } catch (_) {}
    _scrollController.removeListener(_onScroll);
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// ✅ Track scroll position to determine if user is near bottom
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    
    // Calculate distance from bottom
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    final distanceToBottom = maxScroll - currentScroll;
    
    // Threshold: 80px from bottom = "near bottom"
    final near = distanceToBottom < 80;
    
    if (near != _isNearBottom) {
      setState(() => _isNearBottom = near);
      
      // ✅ If user scrolled back to bottom, clear unseen count
      if (near && _unseenCount > 0) {
        setState(() => _unseenCount = 0);
      }
    }
  }

  /// ✅ Called when new message arrives - handles smart scroll
  void _onNewMessageArrived() {
    if (!mounted) return;
    
    if (_isNearBottom) {
      // User is near bottom - auto-scroll smoothly
      _animateToBottom();
    } else {
      // User is reading old messages - show pill, don't scroll
      setState(() => _unseenCount += 1);
    }
  }

  /// Jump to bottom instantly (for initial load)
  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    setState(() => _isNearBottom = true);
  }

  /// Animate to bottom smoothly
  void _animateToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
    setState(() {
      _isNearBottom = true;
      _unseenCount = 0;
    });
  }

  // Legacy method for backward compatibility
  void _scrollToBottom() {
    _animateToBottom();
  }

  // ═══════════════════════════════════════════════════════════════════
  // ATTACHMENT PICKER
  // ═══════════════════════════════════════════════════════════════════
  
  void _showAttachmentPicker() {
    AttachmentPickerPanel.show(
      context: context,
      anchorKey: _attachButtonKey,
      onSelect: (type) {
        if (type == AttachmentType.image) {
          _pickImage();
        } else if (type == AttachmentType.file) {
          _pickFile();
        } else if (type == AttachmentType.schedule) {
          _showSchedulePicker();
        }
      },
    );
  }
  
  /// ✅ Show schedule picker for scheduled messages
  void _showSchedulePicker() async {
    final scheduledAtUtc = await SchedulePickerSheet.show(context);
    if (scheduledAtUtc == null) return;
    
    // Mark that we're scheduling a message
    setState(() {
      _scheduledAtUtc = scheduledAtUtc;
    });
    
    ToastService.showSuccess('Message will be scheduled. Type and send!');
  }
  
  DateTime? _scheduledAtUtc;
  
  Future<void> _pickImage() async {
    try {
      // ✅ Don't use imageQuality/maxWidth/maxHeight - they strip EXIF orientation!
      // Server already handles: resize + EXIF transpose + compression
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        // NO compression params - let server handle it to preserve EXIF orientation
      );
      
      if (image == null) return;
      
      print('📷 [Attach] Image selected: ${image.path}');
      await _uploadAndSendMedia(File(image.path), 'image');
    } catch (e) {
      print('❌ [Attach] Image picker error: $e');
      _showError('Failed to select image');
    }
  }
  
  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png', 'doc', 'docx', 'txt'],
        allowMultiple: false,
      );
      
      if (result == null || result.files.isEmpty) return;
      
      final file = result.files.first;
      if (file.path == null) return;
      
      // Check file size (25MB limit)
      final fileSize = file.size;
      if (fileSize > 25 * 1024 * 1024) {
        _showError('File too large. Maximum size is 25MB.');
        return;
      }
      
      print('📄 [Attach] File selected: ${file.name} ($fileSize bytes)');
      
      // ✅ FIX: iOS security-scoped URLs expire after callback completes.
      // Copy file to temp directory IMMEDIATELY to preserve access.
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempPath = '${tempDir.path}/${timestamp}_${file.name}';
      
      print('📄 [Attach] Copying to temp: $tempPath');
      final sourceFile = File(file.path!);
      
      // Read bytes immediately while we still have access
      final bytes = await sourceFile.readAsBytes();
      if (bytes.isEmpty) {
        print('❌ [Attach] File read returned 0 bytes - security-scoped URL expired');
        _showError('Could not read file. Please try again.');
        return;
      }
      
      // Write to temp location
      final tempFile = await File(tempPath).writeAsBytes(bytes);
      print('✅ [Attach] File copied successfully: ${await tempFile.length()} bytes');
      
      await _uploadAndSendMedia(
        tempFile,
        'file',
        fileName: file.name,
        mimeType: file.extension != null ? 'application/${file.extension}' : null,
      );
    } catch (e) {
      print('❌ [Attach] File picker error: $e');
      _showError('Failed to select file');
    }
  }
  
  Future<void> _uploadAndSendMedia(
    File file, 
    String type, {
    String? fileName,
    String? mimeType,
  }) async {
    final model = context.read<AppModel>();
    final isFileUpload = type == 'file';
    final displayName = fileName ?? file.path.split('/').last;
    
    // Store for retry
    _pendingUploadFile = file;
    _pendingUploadMimeType = mimeType;
    
    // Show progress UI for files, toast for images
    if (isFileUpload) {
      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
        _uploadFilename = displayName;
        _uploadStatus = UploadStatus.uploading;
      });
    } else {
      ToastService.showInfo('Uploading image...', subtitle: 'Please wait');
    }
    
    try {
      String? url;
      
      if (isFileUpload) {
        // Use new uploadFile with progress callback
        final result = await ApiService.uploadFile(
          file,
          onProgress: (progress) {
            if (mounted) {
              setState(() => _uploadProgress = progress);
            }
          },
        );
        url = result?['file_url'] as String?;
      } else {
        // Use existing image upload
        url = await ApiService.uploadImage(file);
      }
      
      if (url != null) {
        // ✅ Send as proper media message
        await model.sendMediaMessage(
          recipientId: model.currentChatId,
          mediaUrl: url,
          messageType: type,
          mimeType: mimeType,
          filename: fileName,
        );
        
        if (isFileUpload) {
          // Show "Sent" state briefly
          setState(() => _uploadStatus = UploadStatus.sent);
          await Future.delayed(const Duration(milliseconds: 600));
          if (mounted) {
            setState(() => _isUploading = false);
          }
        } else {
          ToastService.showSuccess('Image sent!');
        }
        
        Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
      } else {
        if (isFileUpload) {
          setState(() => _uploadStatus = UploadStatus.failed);
        } else {
          _showError('Upload failed. Please try again.');
        }
      }
    } catch (e) {
      print('❌ [Attach] Upload error: $e');
      if (isFileUpload) {
        setState(() => _uploadStatus = UploadStatus.failed);
      } else {
        _showError('Upload failed');
      }
    }
  }
  
  void _retryUpload() {
    if (_pendingUploadFile != null) {
      _uploadAndSendMedia(
        _pendingUploadFile!,
        'file',
        fileName: _uploadFilename,
        mimeType: _pendingUploadMimeType,
      );
    }
  }
  
  void _showError(String message) {
    ToastService.showError(message);
  }

  // Helper to generate roomId (same logic as AppModel)
  String _getRoomId(String a, String b) {
    if (b == 'broadcast' || b == 'general') return b;
    return (a.compareTo(b) < 0) ? '${a}_$b' : '${b}_$a';
  }

  // Convert system event codes to user-friendly text
  String _getEventText(String rawText) {
    switch (rawText) {
      case '<<FRIEND_REQUEST>>':
        return '📬 Friend request sent';
      case '<<FRIEND_ACCEPT>>':
        return '✅ Friend request accepted';
      case '<<FRIEND_REJECT>>':
        return '❌ Friend request declined';
      default:
        return rawText.replaceAll(RegExp(r'[<>]'), '');
    }
  }

  /// Build message with swipe-to-reply and double-tap like
  Widget _buildSwipeableMessage({
    required ChatMessage msg,
    required bool isMe,
    required Widget child,
  }) {
    return Dismissible(
      key: ValueKey('swipe_${msg.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        // Trigger reply mode
        setState(() => _replyingTo = msg);
        return false; // Don't actually dismiss
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: Icon(
          Icons.reply,
          color: ModernTheme.textSecondary.withOpacity(0.6),
          size: 24,
        ),
      ),
      child: GestureDetector(
        onDoubleTap: () => _toggleLike(msg),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            // Like heart overlay
            if (msg.isLiked)
              Positioned(
                left: isMe ? 8 : null,
                right: isMe ? null : 8,
                bottom: -4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: ModernTheme.shadowSoft,
                  ),
                  child: const Icon(
                    Icons.favorite,
                    size: 14,
                    color: Colors.red,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Toggle like on message
  void _toggleLike(ChatMessage msg) async {
    final model = context.read<AppModel>();
    final newLiked = !msg.isLiked;
    
    // Update in AppModel messages list and trigger rebuild
    final idx = model.messages.indexWhere((m) => m.id == msg.id);
    if (idx != -1) {
      model.messages[idx] = model.messages[idx].copyWith(isLiked: newLiked);
      // Use setState to trigger rebuild (this widget)
      setState(() {});
    }
    
    // Update in DB
    await DatabaseHelper.instance.updateMessageLike(msg.id, newLiked);
  }


  // Report user dialog (App Store requirement)
  void _showReportDialog(BuildContext context, AppModel model) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report User'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Spam'),
              onTap: () async {
                await model.reportUser(model.currentChatId, 'spam');
                Navigator.pop(ctx);
                ToastService.showSuccess('Report submitted');
              },
            ),
            ListTile(
              title: const Text('Harassment'),
              onTap: () async {
                await model.reportUser(model.currentChatId, 'harassment');
                Navigator.pop(ctx);
                ToastService.showSuccess('Report submitted');
              },
            ),
            ListTile(
              title: const Text('Inappropriate Content'),
              onTap: () async {
                await model.reportUser(model.currentChatId, 'inappropriate');
                Navigator.pop(ctx);
                ToastService.showSuccess('Report submitted');
              },
            ),
          ],
        ),
      ),
    );
  }

  // Block user dialog (App Store requirement)
  void _showBlockDialog(BuildContext context, AppModel model) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Block ${model.currentChatName}?'),
        content: const Text('You will no longer receive messages from this user.'),
        actions: [
          TextButton(
            child: const Text('Cancel'),
            onPressed: () => Navigator.pop(ctx),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Block'),
            onPressed: () async {
              await model.blockUser(model.currentChatId);
              Navigator.pop(ctx); // Close dialog
              Navigator.pop(context); // Exit chat
              ToastService.showSuccess('Blocked ${model.currentChatName}');
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    
    // Generate proper roomId for filtering
    final roomId = model.currentUser != null && model.currentChatId.isNotEmpty
        ? _getRoomId(model.currentUser!.id, model.currentChatId)
        : model.currentChatId;
    
    final messages = model.messages
        .where((m) => m.roomId == roomId)
        .toList();
    
    // ✅ Detect new message arrival and trigger smart scroll
    if (messages.length > _lastMessageCount && _lastMessageCount > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onNewMessageArrived();
      });
    }
    _lastMessageCount = messages.length;

    return Scaffold(
      backgroundColor: ModernTheme.background,
      body: Stack(
        children: [
          // ✅ Gradient Background for better blur visibility
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF0D0D0D),  // Dark at top
                  Color(0xFF1A1A2E),  // Slightly purple/blue at bottom
                  Color(0xFF16213E),  // Deeper blue near input
                ],
                stops: [0.0, 0.7, 1.0],
              ),
            ),
          ),
          
          // ✅ Connection Status Banner (below header)
          Positioned(
            top: MediaQuery.of(context).padding.top + 80, // Below glass header
            left: 0,
            right: 0,
            child: ChatConnectionBanner(
              isStreaming: true, // Always show on connection changes
              overrideLink: null, // Auto-detect via connectivity_plus
            ),
          ),
          
          // NOTE: Global upload banner removed - now using inline file bubble
          
          // Messages List
          ListView.builder(
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 88, // Below header (72 + 16)
              bottom: 80 + MediaQuery.of(context).padding.bottom,
              left: 16,
              right: 16,
            ),
            itemCount: messages.length,
            itemBuilder: (context, index) {
              final msg = messages[index];
              final isMe = msg.senderId == model.currentUser?.id;
              
              // Filter out system event messages
              if (msg.text.startsWith('<<') && msg.text.endsWith('>>')) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: ModernTheme.surfaceVariant.withOpacity(0.5),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _getEventText(msg.text),
                        style: ModernTheme.caption.copyWith(
                          color: ModernTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                );
              }
              // ✅ Voice Message - render with VoiceMessageBubble
              if (msg.type == MessageType.voice && (msg.audioUrl != null || msg.localPath != null)) {
                // ✅ Build list of all voice messages for queue playback
                final allVoices = messages
                    .where((m) => m.type == MessageType.voice && (m.audioUrl != null || m.localPath != null))
                    .map((m) => VoiceQueueItem(
                      id: m.id,
                      url: m.audioUrl,
                      localPath: m.localPath,
                    ))
                    .toList();
                
                return _buildSwipeableMessage(
                  msg: msg,
                  isMe: isMe,
                  child: VoiceMessageBubble(
                    messageId: msg.id,  // ✅ Required for queue tracking
                    audioUrl: msg.audioUrl,
                    localPath: msg.localPath,
                    durationSeconds: msg.audioDurationSeconds ?? 0, // ✅ Use real duration from message
                    isFromMe: isMe,
                    timestamp: msg.timestamp,
                    transcript: msg.transcriptText,
                    allVoicesInChat: allVoices,  // ✅ For queue playback
                  ),
                );
              }
              
              // ✅ Regular text, image, or file message with swipe+like
              return _buildSwipeableMessage(
                msg: msg,
                isMe: isMe,
                child: ModernChatBubble(
                  isMe: isMe,
                  message: msg.text,
                  timestamp: msg.timestamp,
                  status: msg.status.name,  // ✅ FIX: Use actual status (sent/delivered/read)
                  type: msg.type,
                  mediaUrl: msg.audioUrl,
                  filename: msg.fileName ?? msg.text,  // ✅ FIX: Use actual filename, fallback to text
                  via: msg.via,  // ✅ Via badge (wifi/mesh)
                  deliveryAuthority: msg.deliveryAuthority,  // ✅ Transport-based coloring
                  // Reply info
                  replyToSenderName: msg.replyToSenderName,
                  replyToTextPreview: msg.replyToTextPreview,
                  replyToType: msg.replyToType,
                  // ✅ Scheduled message support
                  scheduledAtUtc: msg.scheduledAtUtc,
                ),
              );
          },
          ),
          
          // ✅ INLINE UPLOAD BUBBLE - Shows at bottom of chat during file upload
          if (_isUploading)
            Positioned(
              left: 0,
              right: 0,
              bottom: 96 + MediaQuery.of(context).padding.bottom,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: ModernChatBubble(
                    isMe: true,
                    message: _uploadFilename,
                    timestamp: DateTime.now(),
                    status: 'pending',
                    type: MessageType.file,
                    filename: _uploadFilename,
                    uploadProgress: _uploadProgress,
                    uploadStatus: _uploadStatus,
                    onRetry: _retryUpload,
                  ),
                ),
              ),
            ),
          
          // ✅ NEW MESSAGE PILL - Shows when user is scrolled up and new messages arrive
          Positioned(
            left: 0,
            right: 0,
            bottom: 96 + MediaQuery.of(context).padding.bottom,
            child: AnimatedSlide(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              offset: _unseenCount > 0 ? Offset.zero : const Offset(0, 0.4),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _unseenCount > 0 ? 1 : 0,
                child: IgnorePointer(
                  ignoring: _unseenCount == 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.lightImpact();
                        _animateToBottom();
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.10),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(color: Colors.white.withOpacity(0.18)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.2),
                                  blurRadius: 16,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.arrow_downward_rounded,
                                  size: 18,
                                  color: Colors.white.withOpacity(0.9),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _unseenCount == 1 
                                      ? "New message" 
                                      : "$_unseenCount new messages",
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          
          // ✅ Reply Preview Bar (above composer)
          if (_replyingTo != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 80 + MediaQuery.of(context).padding.bottom,
              child: ReplyPreviewBar(
                message: _replyingTo!,
                onCancel: () => setState(() => _replyingTo = null),
              ),
            ),
          
          // ✅ Floating Liquid Glass Composer
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: LiquidGlassComposer(
              attachButtonKey: _attachButtonKey,
              // ✅ Pass schedule state for chip UI
              scheduledAtUtc: _scheduledAtUtc,
              onModifySchedule: _showSchedulePicker,
              onCancelSchedule: () => setState(() => _scheduledAtUtc = null),
              onSend: (text) {
                // ✅ Check if this is a scheduled message
                final isScheduled = _scheduledAtUtc != null;
                final sendMode = isScheduled ? 'scheduled' : 'instant';
                final scheduledAt = _scheduledAtUtc;
                
                // ✅ Send with reply info if replying
                if (_replyingTo != null) {
                  model.sendReplyMessage(
                    recipientId: model.currentChatId,
                    text: text,
                    replyToMessage: _replyingTo!,
                    sendMode: sendMode,
                    scheduledAtUtc: scheduledAt,
                  );
                  setState(() => _replyingTo = null);
                } else {
                  model.sendToUser(
                    model.currentChatId, 
                    text,
                    sendMode: sendMode,
                    scheduledAtUtc: scheduledAt,
                  );
                }
                
                // Reset scheduled time after sending
                if (isScheduled) {
                  setState(() => _scheduledAtUtc = null);
                  ToastService.showSuccess('Message scheduled!');
                }
                
                Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
              },
              onAttach: () => _showAttachmentPicker(),
              onVoiceSend: (String filePath, Duration duration) async {
                print('🎤 [Voice] Recording complete: ${duration.inSeconds}s');
                print('🎤 [Voice] File path: $filePath');
                
                // Show uploading indicator
                ToastService.showInfo(
                  'Uploading voice...',
                  subtitle: '${duration.inSeconds}s',
                );
                
                // ✅ MUST upload to cloud first - this is required
                String? audioUrl;
                int retryCount = 0;
                const maxRetries = 3;
                
                while (audioUrl == null && retryCount < maxRetries) {
                  try {
                    print('🎤 [Voice] Upload attempt ${retryCount + 1}/$maxRetries');
                    audioUrl = await ApiService.uploadVoice(File(filePath));
                    if (audioUrl != null) {
                      print('✅ [Voice] Uploaded successfully: $audioUrl');
                    }
                  } catch (e) {
                    print('⚠️ [Voice] Upload attempt ${retryCount + 1} failed: $e');
                    retryCount++;
                    if (retryCount < maxRetries) {
                      await Future.delayed(const Duration(seconds: 1));
                    }
                  }
                }
                
                // ✅ Check if upload succeeded
                if (audioUrl == null) {
                  // Upload failed after all retries
                  ToastService.showError(
                    'Voice upload failed',
                    subtitle: 'Please try again',
                  );
                  return; // ❌ Don't send message without audioUrl
                }
                
                // ✅ Upload succeeded - now send the message
                final voiceText = '🎤 Voice (${duration.inSeconds}s)';
                await model.sendVoiceMessage(
                  recipientId: model.currentChatId,
                  audioUrl: audioUrl,        // ✅ Always has value now
                  localPath: filePath,       // Keep local path for sender's playback
                  duration: duration,
                  text: voiceText,
                );
                
                // Show success
                ToastService.showSuccess(
                  'Voice sent!',
                  subtitle: '${duration.inSeconds}s',
                );
                
                // Scroll to bottom
                Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
              },
            ),
          ),
          
          // ═══════════════════════════════════════════════════════════════
          // ✅ LIQUID GLASS HEADER - Three separate capsules
          // ═══════════════════════════════════════════════════════════════
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassChatHeader(
              fullName: NicknameService.instance.getNickname(model.currentChatId) ?? model.currentChatName,
              lastSeenText: model.isCurrentChatFriend ? "Online" : "Peer Connection",
              isOnline: model.isCurrentChatFriend,
              avatarUrl: model.currentChatAvatarUrl,
              onBack: () => Navigator.pop(context),
              onTapName: () async {
                final changed = await showNicknameSheet(
                  context: context,
                  peerId: model.currentChatId,
                  username: model.currentChatName,
                  avatarUrl: model.currentChatAvatarUrl,
                  currentNickname: NicknameService.instance.getNickname(model.currentChatId),
                );
                if (changed && mounted) setState(() {});
              },
              onOpenProfile: () {
                // ✅ Navigate to Chat Details (Photos/Files/Voice)
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatDetailsPage(
                      chatId: model.currentChatId,
                      title: model.currentChatName,
                      lastSeenText: model.isCurrentChatFriend ? "Online" : "Peer Connection",
                      avatarUrl: model.currentChatAvatarUrl,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
