import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'package:hybrid_messenger/screens/chat_page.dart';
import 'package:hybrid_messenger/screens/debug_log_screen.dart';
import 'package:hybrid_messenger/screens/home_tabs.dart';
import 'package:hybrid_messenger/screens/messages_page.dart';
import 'package:hybrid_messenger/screens/search_page.dart';
import 'package:hybrid_messenger/screens/account_settings_page.dart';
import 'package:hybrid_messenger/screens/settings_screen.dart';
import 'package:hybrid_messenger/widgets/global_notification_overlay.dart';
import 'package:hybrid_messenger/services/sync_service.dart';
import 'package:hybrid_messenger/services/sync_manager.dart';
import 'package:hybrid_messenger/services/toast_service.dart';
import 'package:hybrid_messenger/services/mesh/mesh_notification_service.dart';  // ✅ Notification deep-linking
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:hybrid_messenger/mesh_bridge.dart';
import 'package:hybrid_messenger/models/notification_model.dart';
import 'package:hybrid_messenger/services/network_mode_service.dart';
import 'package:hybrid_messenger/widgets/notification_popup.dart';
import 'package:hybrid_messenger/widgets/network_mode_toast.dart';
import 'package:hybrid_messenger/widgets/send_method_selector.dart';
import 'gen_l10n/app_localizations.dart';

import 'models/user_model.dart';
import 'models/message_model.dart';
import 'models/contact_model.dart';
import 'models/post_model.dart';
import 'models/message_envelope.dart';
import 'services/badge_state.dart';
import 'services/database_helper.dart';
import 'services/message_router.dart';
import 'services/security_service.dart';
import 'services/api_service.dart';
import 'services/identity_service.dart';
import 'services/crypto_service.dart';
import 'services/contact_service.dart';
import 'services/device_identity_service.dart';
import 'services/time_service.dart';  // ✅ Added for UTC time sync
import 'services/mesh_router.dart';  // ✅ Added for auto mesh/WiFi switching
import 'services/nickname_service.dart';  // ✅ Added for local nickname support
import 'services/qr_friend_service.dart';  // ✅ Added for QR-based friend pairing
import 'services/mesh/mesh_event_dispatcher.dart';  // ✅ Mesh networking dispatcher
import 'services/dtn_router_service.dart';  // ✅ DTN Store-and-Forward routing
import 'services/dtn_config_service.dart';  // ✅ DTN adaptive configuration
import 'widgets/friend_pair_dialog.dart';  // ✅ Added for friend pair approval dialog
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'screens/chat_page.dart';
import 'screens/debug_log_screen.dart';
import 'screens/home_tabs.dart';
import 'screens/settings_screen.dart';
import 'screens/profile_edit_screen.dart';
import 'screens/registration_screen.dart';
import 'screens/welcome_screen.dart';
import 'screens/sign_in_screen.dart';
import 'screens/sign_up_screen.dart';
import 'screens/onboarding/email_step_screen.dart';
import 'screens/qr_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/email_verification_screen.dart';
import 'screens/forgot_password_screen.dart';
import 'screens/privacy_policy_page.dart';
import 'widgets/glass_container.dart';
import 'widgets/follow_back_prompt.dart';
import 'widgets/liquid_glass.dart';
import 'widgets/native_glass_container.dart';
import 'widgets/floating_glass_dock.dart';
import 'widgets/post_composer.dart';
import 'theme/mobile_theme.dart';
import 'theme/ios_design_system.dart';
import 'services/device_optimization_service.dart';


// Notification Plugin
final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize notifications
  const initializationSettingsIOS = DarwinInitializationSettings();
  const initializationSettings = InitializationSettings(iOS: initializationSettingsIOS);
  await _notificationsPlugin.initialize(initializationSettings);
  
  // ✅ Sync time with server (non-blocking)
  TimeService.instance.syncWithServer();
  
  // ✅ Initialize nickname service (load cached nicknames)
  NicknameService.instance.init();
  
  // ✅ Initialize mesh notifications and set up deep-link callback
  await MeshNotificationService.instance.init();
  MeshNotificationService.onOpenChat = (userId, username) {
    // Navigate to chat when notification is tapped
    final context = navigatorKey.currentContext;
    if (context != null) {
      final model = Provider.of<AppModel>(context, listen: false);
      model.startChatWith(userId, username);
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => const ChatPage()),
      );
    }
  };

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppModel()),
        ChangeNotifierProvider(create: (_) => NetworkModeService()),
        ChangeNotifierProvider(create: (_) => NotificationService()),
        ChangeNotifierProvider(create: (_) => BadgeState()),
        ChangeNotifierProvider(create: (_) => NotificationOverlayController()),
      ],
      child: const App(),
    ),
  );
}

// Global navigator key for context access
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    
    return Builder(
      builder: (context) {
        final mq = MediaQuery.of(context);
        final notifController = context.watch<NotificationOverlayController>();
        
        // ✅ Connect overlay controller to AppModel - using post-frame callback to avoid build-time side effects
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (model.notificationController != notifController) {
            model.setNotificationController(notifController);
          }
        });
        
        return MediaQuery(
          data: mq.copyWith(textScaleFactor: model.fontScale),
          child: Directionality(
            textDirection: model.locale.languageCode == 'fa' 
                ? TextDirection.rtl 
                : TextDirection.ltr,
            child: Stack(
              children: [
                MaterialApp(
                  title: 'Raven',
                  navigatorKey: navigatorKey,
                  debugShowCheckedModeBanner: false,
                  locale: model.locale,
                  localizationsDelegates: const [
                    AppLocalizations.delegate,
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  supportedLocales: const [
                    Locale('en'),
                    Locale('es'),
                    Locale('fa'),
                    Locale('zh'),
                    Locale('de'),
                  ],
                  theme: MobileTheme.lightTheme,
                  darkTheme: MobileTheme.darkTheme,
                  themeMode: ThemeMode.system,
                  // ✅ Initialize ToastService with global context
                  builder: (context, child) {
                    ToastService.init(context);
                    return child ?? const SizedBox.shrink();
                  },
                  home: const SplashScreen(),
                  routes: {
                    '/welcome': (context) => const WelcomeScreen(),
                    '/onboarding': (context) => const OnboardingScreen(),
                    '/signin': (context) => const SignInScreen(),
                    '/signup': (context) => const EmailStepScreen(),  // New multi-step flow
                    '/signup-legacy': (context) => const SignUpScreen(),  // Old flow for OAuth fallback
                    '/registration': (context) => const RegistrationScreen(),
                    '/home': (context) => const HomePage(),
                    '/email-verification': (context) => const EmailVerificationScreen(),
                    '/forgot-password': (context) => const ForgotPasswordScreen(),
                    '/privacy-policy': (context) => const PrivacyPolicyPage(),
                    '/splash': (context) => const SplashScreen(),
                  },
                ),
                
                // ✅ Global Toast Popup (anchored to Bell)
                NotificationToastWidget(
                  toast: notifController.currentToast,
                  bellRect: notifController.bellRect,
                  onTap: () {
                    final toast = notifController.currentToast;
                    if (toast != null) {
                      notifController.handleToastTap(context, toast);
                    }
                  },
                ),
                
                // ✅ Global Notification Panel (anchored to Bell)
                NotificationPanelWidget(
                  isOpen: notifController.isOpen,
                  items: notifController.items,
                  bellRect: notifController.bellRect,
                  onClose: () => notifController.close(),
                  onClearAll: () => notifController.clearAll(),
                  onItemTap: (n) {
                    if (n.type == OverlayNotificationType.message) {
                      notifController.close();
                      // Navigate to chat
                      if (n.roomId != null) {
                        navigatorKey.currentState?.pushNamed(
                          '/chat',
                          arguments: {
                            'roomId': n.roomId,
                            'peerUserId': n.peerUserId,
                            'username': n.peerUsername,
                          },
                        );
                      }
                    }
                  },
                  onFriendRequestAction: (notifId, requesterId, accept) async {
                    HapticFeedback.mediumImpact();
                    // ✅ FIX: Capture model BEFORE any async operations to avoid BuildContext issues
                    final model = context.read<AppModel>();
                    
                    try {
                      if (accept) {
                        // ✅ FIX: Use notifId (friend_request ID) instead of requesterId (user ID)!
                        // notifId = friend_request ID from server
                        // requesterId = user ID of the person who sent the request
                        await ApiService.acceptFriendRequest(notifId);
                        
                        // Step 2: Remove notification
                        notifController.remove(notifId);
                        
                        // Step 3: Get requester info for prompt
                        // ✅ Also fix the lookup - compare notification id OR friend_request_id from data
                        final requesterUsername = model.notifications
                            .firstWhere((n) => n.id == notifId || n.data?['friend_request_id'] == notifId,
                                orElse: () => AppNotification(
                                  id: '', title: 'User', body: '', 
                                  type: NotificationType.friendRequest,
                                  timestamp: DateTime.now(),
                                ))
                            .title;
                        
                        // Step 4: Show follow-back prompt
                        if (context.mounted) {
                          final wantsFollowback = await showFollowBackPrompt(
                            context,
                            username: requesterUsername,
                          );
                          
                          // Step 5: If yes, send followback request
                          if (wantsFollowback) {
                            await ApiService.sendFollowbackRequest(requesterId);
                            if (context.mounted) {
                              ToastService.showSuccess('Follow-back request sent to @$requesterUsername!');
                            }
                          }
                        }
                        
                        // Refresh contacts
                        model.fetchNotifications();
                        model.refreshFriendsList();
                      } else {
                        // ✅ FIX: Use notifId (friend_request ID) instead of requesterId
                        await ApiService.rejectFriendRequest(notifId);
                        notifController.remove(notifId);
                        // ✅ Use already-captured model instead of context.read after await
                        model.fetchNotifications();
                      }
                    } catch (e) {
                      print('Friend request action failed: $e');
                    }
                  },
                ),
                
                // ✅ Network Mode Toast (WiFi/Mesh switch)
                const NetworkModeToast(child: SizedBox.shrink()),
              ],
            ),
          ),
        );
      },
    );
  }
}

// SplashScreen moved to screens/splash_screen.dart

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late PageController _pageController;
  late AnimationController _bottomBarAnimationController;
  late Animation<double> _bottomBarHeightAnimation;
  late Animation<double> _bottomBarWidthAnimation;
  late Animation<double> _bottomBarRadiusAnimation;
  late Animation<double> _bottomBarOpacityAnimation;
  
  int _selectedIndex = 0;
  bool _isBottomBarVisible = true;
  double _lastScrollOffset = 0;
  
  static const _tabTitles = ['Home', 'Messages', 'Search', 'Account'];
  
  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _selectedIndex);
    
    // Initialize animation controller for vortex effect
    _bottomBarAnimationController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    
    // Height animation: 56 → 20 (vortex point) - Golden Ratio based
    _bottomBarHeightAnimation = Tween<double>(
      begin: 56.0,  // GoldenRatio.dockHeight
      end: 20.0,    // GoldenRatio.dockCollapsedSize
    ).animate(CurvedAnimation(
      parent: _bottomBarAnimationController,
      curve: Curves.easeInOutCubic,
    ));
    
    // Width animation: full → 20 (circular point)
    _bottomBarWidthAnimation = Tween<double>(
      begin: 1.0, // percentage of screen width
      end: 0.0, // will use 20px fixed
    ).animate(CurvedAnimation(
      parent: _bottomBarAnimationController,
      curve: Curves.easeInOutCubic,
    ));
    
    // Border radius: 0 → 10 (circular)
    _bottomBarRadiusAnimation = Tween<double>(
      begin: 0.0,
      end: 10.0,
    ).animate(CurvedAnimation(
      parent: _bottomBarAnimationController,
      curve: Curves.easeInOutCubic,
    ));
    
    // Opacity animation for content fade
    _bottomBarOpacityAnimation = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _bottomBarAnimationController,
      curve: Curves.easeInOut,
    ));
    
    // ✅ Wire SyncService to refresh inbox when new messages arrive
    // Store reference to avoid context issues
    final appModel = context.read<AppModel>();
    SyncService.instance.setOnInboxUpdateCallback(() {
      print('🔔 [HomePage] SyncService callback triggered → refreshing inbox');
      appModel.refreshInbox();
    });
  }

  
  @override
  void dispose() {
    _pageController.dispose();
    _bottomBarAnimationController.dispose();
    super.dispose();
  }
  
  void _handleScroll(ScrollNotification notification) {
    // Only handle scroll updates on Home tab (index 0)
    if (_selectedIndex != 0) return;
    
    if (notification is ScrollUpdateNotification) {
      final currentOffset = notification.metrics.pixels;
      final delta = currentOffset - _lastScrollOffset;
      
      // Higher threshold to prevent jitter (15px instead of 3px)
      // Scroll up (delta > 0) → hide bar (vortex)
      if (delta > 15 && _isBottomBarVisible) {
        setState(() {
          _isBottomBarVisible = false;
        });
        _bottomBarAnimationController.forward();
      }
      // Scroll down (delta < 0) → show bar
      else if (delta < -15 && !_isBottomBarVisible) {
        setState(() {
          _isBottomBarVisible = true;
        });
        _bottomBarAnimationController.reverse();
      }
      
      _lastScrollOffset = currentOffset;
    }
    
    // Also show bar when scroll ends
    if (notification is ScrollEndNotification) {
      if (!_isBottomBarVisible) {
        setState(() {
          _isBottomBarVisible = true;
        });
        _bottomBarAnimationController.reverse();
      }
    }
  }
  
  void _onPageChanged(int index) {
    setState(() {
      _selectedIndex = index;
    });
    
    // Show bar when switching tabs
    if (!_isBottomBarVisible) {
      setState(() {
        _isBottomBarVisible = true;
      });
      _bottomBarAnimationController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Bottom bar height calculation
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    final dockHeight = DeviceOptimizationService.getDockHeight(context);
    final bottomNavHeight = (dockHeight + 16).clamp(0.0, 200.0);
    
    return Scaffold(
      extendBody: true, // ✅ محتوا پشت داک هم رندر میشه
      backgroundColor: iOSDesignSystem.baseBackground,
      resizeToAvoidBottomInset: true,
      body: Stack(
        children: [
          // Main content - extends to bottom, dock floats over it
          Positioned.fill(
            bottom: 0, // ✅ محتوا تا ته صفحه میاد
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                _handleScroll(notification);
                return true;
              },
              child: PageView(
                controller: _pageController,
                physics: const BouncingScrollPhysics(),
                onPageChanged: _onPageChanged,
                children: [
                  HomeTab(currentTab: _selectedIndex),
                  const MessagesPage(),
                  const SearchPage(),
                  const AccountSettingsPage(),
                ],
              ),
            ),
          ),
          
          // Sliding Bottom Bar
          AnimatedBuilder(
            animation: _bottomBarAnimationController,
            builder: (context, child) {
              final progress = _bottomBarAnimationController.value;
              final slideOffset = progress * 100;
              final barBottom = (bottomPadding + 8 - slideOffset).clamp(-100.0, 200.0);
              
              return Positioned(
                left: 16,
                right: 16,
                bottom: barBottom,
                child: Container(
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.1),
                      width: 0.5,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: FloatingGlassDock(
                        selectedIndex: _selectedIndex,
                        onTap: (index) {
                          _pageController.animateToPage(
                            index,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}


// Old ChatPage removed


class _ChatPageState extends State<ChatPage> {
  final _msgCtrl = TextEditingController();
  
  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final l10n = AppLocalizations.of(context)!;
    
    final isFriend = model.isCurrentChatFriend;
    final msgCount = model.currentChatMsgCount;
    final limitReached = false; // LIMIT REMOVED per user request
    
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF89CFF0), Color(0xFFF0F8FF)],
        )
      ),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(limitReached && !model.currentChatPeerSharesName ? "Anonymous" : model.currentChatName),
              Text(
                 "Mesh Peers: ${model.meshPeers.length}", 
                 style: const TextStyle(fontSize: 10, color: Colors.white70)
              ),
              Text(isFriend ? l10n.youAreFriends : (limitReached ? l10n.limitReached : ""), 
                   style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
            ],
          )
        ),
        body: Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: model.messages.length,
                itemBuilder: (_, i) {
                  final m = model.messages[i];
                  final isMe = m.senderId == model.currentUser?.id;
                  
                  if (m.text == "<<FRIEND_REQUEST>>") {
                    return Center(
                      child: GlassContainer(
                        color: Colors.yellow,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            Text(l10n.wantsToBeFriends(m.senderName)),
                            if (!isMe && !isFriend)
                              TextButton(onPressed: () => model.acceptFriend(m.senderId), child: Text(l10n.accept))
                            else if (isFriend)
                              Text(l10n.youAreFriends)
                          ],
                        ),
                      ),
                    );
                  }
                  
                  if (m.text == "<<SCREENSHOT_TAKEN>>") {
                    return Center(
                      child: GlassContainer(
                        color: Colors.redAccent,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                        padding: const EdgeInsets.all(8),
                        child: Text(l10n.screenshotDetected, style: const TextStyle(color: Colors.white)),
                      ),
                    );
                  }
                  
                  
                  // New Chat Bubble Styling (VisionOS)
                  return Align(
                    alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                    child: GlassContainer(
                      color: isMe ? Colors.blueAccent : Colors.white, 
                      // If 'isMe', we want it to look "active blue glass", else "frosted white glass"
                      // Our GlassContainer ignores 'color' slightly due to gradient override, 
                      // let's rely on the gradient logic we added or key opacity
                      opacity: isMe ? 0.3 : 0.2, 
                      margin: const EdgeInsets.all(6),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(20),
                        topRight: const Radius.circular(20),
                        bottomLeft: isMe ? const Radius.circular(20) : const Radius.circular(5),
                        bottomRight: isMe ? const Radius.circular(5) : const Radius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!isMe) Text(m.senderName, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                          Text(m.text, style: const TextStyle(color: Colors.black87, fontSize: 16)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
              if (limitReached && !isFriend)
               // Removed limit UI but keeping logic block commented or empty if cleaner,
               // actually let's just remove the block entirely.
               // Since replacing with empty string might leave gaps, I will replace with SizedBox.
               const SizedBox.shrink(),
            // Input Row
            Padding(
              padding: const EdgeInsets.all(16),
              child: FutureBuilder<bool>(
                future: model.canSendToCurrentChat(),
                builder: (context, snapshot) {
                  final canSend = snapshot.data ?? true;
                  final needsRequest = model.currentChatNeedsFriendRequest;
                  
                  if (!canSend && needsRequest) {
                    // Show friend request button instead
                    return GlassContainer(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          Text(l10n.messageLimitReached, style: const TextStyle(color: Colors.amber)),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: () => model.sendFriendRequest(),
                            icon: const Icon(Icons.person_add),
                            label: Text(l10n.sendFriendRequest),
                          ),
                        ],
                      ),
                    );
                  }
                  
                  return Row(
                    children: [
                      Expanded(
                        child: GlassContainer(
                          child: TextField(
                            controller: _msgCtrl, 
                            decoration: InputDecoration(
                              hintText: l10n.typeMessage,
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16)
                            )
                          ),
                        )
                      ),
                      const SizedBox(width: 8),
                      // Send Method Selector
                      SendMethodSelector(
                        selectedMethod: model.selectedSendMethod,
                        bluetoothAvailable: model.bluetoothAvailable,
                        wifiAvailable: model.wifiAvailable,
                        onMethodChanged: (method) => model.setSendMethod(method),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () { 
                          final text = _msgCtrl.text.trim(); 
                          if (text.isNotEmpty) { 
                             _msgCtrl.clear(); 
                             model.send(text); 
                          }
                        }, 
                        child: const Icon(Icons.send)
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AppModel extends ChangeNotifier {
  final DatabaseHelper _db = DatabaseHelper.instance;
  final MessageRouter _router = MessageRouter.instance;
  final SyncManager _syncManager = SyncManager();
  
  User? currentUser;
  String currentChatId = 'general';
  String currentChatName = 'General';
  
  /// Get avatar URL for current chat (looks up from friends list)
  String? get currentChatAvatarUrl {
    try {
      final friend = _friends.firstWhere(
        (f) => f['user_id'] == currentChatId || f['id'] == currentChatId,
        orElse: () => {},
      );
      return friend['avatar_url'] as String?;
    } catch (_) {
      return null;
    }
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // REAL-TIME INBOX STREAM (for MessagesPage)
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// StreamController for inbox updates - emits whenever conversations change
  final _inboxController = StreamController<List<Contact>>.broadcast();
  
  /// Last inbox data for immediate access (BehaviorSubject pattern)
  List<Contact> _lastInboxData = [];
  List<Contact> get lastInboxData => _lastInboxData;
  
  /// Stream of inbox conversations (subscribe in MessagesPage)
  /// Wraps the raw stream to immediately emit last value on subscribe
  Stream<List<Contact>> get inboxStream async* {
    // Emit last known data immediately
    if (_lastInboxData.isNotEmpty) {
      yield _lastInboxData;
    }
    // Then yield all future updates
    await for (final data in _inboxController.stream) {
      yield data;
    }
  }
  
  /// Refresh inbox and emit to stream
  Future<void> refreshInbox() async {
    try {
      final individuals = await DatabaseHelper.instance.getIndividualChats();
      final groups = await DatabaseHelper.instance.getGroupChats();
      final combined = [...groups, ...individuals];
      
      // ✅ Store for immediate access
      _lastInboxData = combined;
      
      // ✅ Emit to all listeners
      _inboxController.add(combined);
      print('📬 [AppModel] Inbox refreshed: ${groups.length} groups, ${individuals.length} individuals → emitted to stream');
    } catch (e) {
      print('❌ [AppModel] refreshInbox error: $e');
    }
  }
  
  /// Dispose inbox stream (call when app closes)
  void disposeInboxStream() {
    _inboxController.close();
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // REAL-TIME CHAT MESSAGES STREAM (for ChatPage)
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// StreamController for chat message updates - emits whenever messages change
  final _chatMessagesController = StreamController<List<ChatMessage>>.broadcast();
  
  /// Stream of chat messages for current room (subscribe in ChatPage)
  Stream<List<ChatMessage>> get chatMessagesStream => _chatMessagesController.stream;
  
  /// Emit current chat messages to stream (call after any message change)
  void emitChatUpdate() {
    if (currentUser == null || currentChatId.isEmpty) return;
    
    final roomId = _getRoomId(currentUser!.id, currentChatId);
    final roomMessages = messages.where((m) => m.roomId == roomId).toList();
    roomMessages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    _chatMessagesController.add(roomMessages);
    print('💬 [AppModel] Chat stream emitted: ${roomMessages.length} messages for $roomId');
  }
  
  /// Dispose chat messages stream (call when app closes)
  void disposeChatMessagesStream() {
    _chatMessagesController.close();
  }

  Locale _locale = const Locale('en');

  Locale get locale => _locale;
  
  // Font Scale Factor (0.85 = Small, 1.0 = Medium, 1.15 = Large, 1.3 = Extra Large)
  double _fontScale = 1.0;
  double get fontScale => _fontScale;
  
  // AI Internet Search (for fact-checking)
  bool _aiSearchEnabled = true;  // Default ON
  bool get aiSearchEnabled => _aiSearchEnabled;

  final List<ChatMessage> messages = [];
  final List<String> meshPeers = [];
  final List<AppNotification> _notifications = [];
  final List<Map<String, dynamic>> _friends = []; // List of accepted friends
  
  // ✅ Pending mesh pairing requests (for Nearby People screen)
  final Map<String, Map<String, dynamic>> _pendingPairings = {};
  List<Map<String, dynamic>> get pendingPairings => _pendingPairings.values.toList();
  
  // ═══════════════════════════════════════════════════════════════════════════
  // LIVE CHAT REFRESH (Real-time updates when chat is open)
  // ═══════════════════════════════════════════════════════════════════════════
  Timer? _chatLiveTimer;
  String? _livePeerId;
  
  /// Check if a message belongs to the currently open chat
  bool _isMessageForOpenChat(ChatMessage m) {
    if (currentUser == null) return false;
    final me = currentUser!.id;
    final peer = currentChatId;
    
    // Individual chat: message between me and peer
    final betweenMeAndPeer =
        (m.senderId == peer && m.recipientId == me) ||
        (m.senderId == me && m.recipientId == peer);
    
    // Group chat: message roomId matches currentChatId (for groups)
    final isGroupChat = m.roomId.startsWith('group_') && m.roomId == currentChatId;
    
    return betweenMeAndPeer || isGroupChat;
  }
  
  /// Start live polling for the current chat (call when ChatPage opens)
  void startLiveChat(String peerId) {
    stopLiveChat();
    _livePeerId = peerId;
    log('🔄 [LiveChat] Started for peer: $peerId');
    
    _chatLiveTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (currentUser == null || _livePeerId == null) return;
      if (currentChatId != _livePeerId) return; // User changed chat
      
      await refreshCurrentChatFromServer();
    });
  }
  
  /// Stop live polling (call when ChatPage closes)
  void stopLiveChat() {
    if (_chatLiveTimer != null) {
      log('🔄 [LiveChat] Stopped');
    }
    _chatLiveTimer?.cancel();
    _chatLiveTimer = null;
    _livePeerId = null;
  }
  
  /// Refresh current chat from server (for WiFi mode)
  Future<void> refreshCurrentChatFromServer() async {
    if (currentUser == null || currentChatId.isEmpty) return;
    
    try {
      final serverMessages = await ApiService.getMessages(currentChatId);
      if (serverMessages.isEmpty) return;
      
      final roomId = _getRoomId(currentUser!.id, currentChatId);
      bool changed = false;
      
      for (final msgJson in serverMessages) {
        final msgId = msgJson['id'] as String?;
        if (msgId == null) continue;
        
        // Skip if already in memory
        if (messages.any((m) => m.id == msgId)) continue;
        
        // ✅ Parse message type from server
        final serverType = msgJson['message_type'] as String? ?? 'text';
        MessageType msgType = MessageType.text;
        if (serverType == 'voice') msgType = MessageType.voice;
        else if (serverType == 'image') msgType = MessageType.image;
        else if (serverType == 'file') msgType = MessageType.file;
        
        final msg = ChatMessage(
          id: msgId,
          senderId: msgJson['sender_id'] as String? ?? '',
          recipientId: msgJson['recipient_id'] as String? ?? '',
          senderName: msgJson['sender_name'] as String? ?? 'Unknown',
          roomId: roomId,
          text: msgJson['content'] as String? ?? '',
          timestamp: DateTime.tryParse(msgJson['created_at'] ?? '') ?? DateTime.now().toUtc(),
          status: MessageStatus.delivered,
          type: msgType,
          via: 'wifi',
          // ✅ Parse media fields for file/image/voice messages
          audioUrl: msgJson['audio_url'] as String?,
          fileName: msgJson['file_name'] as String?,
          mimeType: msgJson['mime_type'] as String?,
        );
        
        // Insert to DB (dedupe happens there)
        await _db.insertMessage(msg);
        
        // Add to memory
        messages.add(msg);
        changed = true;
        log('📥 [LiveChat] New message from ${msg.senderName}');
      }
      
      if (changed) {
        messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        notifyListeners();
        emitChatUpdate(); // ✅ Trigger ChatPage stream update
      }
    } catch (e) {
      // Silent fail - network might be down
    }
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // HAPTIC MENU ACTION STATE
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Home feed mode: 0 = Local, 1 = Friends
  int _homeFeedMode = 0;
  int get homeFeedMode => _homeFeedMode;
  
  /// Flag to trigger search field focus when navigating to Search tab
  bool _shouldFocusSearchField = false;
  bool get shouldFocusSearchField => _shouldFocusSearchField;
  void consumeSearchFieldFocus() {
    _shouldFocusSearchField = false;
  }
  
  /// Set home feed mode from Haptic Menu
  void setHomeFeedMode(int mode) {
    if (_homeFeedMode != mode) {
      _homeFeedMode = mode;
      print('📱 [AppModel] Feed mode changed to: ${mode == 0 ? "Local" : "Friends"}');
      notifyListeners();
    }
  }
  
  /// Trigger search field focus when navigating to Search tab
  void triggerSearchFieldFocus() {
    _shouldFocusSearchField = true;
    notifyListeners();
  }
  
  /// Mark all messages as read (clear all unread counts)
  Future<void> markAllMessagesRead() async {
    print('✅ [AppModel] Marking all messages as read...');
    final db = await _db.database;
    await db.update(
      'contacts',
      {'unreadCount': 0},
      where: 'unreadCount > 0',
    );
    notifyListeners();
  }
  
  // ══════════════════════════════════════════════════════════════
  // MULTI-ACCOUNT SWITCH (Double-tap on Profile icon)
  // ══════════════════════════════════════════════════════════════
  
  /// Switch to next account in the stored accounts list
  /// Returns {'success': true, 'username': '...'} if switch was successful
  /// Returns null if only one account exists
  Future<Map<String, dynamic>?> switchToNextAccount() async {
    print('🔄 [AppModel] switchToNextAccount called');
    
    // Get list of stored accounts from SecureStorage
    final accountsJson = await _secureStorage.read(key: 'accounts_list');
    if (accountsJson == null || accountsJson.isEmpty) {
      print('📱 [AppModel] No multiple accounts stored');
      return null;
    }
    
    try {
      final List<dynamic> accounts = jsonDecode(accountsJson);
      if (accounts.length < 2) {
        print('📱 [AppModel] Only one account, nothing to switch');
        return null;
      }
      
      // Find current account index
      final currentId = currentUser?.id;
      int currentIndex = accounts.indexWhere((a) => a['id'] == currentId);
      if (currentIndex == -1) currentIndex = 0;
      
      // Get next account (circular)
      final nextIndex = (currentIndex + 1) % accounts.length;
      final nextAccount = accounts[nextIndex] as Map<String, dynamic>;
      
      print('🔄 [AppModel] Switching from account $currentIndex to $nextIndex: ${nextAccount['username']}');
      
      // Load the new account
      final newUser = User(
        id: nextAccount['id'] as String,
        username: nextAccount['username'] as String,
        email: nextAccount['email'] as String?,
        avatarPath: nextAccount['avatarPath'] as String?,
        createdAt: DateTime.now(),
      );
      
      // Update token
      final token = nextAccount['token'] as String?;
      if (token != null) {
        await _secureStorage.write(key: 'jwt_token', value: token);
        await _secureStorage.write(key: 'user_id', value: newUser.id);
      }
      
      // Set new current user
      currentUser = newUser;
      
      // Clear in-memory data for old account
      messages.clear();
      currentChatId = '';
      
      // ✅ FIX: Restart mesh with new user identity
      await _initMesh();
      
      notifyListeners();
      
      print('✅ [AppModel] Switched to @${newUser.username}');
      
      return {
        'success': true,
        'username': newUser.username,
        'avatarPath': newUser.avatarPath,
      };
    } catch (e) {
      print('❌ [AppModel] switchToNextAccount error: $e');
      return null;
    }
  }
  
  /// Show "Welcome back, @username" toast via notification overlay
  void showAccountSwitchToast(String username) {
    if (_notificationController == null) {
      print('⚠️ [AppModel] No notification controller for toast');
      return;
    }
    
    print('🔔 [AppModel] Showing account switch toast for @$username');
    
    _notificationController!.add(
      OverlayNotification(
        id: 'account_switch_${DateTime.now().millisecondsSinceEpoch}',
        type: OverlayNotificationType.other,
        title: 'Raven',
        body: 'Welcome back, @$username',
        time: DateTime.now(),
      ),
    );
  }
  
  /// Add current account to accounts list (call after login/register)
  Future<void> saveCurrentAccountToList() async {
    if (currentUser == null) return;
    
    final token = await _secureStorage.read(key: 'jwt_token');
    
    // Get existing accounts
    final accountsJson = await _secureStorage.read(key: 'accounts_list');
    List<dynamic> accounts = [];
    if (accountsJson != null && accountsJson.isNotEmpty) {
      try {
        accounts = jsonDecode(accountsJson);
      } catch (_) {}
    }
    
    // Remove existing entry for this user (if any)
    accounts.removeWhere((a) => a['id'] == currentUser!.id);
    
    // Add current account
    accounts.add({
      'id': currentUser!.id,
      'username': currentUser!.username,
      'email': currentUser!.email,
      'avatarPath': currentUser!.avatarPath,
      'token': token,
    });
    
    // Save updated list
    await _secureStorage.write(
      key: 'accounts_list',
      value: jsonEncode(accounts),
    );
    
    print('📱 [AppModel] Saved account to list: ${currentUser!.username} (${accounts.length} total)');
  }

  // ✅ Notification overlay controller (set from main when Provider is available)
  NotificationOverlayController? _notificationController;
  NotificationOverlayController? get notificationController => _notificationController;
  void setNotificationController(NotificationOverlayController controller) {
    _notificationController = controller;
    
    // ✅ Set up callback for new messages from SyncService
    SyncService.instance.setOnNewMessageCallback((ChatMessage msg) {
      print('🔔 [AppModel] New message callback received: from=${msg.senderName} room=${msg.roomId}');
      
      // Don't show notification if user is in the same chat
      final currentRoom = currentUser != null 
          ? _getRoomId(currentUser!.id, currentChatId) 
          : '';
      
      print('🔔 [AppModel] currentRoom=$currentRoom currentChatId=$currentChatId');
      
      if (msg.roomId == currentRoom && currentChatId.isNotEmpty) {
        print('🔔 [AppModel] User in same chat, just adding to messages');
        // Just add to messages and notify UI
        if (!messages.any((m) => m.id == msg.id)) {
          messages.add(msg);
          messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
          notifyListeners();
        }
        return;
      }
      
      // Show overlay notification for messages from other chats
      if (!msg.text.startsWith("<<")) {
        print('🔔 [AppModel] Showing notification popup for ${msg.senderName}');
        print('🔔 [AppModel] _notificationController: ${_notificationController != null ? "SET" : "NULL"}');
        
        _notificationController?.add(
          OverlayNotification(
            id: msg.id,
            type: OverlayNotificationType.message,
            title: msg.senderName,
            body: msg.text.length > 50 
                ? '${msg.text.substring(0, 50)}...' 
                : msg.text,
            time: DateTime.now(),
            roomId: msg.roomId,
            peerUserId: msg.senderId,
            peerUsername: msg.senderName,
          ),
        );
      } else {
        print('🔔 [AppModel] Skipping system message (<<)');
      }
      
      // Notify UI about unread count change
      notifyListeners();
    });
  }
  
  // ✅ Secure storage for sensitive data
  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );
  
  List<Map<String, dynamic>> get friends => _friends;
  
  // Auto-refresh timer
  Timer? _autoRefreshTimer;

  
  List<AppNotification> get notifications => _notifications;
  int get unreadNotificationCount => _notifications.where((n) => !n.isRead && n.data?['status'] == 'pending').length;
  
  // Debug Logging
  final List<String> logs = [];
  void log(String msg) {
    final time = DateTime.now().toString().split(' ').last.split('.').first;
    logs.insert(0, "[$time] $msg");
    if (logs.length > 100) logs.removeLast();
    print("📝 $msg");
    notifyListeners();
  }
  
  // ═══════════════════════════════════════════════════════════════════════════
  // UNIFIED MESSAGE UPSERT (dedupe + sort + notify)
  // ═══════════════════════════════════════════════════════════════════════════
  
  /// Add or update a message in the list, maintaining chronological order
  /// This is the ONLY way to add messages to ensure:
  /// 1. No duplicates (by id)
  /// 2. Sorted by timestamp (oldest → newest)
  /// 3. UI gets notified
  void upsertMessage(ChatMessage m) {
    final idx = messages.indexWhere((x) => x.id == m.id);
    if (idx == -1) {
      messages.add(m);
      print('📨 [upsertMessage] Added new message: ${m.id.substring(0, 8)}...');
    } else {
      messages[idx] = m; // Update existing (status change, etc.)
      print('🔄 [upsertMessage] Updated message: ${m.id.substring(0, 8)}...');
    }
    
    // ✅ Always sort by timestamp (oldest → newest)
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    notifyListeners();
    emitChatUpdate(); // ✅ Trigger ChatPage stream update
  }
  
  /// Batch upsert multiple messages (useful for sync/merge)
  void upsertMessages(List<ChatMessage> newMessages) {
    for (final m in newMessages) {
      final idx = messages.indexWhere((x) => x.id == m.id);
      if (idx == -1) {
        messages.add(m);
      } else {
        messages[idx] = m;
      }
    }
    
    // ✅ Sort once after all inserts
    messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    
    print('📨 [upsertMessages] Upserted ${newMessages.length} messages. Total: ${messages.length}');
    notifyListeners();
    emitChatUpdate(); // ✅ Trigger ChatPage stream update
  }
  
  // Event deduplication - prevent duplicate system events
  final Map<String, DateTime> _recentEvents = {};
  
  bool isCurrentChatFriend = false;
  int currentChatMsgCount = 0;
  bool currentChatPeerSharesName = true;
  bool currentChatNeedsFriendRequest = false;
  
  // Send Method Selection
  SendMethod selectedSendMethod = SendMethod.auto;
  bool get bluetoothAvailable => meshPeers.isNotEmpty;
  bool get wifiAvailable => isCurrentChatFriend; // WiFi only for friends
  
  // SOS Mode (Mesh Relay)
  bool relayEnabled = true; // Enable by default
  int maxHops = 5; // Default max hops

  AppModel() {
    // defer mesh start until user is loaded
    _startAutoRefresh();
    _loadLocale();
    _loadFontScale();
    
    // ✅ Start cloud sync
    SyncService.instance.startAutoSync();
  }
  
  /// Load saved locale from SharedPreferences
  Future<void> _loadLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final savedLocale = prefs.getString('locale');
    if (savedLocale != null) {
      _locale = Locale(savedLocale);
      log('🌐 Loaded locale: $savedLocale');
      notifyListeners();
    }
  }
  
  /// Set locale and save to SharedPreferences
  Future<void> setLocale(Locale newLocale) async {
    _locale = newLocale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('locale', newLocale.languageCode);
    log('🌐 Locale changed to: ${newLocale.languageCode}');
    notifyListeners();
  }
  
  /// Load saved font scale from SharedPreferences
  Future<void> _loadFontScale() async {
    final prefs = await SharedPreferences.getInstance();
    final savedScale = prefs.getDouble('fontScale');
    if (savedScale != null) {
      _fontScale = savedScale;
      log('🔤 Loaded font scale: ${savedScale}x');
      notifyListeners();
    }
  }
  
  /// Set font scale and save to SharedPreferences
  Future<void> setFontScale(double scale) async {
    _fontScale = scale.clamp(0.85, 1.3);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fontScale', _fontScale);
    log('🔤 Font scale changed to: ${_fontScale}x');
    notifyListeners();
  }
  
  /// Set AI Internet Search enabled and save to SecureStorage
  Future<void> setAiSearchEnabled(bool enabled) async {
    _aiSearchEnabled = enabled;
    await _secureStorage.write(key: 'ai_search_enabled', value: enabled.toString());
    log('🔍 AI Search enabled: $enabled');
    notifyListeners();
  }
  
  /// Load AI search setting from SecureStorage
  Future<void> _loadAiSearchSetting() async {
    final saved = await _secureStorage.read(key: 'ai_search_enabled');
    if (saved != null) {
      _aiSearchEnabled = saved == 'true';
      log('🔍 Loaded AI Search setting: $_aiSearchEnabled');
    }
  }

  /// Start auto-refresh timer (every 30 seconds) - Posts & Notifications only
  /// NOTE: Messages/Friends sync is handled by SyncService to avoid duplication
  void _startAutoRefresh() {
    // Initialize SyncManager for offline-first sync
    _syncManager.init();
    _syncManager.onSyncStatusChanged = (status) {
      log('🔄 [Sync] $status');
    };
    
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 20), (timer) async {
      if (currentUser != null) {
        print('🔄 Auto-refreshing posts & notifications...');
        
        // Refresh posts only (messages/friends handled by SyncService)
        await getPosts();
        
        // Refresh notifications
        await fetchNotifications();
        
        // NOTE: Friends/messages sync is handled by SyncService every 30s
        // Removed to prevent duplicate network requests
      }
    });
  }
  
  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }
  
  void setSendMethod(SendMethod method) {
    selectedSendMethod = method;
    log("📡 Send method changed to: $method");
    notifyListeners();
  }
  
  void setRelayEnabled(bool enabled) {
    relayEnabled = enabled;
    log("🔄 Relay mode: ${enabled ? 'ON' : 'OFF'}");
    notifyListeners();
  }
  
  void setMaxHops(int hops) {
    maxHops = hops;
    log("🔢 Max hops set to: $hops");
    notifyListeners();
  }
  
  // === FRIEND REQUEST METHODS ===
  
  Future<bool> canSendToCurrentChat() async {
    if (currentUser == null) return false;
    return await _db.canSendMessage(currentUser!.id, currentChatId);
  }
  
  Future<void> sendFriendRequest([String? peerId, BuildContext? context]) async {
    if (currentUser == null) return;
    final targetId = peerId ?? currentChatId;
    if (targetId.isEmpty) return;
    
    log("👥 [sendFriendRequest] START - Sending to $targetId");
    
    // ✅ STEP 1: Call API Server to create friend request (so recipient gets notified)
    try {
      final success = await ApiService.sendFriendRequest(targetId);
      if (success) {
        log("✅ [sendFriendRequest] API call successful - server will notify recipient");
      } else {
        log("⚠️ [sendFriendRequest] API call returned false - recipient may not be notified");
      }
    } catch (e) {
      log("❌ [sendFriendRequest] API call failed: $e");
    }
    
    // ✅ STEP 2: Update local status to "Request Sent"
    await _db.updateFriendStatus(currentUser!.id, targetId, 3);
    log("📝 [sendFriendRequest] Local DB updated: status=3 (Request Sent)");
    
    // ✅ STEP 3: Create local notification for sender
    if (context != null && context.mounted) {
      try {
        final notificationService = context.read<NotificationService>();
        
        final targetDisplay = targetId.length > 8 ? targetId.substring(0, 8) : targetId;
        
        final senderNotification = AppNotification(
          id: const Uuid().v4(),
          type: NotificationType.friendRequestSent,
          title: 'Friend request sent',
          body: 'You sent a friend request to $targetDisplay',
          userId: targetId,
          timestamp: DateTime.now(),
        );
        notificationService.addNotification(senderNotification);
        log("🔔 [sendFriendRequest] Local notification created for sender");
        
      } catch (e) {
        log('❌ [sendFriendRequest] Failed to create local notification: $e');
      }
    }
    
    // ✅ STEP 4: Send mesh system message (for offline/mesh delivery)
    if (peerId != null) {
        await sendToUser(targetId, "<<FRIEND_REQUEST>>");
    } else {
        await send("<<FRIEND_REQUEST>>", context: context);
    }
    log("📤 [sendFriendRequest] Mesh message sent");
    
    if (peerId == null || peerId == currentChatId) {
        currentChatNeedsFriendRequest = false;
    }
    notifyListeners();
    log("✅ [sendFriendRequest] DONE");
  }
  
  Future<void> acceptFriend(String friendId) async {
    try {
      if (currentUser == null) {
        log("❌ Cannot accept friend: No user logged in");
        return;
      }
      
      log("📨 Accepting friend request from $friendId");
      
      // Update status to Friend (1)
      await _db.updateFriendStatus(currentUser!.id, friendId, 1);
      log("✅ Database updated: $friendId is now a friend");
      
      // Send acceptance confirmation message
      await sendToUser(friendId, "<<FRIEND_ACCEPT>>");
      log("📤 Sent FRIEND_ACCEPT message to $friendId");
      
      // Update current chat state if this is the active chat
      if (currentChatId == friendId) {
        isCurrentChatFriend = true;
        log("🔓 WiFi messaging unlocked for $friendId");
      }
      
      notifyListeners();
      log("✅ Friend accept complete!");
    } catch (e, stackTrace) {
      log("❌ Error accepting friend: $e");
      print("Stack trace: $stackTrace");
    }
  }
  
  Future<void> addContact(Contact contact) async {
    await _db.insertContact(contact);
    log("👤 Added contact: ${contact.username}");
    notifyListeners();
  }
  
  /// Set current user from OAuth authentication
  Future<void> setCurrentUserFromOAuth({
    required String userId,
    required String username,
    String? email,
  }) async {
    final user = User(
      id: userId,
      username: username,
      email: email,
      createdAt: DateTime.now(),
    );
    
    await _db.insertUser(user);
    currentUser = user;
    log('✅ OAuth user set: ${user.username}');
    
    // ✅ FIX: Start mesh networking after user is set
    await _initMesh();
    
    notifyListeners();
  }

  
  Future<List<Contact>> getAllContacts() async {
    return await _db.getAllContacts();
  }
  
  /// Debug function to check friend status - call from debug screen
  Future<void> debugFriendStatus(String otherUserId) async {
    if (currentUser == null) {
      print('❌ [DEBUG] No current user');
      return;
    }
    
    print('═══════════════════════════════════════════════════');
    print('🔬 [DEBUG] Friend Status Report');
    print('═══════════════════════════════════════════════════');
    print('👤 Current User: ${currentUser!.username} (${currentUser!.id})');
    print('👥 Other User: $otherUserId');
    print('───────────────────────────────────────────────────');
    
    // 1. Check DB status
    final friendStatus = await _db.getFriendStatus(currentUser!.id, otherUserId);
    print('📊 DB Friend Status: $friendStatus (0=stranger, 1=friend, 2=pending, 3=request_sent)');
    
    // 2. Check areFriends
    final areFriends = await _db.areFriends(otherUserId);
    print('🤝 areFriends(): $areFriends');
    
    // 3. Check getContact
    final contact = await _db.getContact(otherUserId);
    if (contact != null) {
      print('📇 Contact found: ${contact.username} (status=${contact.status})');
    } else {
      print('❌ Contact NOT found in local DB');
    }
    
    // 4. Check in-memory friends list
    final inMemory = _friends.any((f) => f['id'] == otherUserId);
    print('🧠 In-memory _friends list: $inMemory');
    
    // 5. Check getFriendsContacts count
    final friendsContacts = await _db.getFriendsContacts();
    print('👥 Total friends in DB (status=1): ${friendsContacts.length}');
    
    print('═══════════════════════════════════════════════════');
  }
  
  // === POSTS ===
  
  Future<void> createPost(Post post) async {
    print('💾 Creating post via server...');
    
    try {
      // Get location for local visibility posts
      double? latitude;
      double? longitude;
      
      if (post.visibility == PostVisibility.local) {
        try {
          final position = await LocationService.instance.getCurrentPosition();
          if (position != null) {
            latitude = position.latitude;
            longitude = position.longitude;
            print('📍 Got location for local post: ($latitude, $longitude)');
          } else {
            print('⚠️ No location available for local post');
          }
        } catch (e) {
          print('⚠️ Failed to get location: $e');
        }
      }
      
      // Send to server via API
      final success = await ApiService.createPost(
        post,
        latitude: latitude,
        longitude: longitude,
      );
      
      if (success) {
        // Save to local database for caching
        await _db.insertPost(post);
        print('✅ Post created on server and cached locally');
        notifyListeners();
      } else {
        throw Exception('Server rejected post');
      }
    } catch (e) {
      print('❌ Failed to create post: $e');
      rethrow;
    }
  }
  
  Future<List<Post>> getPosts({bool? isLocal, PostSendMethod? sendMethod}) async {
    print('📥 Fetching posts (isLocal: $isLocal)');
    
    // Always try to fetch from server first
    try {
      final serverPosts = await ApiService.getFeed();
      print('📡 Got ${serverPosts.length} posts from server');
      
      // Cache them locally (ignore duplicates silently)
      for (final post in serverPosts) {
        try {
          await _db.insertPost(post);
        } catch (e) {
          // Silently ignore duplicate errors
          if (!e.toString().contains('UNIQUE')) {
            print('⚠️ Error caching post: $e');
          }
        }
      }
      
      // Apply filters based on feed type
      List<Post> filteredPosts = serverPosts;
      
      if (isLocal == true) {
        // LOCAL FEED: Only show PUBLIC posts (not friendsOnly)
        // This respects private account settings
        filteredPosts = serverPosts.where((p) => 
          p.visibility == PostVisibility.public
        ).toList();
        print('🌍 Local feed: ${filteredPosts.length} public posts');
      } else if (isLocal == false) {
        // FRIENDS FEED: Show ALL posts (both public and friendsOnly)
        filteredPosts = serverPosts;
        print('👥 Friends feed: ${filteredPosts.length} posts');
      }
      
      return filteredPosts;
    } catch (e) {
      print('⚠️ Server fetch failed: $e, falling back to local DB');
    }
    
    // Fallback to local DB
    return await _db.getPosts(isLocal: isLocal, sendMethod: sendMethod);
  }
  
  /// Toggle like on a post with optimistic update
  final Map<String, bool> _likeStates = {};  // Cache of like states
  final Map<String, bool> _repostStates = {};  // Cache of repost states
  final Map<String, int> _viewCounts = {};  // Cache of view counts for live updates
  
  bool isPostLiked(String postId, bool serverState) {
    // Return local state if exists, otherwise server state
    return _likeStates[postId] ?? serverState;
  }
  
  bool isPostReposted(String postId, bool serverState) {
    // Return local state if exists, otherwise server state
    return _repostStates[postId] ?? serverState;
  }
  
  /// Get view count for a post (uses cache if available, else server state)
  int getPostViewCount(String postId, int serverCount) {
    return _viewCounts[postId] ?? serverCount;
  }
  
  /// Update cached view count after recording a view
  /// Call this from widgets after ApiService.recordPostView returns
  void updateViewCount(String postId, int count) {
    _viewCounts[postId] = count;
    print('👁️ [AppModel] View count updated for ${postId.substring(0, 8)}... → $count');
    notifyListeners();
  }
  
  Future<void> toggleLike(String postId, bool currentState) async {
    if (currentUser == null) return;
    
    try {
      // Optimistic update - change UI immediately
      _likeStates[postId] = !currentState;
      notifyListeners();
      
      // Send to server
      final response = await ApiService.toggleLike(postId);
      
      if (response != null) {
        // Use server response for accurate state
        _likeStates[postId] = response['is_liked'] as bool;
        print('❤️ Post ${response['action']} - total: ${response['likes']}');
        notifyListeners();
      } else {
        // Revert on failure
        _likeStates[postId] = currentState;
        notifyListeners();
      }
    } catch (e) {
      print('❌ Failed to toggle like: $e');
      // Revert on error
      _likeStates[postId] = currentState;
      notifyListeners();
    }
  }
  
  /// Repost a post (toggle) with optimistic update
  Future<void> repostPost(String postId, bool currentState) async {
    if (currentUser == null) return;
    
    try {
      // Optimistic update - change UI immediately
      _repostStates[postId] = !currentState;
      notifyListeners();
      
      final response = await ApiService.repost(postId);
      
      if (response != null) {
        // Use server response for accurate state
        _repostStates[postId] = response['is_reposted'] as bool;
        print('🔄 Post ${response['action']} - total: ${response['reposts']}');
        notifyListeners();
      } else {
        // Revert on failure
        _repostStates[postId] = currentState;
        notifyListeners();
      }
    } catch (e) {
      print('❌ Failed to repost: $e');
      // Revert on error
      _repostStates[postId] = currentState;
      notifyListeners();
    }
  }

  
  // === NOTIFICATIONS ===
  
  Timer? _notificationPollingTimer;
  
  /// Start 20-second notification polling (call when app enters foreground)
  void startNotificationPolling() {
    _notificationPollingTimer?.cancel();
    _notificationPollingTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => fetchNotifications(),
    );
    print('🔔 [Polling] Started 20s notification polling');
    
    // Immediate first fetch
    fetchNotifications();
  }
  
  /// Stop notification polling (call when app enters background)
  void stopNotificationPolling() {
    _notificationPollingTimer?.cancel();
    _notificationPollingTimer = null;
    print('🔔 [Polling] Stopped notification polling');
  }
  
  // === SCHEDULED MESSAGE WORKER ===
  
  Timer? _scheduledMessageTimer;
  
  /// Start 15-second scheduled message worker (auto-sends due messages)
  void startScheduledMessageWorker() {
    _scheduledMessageTimer?.cancel();
    _scheduledMessageTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _processScheduledMessages(),
    );
    print('⏰ [ScheduleWorker] Started 15s scheduled message worker');
    
    // Immediate first check
    _processScheduledMessages();
  }
  
  /// Stop scheduled message worker
  void stopScheduledMessageWorker() {
    _scheduledMessageTimer?.cancel();
    _scheduledMessageTimer = null;
    print('⏰ [ScheduleWorker] Stopped');
  }
  
  /// Process due scheduled messages and send them
  Future<void> _processScheduledMessages() async {
    final now = DateTime.now().toUtc();
    
    // Find messages that are scheduled and due
    final dueMessages = messages.where((m) =>
      m.sendMode == 'scheduled' &&
      m.status == MessageStatus.scheduled &&
      m.scheduledAtUtc != null &&
      m.scheduledAtUtc!.isBefore(now)
    ).toList();
    
    if (dueMessages.isEmpty) return;
    
    print('⏰ [ScheduleWorker] Found ${dueMessages.length} due messages');
    
    for (final msg in dueMessages) {
      try {
        // Update status to sending
        final idx = messages.indexWhere((m) => m.id == msg.id);
        if (idx == -1) continue;
        
        messages[idx] = messages[idx].copyWith(status: MessageStatus.sending);
        notifyListeners();
        
        // Actually send via API
        print('⏰ [ScheduleWorker] Sending: ${msg.id.substring(0, 8)}...');
        
        final success = await ApiService.sendMessage(
          recipientId: msg.recipientId,
          content: msg.text,
          messageId: msg.id,
          messageType: msg.type.name,
          mediaUrl: msg.audioUrl,  // ✅ Use mediaUrl (generic param)
          fileName: msg.fileName,
          mimeType: msg.mimeType,
          replyToMessageId: msg.replyToMessageId,
          replyToTextPreview: msg.replyToTextPreview,
          replyToSenderName: msg.replyToSenderName,
          replyToType: msg.replyToType?.name,
          sendMode: 'instant',  // Now sending as instant (no longer scheduled)
        );
        
        if (success) {
          messages[idx] = messages[idx].copyWith(
            status: MessageStatus.sent,
            sendMode: 'instant',  // Mark as sent normally
          );
          print('✅ [ScheduleWorker] Sent: ${msg.id.substring(0, 8)}...');
        } else {
          messages[idx] = messages[idx].copyWith(status: MessageStatus.failed);
          print('❌ [ScheduleWorker] Failed: ${msg.id.substring(0, 8)}...');
        }
        
        notifyListeners();
        
        // Update DB
        await DatabaseHelper.instance.updateMessage(messages[idx]);
        
      } catch (e) {
        print('❌ [ScheduleWorker] Error sending ${msg.id}: $e');
      }
    }
  }
  
  /// Fetch ALL notifications from unified endpoint
  Future<void> fetchNotifications() async {
    print('📥 [fetchNotifications] START');
    try {
      // ✅ Fetch from BOTH sources and merge:
      // 1. Unified /api/notifications (messages, likes, comments, mentions)
      // 2. Friend requests from /api/users/friend-requests (separate table)
      final futures = await Future.wait([
        ApiService.getNotifications(),
        ApiService.getFriendRequests(),
      ]);
      
      final unifiedNotifications = futures[0] as List<AppNotification>;
      final friendRequests = futures[1] as List<AppNotification>;
      
      // Merge and sort by timestamp (newest first)
      final allNotifications = [...unifiedNotifications, ...friendRequests];
      allNotifications.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      
      // ✅ Detect NEW notifications (for toast)
      final oldIds = _notifications.map((n) => n.id).toSet();
      final newNotifications = allNotifications.where((n) => !oldIds.contains(n.id)).toList();
      
      _notifications.clear();
      _notifications.addAll(allNotifications);
      
      print('📥 [fetchNotifications] Got ${_notifications.length} total (${unifiedNotifications.length} unified + ${friendRequests.length} friend requests), ${newNotifications.length} NEW');
      
      // ✅ Show toast for NEW notifications (all types)
      if (newNotifications.isNotEmpty && _notificationController != null) {
        for (final notif in newNotifications) {
          // Convert to OverlayNotification for toast
          final overlayType = _toOverlayType(notif.type);
          
          _notificationController!.add(
            OverlayNotification(
              id: notif.id,
              type: overlayType,
              title: notif.title,
              body: notif.body,
              time: notif.timestamp,
              roomId: notif.data?['room_id'],
              peerUserId: notif.data?['sender_id'] ?? notif.userId,
              peerUsername: notif.data?['sender_username'] ?? notif.title,
              requesterId: notif.data?['requester_id'] ?? notif.userId,
              requesterUsername: notif.data?['requester_username'] ?? notif.title,
            ),
          );
          print('🔔 [fetchNotifications] Toast shown for: ${notif.type.name} - ${notif.title}');
        }
      }
      
      notifyListeners();
    } catch (e) {
      print('❌ [fetchNotifications] Failed: $e');
    }
  }
  
  /// Convert NotificationType to OverlayNotificationType
  OverlayNotificationType _toOverlayType(NotificationType type) {
    switch (type) {
      case NotificationType.message:
        return OverlayNotificationType.message;
      case NotificationType.friendRequest:
      case NotificationType.friendRequestSent:
        return OverlayNotificationType.friendRequest;
      case NotificationType.like:
        return OverlayNotificationType.like;
      case NotificationType.comment:
        return OverlayNotificationType.comment;
      case NotificationType.mention:
        return OverlayNotificationType.mention;
      case NotificationType.presence:
        return OverlayNotificationType.presence;
      case NotificationType.deadDrop:
        return OverlayNotificationType.deadDrop;
      case NotificationType.security:
        return OverlayNotificationType.security;
    }
  }
  
  /// Accept friend request - creates contact and enables messaging
  Future<void> acceptFriendRequest(String requestId) async {
    try {
      print('═══════════════════════════════════════════════════');
      print('🤝 [acceptFriendRequest] START');
      print('├── requestId: $requestId');
      print('├── currentUser: ${currentUser?.id}');
      print('═══════════════════════════════════════════════════');
      
      // ✅ Call API and get friend info directly from response
      final result = await ApiService.acceptFriendRequest(requestId);
      
      if (result == null) {
        print('❌ [acceptFriendRequest] API call failed');
        return;
      }
      
      final success = result['success'] == true;
      print('├── API success: $success');
      
      if (success) {
        // ✅ Get friend info directly from server response (no notification lookup needed!)
        final friendUserId = result['friend_id'] as String?;
        final friendUsername = result['friend_username'] as String? ?? 'Friend';
        final friendAvatar = result['friend_avatar'] as String?;
        
        print('├── Friend from server: id=$friendUserId, username=$friendUsername');
        
        if (friendUserId != null && currentUser != null) {
          // ✅ STEP 1: Add to friends list
          final alreadyExists = _friends.any((f) => f['id'] == friendUserId);
          print('├── Already in friends list: $alreadyExists');
          
          if (!alreadyExists) {
            final newFriend = {
              'id': friendUserId,
              'username': friendUsername,
              'avatar_path': friendAvatar,
            };
            _friends.add(newFriend);
            await _saveFriendsToPrefs();
            print('✅ Added to in-memory friends list');
          }
          
          // ✅ STEP 2: Create LOCAL contact with data from server
          print('├── Calling updateFriendStatus...');
          await _db.updateFriendStatus(
            currentUser!.id, 
            friendUserId, 
            1, // FriendStatus.accepted
            username: friendUsername,
            avatarPath: friendAvatar,
          );
          print('✅ Local contact CREATED in DB');
          
          // ✅ Verify it was created
          final verifyContact = await _db.getContact(friendUserId);
          if (verifyContact != null) {
            print('✅ VERIFIED: Contact exists - ${verifyContact.username} (status=${verifyContact.status})');
          } else {
            print('❌ VERIFICATION FAILED: Contact NOT in DB!');
          }
          
          // ✅ STEP 3: If this is current chat, unlock WiFi messaging
          if (currentChatId == friendUserId) {
            isCurrentChatFriend = true;
            print('🔓 [acceptFriendRequest] WiFi messaging unlocked for current chat');
          }
        } else {
          // ⚠️ Server didn't return friend_id - use notification.userId as safe fallback
          print('⚠️ [acceptFriendRequest] No friend_id in response, using notification fallback...');
          
          // Find notification by request ID to get requester_id (which is the correct friend user ID)
          final notif = _notifications.firstWhere(
            (n) => n.data?['friend_request_id'] == requestId || n.id == requestId,
            orElse: () => _notifications.firstWhere(
              (n) => n.id == requestId,
              orElse: () => AppNotification(
                id: '', 
                type: NotificationType.friendRequest, 
                title: '', 
                body: '', 
                timestamp: DateTime.now(),
              ),
            ),
          );
          
          final fallbackUserId = notif.userId;
          final fallbackUsername = notif.title;
          final fallbackAvatar = notif.avatarPath;
          
          print('├── Fallback: userId=$fallbackUserId, username=$fallbackUsername');
          
          if (fallbackUserId != null && fallbackUserId.isNotEmpty && currentUser != null) {
            // ✅ Add to friends list
            final alreadyExists = _friends.any((f) => f['id'] == fallbackUserId);
            if (!alreadyExists) {
              _friends.add({
                'id': fallbackUserId,
                'username': fallbackUsername ?? 'Friend',
                'avatar_path': fallbackAvatar,
              });
              await _saveFriendsToPrefs();
            }
            
            // ✅ Create contact in DB
            await _db.updateFriendStatus(
              currentUser!.id, 
              fallbackUserId, 
              1,
              username: fallbackUsername,
              avatarPath: fallbackAvatar,
            );
            print('✅ Created contact via notification fallback');
            
            // Verify
            final verifyContact = await _db.getContact(fallbackUserId);
            if (verifyContact != null) {
              print('✅ VERIFIED: Contact exists - ${verifyContact.username}');
            }
          } else {
            print('❌ [acceptFriendRequest] No valid fallback ID found');
          }
        }
        
        // ✅ Update notification status
        final notifIndex = _notifications.indexWhere((n) => n.data?['friend_request_id'] == requestId);
        if (notifIndex != -1) {
          _notifications[notifIndex] = _notifications[notifIndex].copyWith(
            data: {..._notifications[notifIndex].data!, 'status': 'accepted'},
          );
        }
        
        // Refresh friends list from server (ensures sync)
        await refreshFriendsList();
        
        // ✅ Sync friend fingerprints so new friend can auto-connect via mesh
        _syncFriendFingerprints();
        
        notifyListeners();
        print('✅ [acceptFriendRequest] DONE');
      }
    } catch (e) {
      print('❌ [acceptFriendRequest] Failed: $e');
    }
  }
  
  /// Reject friend request
  Future<void> rejectFriendRequest(String requestId) async {
    try {
      final success = await ApiService.rejectFriendRequest(requestId);
      if (success) {
        _notifications.removeWhere((n) => n.data?['friend_request_id'] == requestId);
        notifyListeners();
      }
    } catch (e) {
      print('❌ Failed to reject: $e');
    }
  }
  
  /// Refresh friends list from server
  /// Server /api/users/friends returns friends from BOTH directions (sent+received)
  Future<void> refreshFriendsList() async {
    try {
      print('🔍 [refreshFriendsList] START');
      
      // ✅ Get friends from server (returns both directions)
      final serverFriends = await ApiService.getFriends();
      
      print('📥 [refreshFriendsList] Server returned ${serverFriends.length} friends');
      
      // ✅ Detect NEW friends (for toast notification)
      final oldFriendIds = _friends.map((f) => f['id'] as String?).whereType<String>().toSet();
      final newFriends = serverFriends.where((f) {
        final id = f['id'] as String?;
        return id != null && !oldFriendIds.contains(id);
      }).toList();
      
      if (newFriends.isNotEmpty) {
        print('🎉 [refreshFriendsList] ${newFriends.length} NEW friends detected!');
        
        // Show toast for each new friend
        for (final friend in newFriends) {
          final friendName = friend['username'] as String? ?? 'Someone';
          print('🎉 [refreshFriendsList] New friend: $friendName');
          
          // Update local database with proper friend info
          if (currentUser != null) {
            final friendId = friend['id'] as String;
            final friendAvatar = friend['avatar_path'] as String?;
            await _db.updateFriendStatus(
              currentUser!.id, 
              friendId, 
              1, // FriendStatus.accepted
              username: friendName,
              avatarPath: friendAvatar,
            );
            print('✅ [refreshFriendsList] Contact created for $friendName');
          }
          
          // Show overlay notification (if controller available)
          if (_notificationController != null) {
            _notificationController!.add(
              OverlayNotification(
                id: 'friend_accepted_${friend['id']}',
                type: OverlayNotificationType.other,
                title: '$friendName accepted your request!',
                body: 'You are now friends',
                time: DateTime.now(),
              ),
            );
          }
        }
      }
      
      // ✅ CRITICAL FIX: Merge server data with local, don't overwrite if server is empty
      if (serverFriends.isNotEmpty) {
        _friends.clear();
        _friends.addAll(serverFriends);
        await _saveFriendsToPrefs();
        print('✅ [refreshFriendsList] Updated from server: ${_friends.length} friends');
      } else {
        // Server returned empty - DON'T clear local data!
        // Instead, keep local data and also check local DB for friends
        print('⚠️ [refreshFriendsList] Server returned empty, keeping local data');
        
        // Fetch from local DB as backup
        final localFriendsContacts = await _db.getFriendsContacts();
        if (localFriendsContacts.isNotEmpty) {
          for (final contact in localFriendsContacts) {
            final alreadyExists = _friends.any((f) => f['id'] == contact.userId);
            if (!alreadyExists) {
              _friends.add({
                'id': contact.userId,
                'username': contact.username,
                'avatar_path': contact.avatarUrl,
              });
              print('📂 [refreshFriendsList] Added from local DB: ${contact.username}');
            }
          }
          await _saveFriendsToPrefs();
        }
      }
      
      // ✅ CRITICAL: Sync friend fingerprints to mesh trust list
      // This ensures mesh can connect to friends after refresh
      try {
        final friendFps = await ApiService.getFriendFingerprints();
        print('🔐 [refreshFriendsList] Syncing ${friendFps.length} friend fingerprints to mesh');
        
        // ✅ Cache to SharedPreferences for offline use
        if (friendFps.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          final fpList = friendFps.map((f) => f['fingerprint'] as String).where((fp) => fp.isNotEmpty).toList();
          await prefs.setStringList('cached_friend_fingerprints', fpList);
          print('💾 [refreshFriendsList] Cached ${fpList.length} fingerprints to SharedPreferences');
        }
        
        for (final friend in friendFps) {
          final fp = friend['fingerprint'] as String?;
          if (fp != null && fp.isNotEmpty) {
            await MeshBridge.addTrustedPeer(fp);
          }
        }
      } catch (e) {
        print('⚠️ [refreshFriendsList] Failed to sync fingerprints: $e');
      }
      
      print('✅ [refreshFriendsList] DONE - ${_friends.length} friends total');
      notifyListeners();
      
    } catch (e) {
      print('❌ [refreshFriendsList] Server fetch failed: $e');
      // Fallback to local cache on network error
      await _loadFriendsFromPrefs();
      notifyListeners();
    }
  }
  
  /// Save friends to SharedPreferences
  Future<void> _saveFriendsToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final friendsJson = _friends.map((f) => jsonEncode(f)).toList();
      await prefs.setStringList('friends_list', friendsJson);
      print('💾 Saved ${_friends.length} friends to SharedPreferences');
    } catch (e) {
      print('❌ Failed to save friends: $e');
    }
  }
  
  /// Load friends from SharedPreferences
  Future<void> _loadFriendsFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final friendsJson = prefs.getStringList('friends_list') ?? [];
      _friends.clear();
      for (final json in friendsJson) {
        _friends.add(jsonDecode(json) as Map<String, dynamic>);
      }
      print('📂 Loaded ${_friends.length} friends from SharedPreferences');
    } catch (e) {
      print('❌ Failed to load friends: $e');
    }
  }
  
  /// Check if sent friend requests were accepted
  /// This gets called during auto-refresh to detect when someone accepts your request
  Future<void> checkSentFriendRequests() async {
    try {
      // TODO: Ideally we'd call an API like /api/users/friends to get all accepted friends
      // For now, we assume that if someone is in our notifications with status=accepted,
      // they accepted OUR request (but this is not quite right - see below)
      
      // Better approach: check local sent requests and see if we can chat with them
      final prefs = await SharedPreferences.getInstance();
      final sentRequestsJson = prefs.getStringList('sent_friend_requests') ?? [];
      
      if (sentRequestsJson.isEmpty) {
        print('📭 No sent friend requests to check');
        return;
      }
      
      print('🔍 Checking ${sentRequestsJson.length} sent friend requests...');
      
      // For each sent request, check if they're now our friend
      final List<String> acceptedRequests = [];
      
      for (final requestJson in sentRequestsJson) {
        final request = jsonDecode(requestJson) as Map<String, dynamic>;
        final userId = request['user_id'] as String;
        final username = request['username'] as String;
        
        // Check if this user is already in our friends list
        final alreadyFriend = _friends.any((f) => f['id'] == userId);
        
        if (!alreadyFriend) {
          // Try to see if they appear in our notifications as accepted
          // This is a workaround - ideally server would tell us
          final acceptedNotif = _notifications.any((n) => 
            n.userId == userId && n.data?['status'] == 'accepted'
          );
          
          if (acceptedNotif) {
            print('✅ Request to $username was accepted! Adding to friends.');
            _friends.add({
              'id': userId,
              'username': username,
              'avatar_path': null,
            });
            acceptedRequests.add(requestJson);
          }
        } else {
          // Already friends, remove from sent requests
          print('👥 Already friends with $username');
          acceptedRequests.add(requestJson);
        }
      }
      
      // Remove accepted requests from sent list
      if (acceptedRequests.isNotEmpty) {
        final remainingRequests = sentRequestsJson
            .where((r) => !acceptedRequests.contains(r))
            .toList();
        await prefs.setStringList('sent_friend_requests', remainingRequests);
        await _saveFriendsToPrefs();
        
        print('🎉 Added ${acceptedRequests.length} new friends from accepted requests');
        notifyListeners();
      }
    } catch (e) {
      print('❌ Failed to check sent requests: $e');
    }
  }

  
  // === DATABASE RESET ===
  
  Future<void> clearAllData() async {
    try {
      final db = await _db.database;
      
      // Clear all tables
      await db.delete('messages');
      await db.delete('contacts');
      await db.delete('posts');
      await db.delete('message_counts');
      
      // Reset state
      messages.clear();
      meshPeers.clear();
      currentChatId = '';
      currentChatName = '';
      
      log("🗑️ All data cleared!");
      notifyListeners();
    } catch (e) {
      log("❌ Error clearing data: $e");
    }
  }

  /// Delete account permanently - removes server data and local data
  Future<void> deleteAccount() async {
    if (currentUser == null) return;
    
    log('🗑️ [DeleteAccount] Starting account deletion...');
    
    try {
      // Step 1: Delete from server
      await ApiService.deleteAccount();
      log('✅ [DeleteAccount] Server data deleted');
    } catch (e) {
      log('⚠️ [DeleteAccount] Server deletion failed: $e');
      // Continue with local cleanup even if server fails
    }
    
    try {
      // Step 2: Clear local database
      final db = await _db.database;
      await db.delete('messages');
      await db.delete('contacts');
      await db.delete('posts');
      await db.delete('message_counts');
      await db.delete('reports');
      
      // Step 3: Clear SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      
      // Step 4: Clear secure storage
      const secureStorage = FlutterSecureStorage();
      await secureStorage.deleteAll();
      
      // Step 5: Reset state
      stopNotificationPolling();  // ✅ Stop 20-second polling
      currentUser = null;
      messages.clear();
      meshPeers.clear();
      _friends.clear();
      _notifications.clear();
      currentChatId = '';
      currentChatName = '';
      
      log('✅ [DeleteAccount] All local data cleared');
      notifyListeners();
    } catch (e) {
      log('❌ [DeleteAccount] Local cleanup error: $e');
      throw Exception('Failed to delete local data: $e');
    }
  }
  
  // === NICKNAME ===
  
  Future<void> updateContactNickname(String contactId, String? nickname) async {
    try {
      await _db.updateNickname(contactId, nickname);
      log("✏️ Updated nickname for contact $contactId");
      notifyListeners();
    } catch (e) {
      log("❌ Error updating nickname: $e");
    }
  }
  
  // === USER PROFILE ===
  
  Future<void> updateUserProfile({
    String? username,
    String? bio,
    String? avatarPath,
  }) async {
    try {
      if (currentUser == null) return;
      
      final updatedUser = currentUser!.copyWith(
        username: username,
        bio: bio,
        avatarPath: avatarPath,
      );
      
      await _db.updateUser(updatedUser);
      currentUser = updatedUser;
      
      log("✅ Profile updated: username=${updatedUser.username}");
      notifyListeners();
    } catch (e) {
      log("❌ Error updating profile: $e");
    }
  }

  Future<void> togglePrivacy(bool show) async {
     if (currentUser == null) return;
     
     final updated = User(
       id: currentUser!.id, 
       username: currentUser!.username,
       avatarPath: currentUser!.avatarPath,
       showUsername: show,
       createdAt: currentUser!.createdAt,
     );
     await _db.saveUser(updated);
     currentUser = updated;
     notifyListeners();
  }

  Future<void> setCurrentUser(User user) async {
    currentUser = user;
    _router.initialize(user.id);
    
    // RESTART Mesh with correct identity
    log("🔄 Restarting Mesh for ${user.username}");
    await _initMesh(); 
    
    // ✅ Start 20-second notification polling
    startNotificationPolling();
    
    // ✅ Start 15-second scheduled message worker
    startScheduledMessageWorker();
    
    notifyListeners();
  }
  
  Future<void> startChatWith(String id, String name) async {
    currentChatId = id;
    currentChatName = name;
    await _loadChatContext();
  }
  
  Future<void> _loadChatContext() async {
    if (currentUser == null) return;
    
    final roomId = _getRoomId(currentUser!.id, currentChatId);
    
    // ✅ Step 1: Load local messages first (fast)
    final dbMessages = await _db.getMessagesForRoom(roomId);
    messages.clear();
    messages.addAll(dbMessages);
    notifyListeners(); // Show local messages immediately
    
    // ✅ Step 2: Fetch from server and merge (async)
    try {
      log('📥 [_loadChatContext] Fetching messages from server for $currentChatId...');
      final serverMessages = await ApiService.getMessages(currentChatId);
      
      if (serverMessages.isNotEmpty) {
        log('📥 [_loadChatContext] Got ${serverMessages.length} messages from server');
        
        final parsedMessages = <ChatMessage>[];
        for (final msgJson in serverMessages) {
          try {
            // Parse message type from server
            final serverType = msgJson['message_type'] ?? 'text';
            MessageType msgType = MessageType.text;
            if (serverType == 'voice') msgType = MessageType.voice;
            else if (serverType == 'image') msgType = MessageType.image;
            else if (serverType == 'file') msgType = MessageType.file;  // ✅ Added file type
            
            // ✅ Parse timestamp and ensure UTC
            DateTime timestamp = DateTime.tryParse(msgJson['created_at'] ?? msgJson['timestamp'] ?? '') ?? DateTime.now().toUtc();
            if (!timestamp.isUtc) {
              timestamp = timestamp.toUtc();
            }
            
            // Parse server message format
            final msg = ChatMessage(
              id: msgJson['id'] ?? const Uuid().v4(),
              senderId: msgJson['sender_id'] ?? '',
              recipientId: msgJson['recipient_id'] ?? '',
              senderName: msgJson['sender_name'] ?? msgJson['sender_username'] ?? 'Unknown',
              roomId: roomId,
              text: msgJson['content'] ?? msgJson['text'] ?? '',
              timestamp: timestamp,  // ✅ UTC
              status: MessageStatus.delivered,
              type: msgType,
              via: 'wifi',
              audioUrl: msgJson['audio_url'],  // Voice message URL from server
            );
            
            // Insert to local DB (ignore duplicates)
            await _db.insertMessage(msg);
            parsedMessages.add(msg);
          } catch (e) {
            log('⚠️ Error parsing server message: $e');
          }
        }
        
        // ✅ Use batch upsert for efficiency (handles dedupe + sort)
        upsertMessages(parsedMessages);
        log('✅ [_loadChatContext] Merged to ${messages.length} total messages');
      }
    } catch (e) {
      log('⚠️ [_loadChatContext] Server fetch failed: $e (using local only)');
    }
    
    // Load friend status
    final peerId = currentChatId;
    final count = await _db.getMessageCount(currentUser!.id, peerId);
    currentChatMsgCount = count;
    
    // Check if friend
    final isFr = await _db.areFriends(peerId);
    isCurrentChatFriend = isFr;
    
    notifyListeners();
  }
  
  String _getRoomId(String a, String b) {
    if (b == 'broadcast' || b == 'general') return b;
    return (a.compareTo(b) < 0) ? '${a}_$b' : '${b}_$a';
  }

  Future<void> _initMesh() async {
    try {
      if (currentUser == null) {
        log("⚠️ Cannot start Mesh: No user");
        return;
      }
      
      log("🔄 [MESH] Initializing with ${currentUser!.username}...");
      
      // ✅ Initialize MeshRouter for automatic network mode switching
      await MeshRouter.instance.init();
      log("✅ [MESH] MeshRouter initialized - auto-switch enabled");
      
      // ✅ Use DeviceIdentityService for secure fingerprint-based identity
      final deviceIdentity = DeviceIdentityService.instance;
      final fingerprint = await deviceIdentity.getDeviceFingerprint();
      final publicKeyPem = await deviceIdentity.getPublicKeyPem();
      
      // Use short fingerprint for displayName (more readable)
      final displayName = deviceIdentity.getShortFingerprint(fingerprint);
      log("🔐 DisplayName (short fingerprint): $displayName");
      log("🔑 Full fingerprint: ${fingerprint.substring(0, 16)}...");
      
      // Register own identity in IdentityService
      await IdentityService.instance.registerIdentity(
        userId: currentUser!.id,
        publicKey: publicKeyPem,
      );
      
      // ✅ Start Mesh with full cryptographic identity
      try {
        await MeshBridge.start(
          service: "hybrid-msg",
          displayName: displayName,
          fingerprint: fingerprint,    // ✅ ADDED
          publicKey: publicKeyPem,     // ✅ ADDED
        );
        log("🔵 Mesh started with cryptographic identity");
        log("🆔: ${currentUser!.id}");
        log("👤: $displayName");
        
        // ✅ CRITICAL: Automatically trust all friends' fingerprints
        // This ensures mesh can connect to friends without manual QR scanning
        int trustedCount = 0;
        final prefs = await SharedPreferences.getInstance();
        
        // Step 1: Try to load from API (if online)
        List<Map<String, dynamic>> friendFps = [];
        try {
          friendFps = await ApiService.getFriendFingerprints();
          log("🔐 [MESH] Got ${friendFps.length} friend fingerprints from API");
          
          // ✅ CACHE to SharedPreferences for offline use
          if (friendFps.isNotEmpty) {
            final fpList = friendFps.map((f) => f['fingerprint'] as String).where((fp) => fp.isNotEmpty).toList();
            await prefs.setStringList('cached_friend_fingerprints', fpList);
            log("💾 [MESH] Cached ${fpList.length} fingerprints to SharedPreferences");
          }
        } catch (e) {
          log("⚠️ [MESH] API failed: $e");
          
          // ✅ FALLBACK: Load from SharedPreferences cache
          final cached = prefs.getStringList('cached_friend_fingerprints') ?? [];
          if (cached.isNotEmpty) {
            log("📥 [MESH] Loading ${cached.length} cached fingerprints from SharedPreferences");
            friendFps = cached.map((fp) => {'fingerprint': fp, 'username': 'cached'}).toList();
          }
        }
        
        // Step 2: Add all fingerprints to trust list
        for (final friend in friendFps) {
          final fp = friend['fingerprint'] as String?;
          if (fp != null && fp.isNotEmpty) {
            await MeshBridge.addTrustedPeer(fp);
            trustedCount++;
            log("✅ [MESH] Trusted: ${fp.substring(0, 8)}...");
          }
        }
        
        log("🔐 [MESH] Total trusted fingerprints: $trustedCount");
        
        // ✅ Initialize MeshEventDispatcher for mesh networking features
        MeshEventDispatcher.instance.init(
          userId: currentUser!.id,
          fingerprint: fingerprint,
          nickname: displayName,
        );
        log("🌐 [MESH] MeshEventDispatcher initialized");
        
        // ✅ Wire mesh events to in-app notification overlay
        MeshEventDispatcher.instance.onPresenceReceived = ({
          required String id,
          required String nickname,
          String? note,
        }) {
          if (_notificationController != null) {
            log("📍 [MESH→NOTIF] Presence from $nickname");
            _notificationController!.add(
              OverlayNotification.presence(
                id: id,
                nickname: nickname,
                note: note,
              ),
            );
          }
        };
        
        MeshEventDispatcher.instance.onDeadDropReceived = ({
          required String id,
          required String title,
          required String preview,
        }) {
          if (_notificationController != null) {
            log("📦 [MESH→NOTIF] Dead drop: $title");
            _notificationController!.add(
              OverlayNotification.deadDrop(
                id: id,
                title: title,
                preview: preview,
              ),
            );
          }
        };
        
        // ✅ Register device fingerprint with server (when online)
        _registerDeviceWithServer(fingerprint, publicKeyPem);
        
        // ✅ Sync friend fingerprints and add to trusted peers
        _syncFriendFingerprints();
        
        // ✅ Initialize DTN Store-and-Forward system
        DTNConfigService.instance.initialize();
        DTNRouterService.instance.initialize(
          userId: currentUser!.id,
          deviceId: fingerprint,
          sharedSecret: fingerprint,  // Using fingerprint as shared secret for now
        );
        DTNRouterService.instance.connectToMesh();
        log("🔄 [DTN] Store-and-Forward router connected to mesh");
        
      } catch (e) {
        log("⚠️ Mesh initialization failed (non-critical): $e");
        // Continue without mesh networking - app still works
      }
      
      _router.onMessageReceived = (message) async {
        log("📩 Received: ${message.text} from ${message.senderName}");
        
        // Handle System Messages
        if (message.text == "<<FRIEND_REQUEST>>") {
             try {
               log("👥 Friend Request from ${message.senderName}");
               currentChatName = message.senderName; 
               await _updateContactStatus(message.senderId, 2);
               _showNotification("Friend Request from ${message.senderName}");
               
               // Create app notification for receiver
               try {
                 final context = navigatorKey.currentContext;
                 if (context != null) {
                   final notificationService = Provider.of<NotificationService>(context, listen: false);
                   final notification = AppNotification(
                     id: const Uuid().v4(),
                     type: NotificationType.friendRequest,
                     title: '${message.senderName} sent you a friend request',
                     body: 'Accept to start chatting',
                     userId: message.senderId,
                     timestamp: DateTime.now(),
                   );
                   notificationService.addNotification(notification);
                   log('✅ Created friend request notification');
                 }
               } catch (e) {
                 log('⚠️ Notification error: $e');
               }
             } catch (e) { log("❌ Error Friend Request: $e"); }
        }
        else if (message.text == "<<FRIEND_ACCEPT>>") {
             try {
               log("✅ Friend Accept from ${message.senderId}");
               await _handleFriendAccept(message.senderId);
             } catch (e) { log("❌ Error Friend Accept: $e"); }
        }
        else if (message.text == "<<SCREENSHOT_TAKEN>>") {
           log("📸 Screenshot detected form peer");
           _showNotification("User took a screenshot!");
        }

        // Add to UI if valid room
        // ✅ Use _isMessageForOpenChat for better detection (sender/recipient based)
        if (_isMessageForOpenChat(message)) {
          log("💬 Msg for current open chat");
          // ✅ Use upsertMessage for dedupe + sort + notify
          upsertMessage(message);
          // Update count
          if (!message.text.startsWith("<<")) {
             await _db.incrementMessageCount(currentUser!.id, message.senderId);
             currentChatMsgCount = await _db.getMessageCount(currentUser!.id, message.senderId);
          }
          // Note: upsertMessage already calls notifyListeners()
        } else {
           log("⚠️ Msg for different chat, sender=${message.senderId}");
        }
        
        // Notify - show overlay popup for messages from other chats
        if (!_isMessageForOpenChat(message)) {
           if (!message.text.startsWith("<<")) {
              log("🔔 Showing notification for: ${message.senderName}");
              _showNotification("Message from ${message.senderName}", message.text);
              
              // ✅ Also show overlay popup
              if (_notificationController != null) {
                _notificationController!.add(
                  OverlayNotification(
                    id: message.id,
                    type: OverlayNotificationType.message,
                    title: message.senderName,
                    body: message.text.length > 50 
                        ? '${message.text.substring(0, 50)}...' 
                        : message.text,
                    time: DateTime.now(),
                    roomId: message.roomId,
                    peerUserId: message.senderId,
                    peerUsername: message.senderName,
                  ),
                );
                print('🔔 [Overlay] Added message notification from ${message.senderName}');
              }
           }
        }
      };
      
      _router.onSendToMesh = (payload) async { 
        log("📤 Sending to mesh: ${payload.length} bytes");
        await MeshBridge.send(payload); 
      };
      _router.onSendToInternet = (message) async {
        // ✅ Use real API instead of mock
        print("☁️ [AppModel] Sending via Cloud API to ${message.recipientId}...");
        final ok = await ApiService.sendMessage(
          recipientId: message.recipientId,
          content: message.text,
        );
        if (!ok) {
          print("❌ Cloud API send failed");
          throw Exception("Cloud send failed");
        }
        print("✅ Cloud API send successful");
      };
      
      
      MeshBridge.messages().listen((payload) async {
        // Check if peers update
        try {
           if (payload.contains('"type":"peers"')) { // Simple check before full decode
             final json = jsonDecode(payload); 
             if (json['type'] == 'peers') {
                final list = List<String>.from(json['peers']);
                meshPeers.clear();
                meshPeers.addAll(list);
                notifyListeners();
                return;
             }
           }
           
           // ✅ Handle pairing requests from nearby devices
           if (payload.contains('"type":"pairing_request"')) {
             final json = jsonDecode(payload);
             if (json['type'] == 'pairing_request') {
               final peerFingerprint = json['fingerprint'] as String;
               final peerName = json['peerName'] as String;
               final peerPublicKey = json['publicKey'] as String;
               
               log('🔐 [Mesh] Pairing request from $peerName (fp: ${peerFingerprint.substring(0, 16)}...)');
               
               // ✅ Check if this fingerprint is in our cached friend fingerprints
               final prefs = await SharedPreferences.getInstance();
               final cachedFps = prefs.getStringList('cached_friend_fingerprints') ?? [];
               
               bool isFriendFingerprint = cachedFps.any((fp) => 
                 fp == peerFingerprint || 
                 peerFingerprint.startsWith(fp) || 
                 fp.startsWith(peerFingerprint)
               );
               
               // ✅ ALSO check if we have ANY friend contacts (fallback: trust friends with WiFi ON)
               if (!isFriendFingerprint) {
                 final friendContacts = await _db.getFriendsContacts();
                 log('🔍 [Mesh] Checking ${friendContacts.length} friend contacts for auto-trust');
                 
                 // If we have friends and API returned their fingerprints, the fingerprint should be in cache
                 // But if cache is empty and we have friends, try to trust anyway by checking API directly
                 if (cachedFps.isEmpty && friendContacts.isNotEmpty) {
                   log('📡 [Mesh] Cache empty but have ${friendContacts.length} friends - attempting API lookup');
                   try {
                     final friendFps = await ApiService.getFriendFingerprints();
                     isFriendFingerprint = friendFps.any((f) => 
                       f['fingerprint'] == peerFingerprint ||
                       peerFingerprint.startsWith(f['fingerprint'] ?? '')
                     );
                     
                     // Cache for next time
                     if (friendFps.isNotEmpty) {
                       final fpList = friendFps.map((f) => f['fingerprint'] as String).where((fp) => fp.isNotEmpty).toList();
                       await prefs.setStringList('cached_friend_fingerprints', fpList);
                       log('💾 [Mesh] Cached ${fpList.length} fingerprints');
                     }
                   } catch (e) {
                     log('⚠️ [Mesh] API lookup failed: $e');
                   }
                 }
               }
               
               if (isFriendFingerprint) {
                 // ✅ Friends: Auto-accept, no permission needed
                 log('✅ [Mesh] Auto-accepting friend fingerprint: ${peerFingerprint.substring(0, 16)}...');
                 await MeshBridge.addTrustedPeer(peerFingerprint);
                 
                 _showNotification(
                   'Friend Connected',
                   'Connected via Mesh',
                 );
               } else {
                 // ❌ Not friends: Store pending request, user must use Nearby People
                 log('⚠️ [Mesh] Unknown peer $peerName - not in friend fingerprints list');
                 log('⚠️ [Mesh] Cached fingerprints: ${cachedFps.length}');
                 
                 // Store pending pairing for "Nearby People" screen
                 _pendingPairings[peerFingerprint] = {
                   'fingerprint': peerFingerprint,
                   'peerName': peerName,
                   'publicKey': peerPublicKey,
                   'timestamp': DateTime.now().toIso8601String(),
                 };
                 notifyListeners();
               }
               return;
             }
           }
           
           // ═══════════════════════════════════════════════════════════════
           // QR-BASED FRIEND PAIRING HANDLERS
           // ═══════════════════════════════════════════════════════════════
           
           // ✅ Handle FRIEND_PAIR_REQUEST (someone scanned our QR)
           if (payload.contains('"type":"FRIEND_PAIR_REQUEST"')) {
             try {
               final json = jsonDecode(payload);
               if (json['type'] == 'FRIEND_PAIR_REQUEST') {
                 final fromUserId = json['fromUserId'] as String;
                 final fromUsername = json['fromUsername'] as String;
                 final fromDeviceFp = json['fromDeviceFp'] as String;
                 final fromPubKey = json['fromPubKey'] as String;
                 
                 log('📱 [QR] Friend pair request from @$fromUsername');
                 
                 // Check if this is for us
                 if (currentUser == null) return;
                 
                 // Show the approval dialog
                 final context = navigatorKey.currentContext;
                 if (context != null) {
                   final accepted = await FriendPairDialog.show(
                     context: context,
                     requesterUsername: fromUsername,
                     requesterUserId: fromUserId,
                     requesterFingerprint: fromDeviceFp,
                   );
                   
                   if (accepted == true) {
                     // ✅ Accept: Send acceptance and complete friendship
                     log('✅ [QR] Accepting friend request from @$fromUsername');
                     
                     await QrFriendService.instance.sendFriendPairAccept(
                       myUserId: currentUser!.id,
                       myUsername: currentUser!.username,
                       toUserId: fromUserId,
                       toDeviceFp: fromDeviceFp,
                       myAvatarUrl: currentUser!.avatarPath,
                     );
                     
                     // Complete friendship on our side
                     await _completeFriendPairing(
                       theirUserId: fromUserId,
                       theirUsername: fromUsername,
                       theirFingerprint: fromDeviceFp,
                       theirPubKey: fromPubKey,
                     );
                   } else {
                     // ❌ Decline
                     log('❌ [QR] Declining friend request from @$fromUsername');
                     
                     await QrFriendService.instance.sendFriendPairDecline(
                       myUserId: currentUser!.id,
                       toUserId: fromUserId,
                       toDeviceFp: fromDeviceFp,
                     );
                   }
                 }
                 return;
               }
             } catch (e) {
               log('❌ [QR] Error handling FRIEND_PAIR_REQUEST: $e');
             }
           }
           
           // ✅ Handle FRIEND_PAIR_ACCEPT (they accepted our request)
           if (payload.contains('"type":"FRIEND_PAIR_ACCEPT"')) {
             try {
               final json = jsonDecode(payload);
               if (json['type'] == 'FRIEND_PAIR_ACCEPT') {
                 final fromUserId = json['fromUserId'] as String;
                 final fromUsername = json['fromUsername'] as String;
                 final fromDeviceFp = json['fromDeviceFp'] as String;
                 final fromPubKey = json['fromPubKey'] as String;
                 final fromAvatarUrl = json['fromAvatarUrl'] as String?;
                 
                 log('✅ [QR] Friend pair accepted by @$fromUsername');
                 
                 // Complete friendship on our side
                 await _completeFriendPairing(
                   theirUserId: fromUserId,
                   theirUsername: fromUsername,
                   theirFingerprint: fromDeviceFp,
                   theirPubKey: fromPubKey,
                   theirAvatarUrl: fromAvatarUrl,
                 );
                 return;
               }
             } catch (e) {
               log('❌ [QR] Error handling FRIEND_PAIR_ACCEPT: $e');
             }
           }
           
           // ✅ Handle FRIEND_PAIR_DECLINE (they declined our request)
           if (payload.contains('"type":"FRIEND_PAIR_DECLINE"')) {
             try {
               final json = jsonDecode(payload);
               if (json['type'] == 'FRIEND_PAIR_DECLINE') {
                 final fromUserId = json['fromUserId'] as String;
                 
                 log('❌ [QR] Friend pair declined by $fromUserId');
                 
                 // Show decline toast
                 if (_notificationController != null) {
                   _notificationController!.add(
                     OverlayNotification(
                       id: 'friend_decline_$fromUserId',
                       type: OverlayNotificationType.other,
                       title: 'Request Declined',
                       body: 'Friend request was not accepted',
                       time: DateTime.now(),
                     ),
                   );
                 }
                 return;
               }
             } catch (e) {
               log('❌ [QR] Error handling FRIEND_PAIR_DECLINE: $e');
             }
           }
           
           // Handle LOCAL_POST broadcasts
           if (payload.contains('"type":"LOCAL_POST"')) {
             try {
               final json = jsonDecode(payload);
               if (json['type'] == 'LOCAL_POST') {
                 // دریافت post از دستگاه نزدیک
                 final incomingPost = Post(
                   id: json['id'],
                   authorId: json['authorId'],
                   authorName: json['authorName'],
                   content: json['content'],
                   timestamp: DateTime.parse(json['timestamp']),
                   likes: json['likes'] ?? 0,
                   comments: json['comments'] ?? 0,
                   isLocal: true, // همیشه در Local feed
                   sendMethod: Post.parseSendMethod(json['sendMethod']),
                 );
                 
                 // ذخیره در database
                 await _db.insertPost(incomingPost);
                 log('📥 Received Local post from ${incomingPost.authorName}');
                 
                 // Show notification for new post
                 final contentPreview = incomingPost.content.length > 50
                     ? '${incomingPost.content.substring(0, 50)}...'
                     : incomingPost.content;
                 await _showNotification(
                   'New post from ${incomingPost.authorName}',
                   contentPreview,
                 );
                 
                 // Add to in-app notifications
                 try {
                   final context = navigatorKey.currentContext;
                   if (context != null) {
                     final notificationService = Provider.of<NotificationService>(context, listen: false);
                     final notification = AppNotification(
                       id: const Uuid().v4(),
                       type: NotificationType.mention, // Using mention as closest type
                       title: 'New post from ${incomingPost.authorName}',
                       body: contentPreview,
                       userId: incomingPost.authorId,
                       timestamp: DateTime.now(),
                     );
                     notificationService.addNotification(notification);
                   }
                 } catch (e) {
                   log('⚠️ In-app notification error: $e');
                 }
                 
                 notifyListeners();
                 return;
               }
             } catch (e) {
               log('❌ Error processing LOCAL_POST: $e');
             }
           }
           
           // Screenshot is distinct system event, not chat msg
           if (payload.contains('\"type\":\"screenshot\"')) {
             await _handleScreenshot();
             return;
           }
        } catch(e) { /* ignore */ }
        
        // Let Router handle EVERYTHING else (decryption, dedupe, etc)
        _router.handleIncomingMessage(payload); 
      });
    } catch (e, stackTrace) {
      log("❌ Mesh initialization failed: $e");
      log("Stack trace: $stackTrace");
      // Don't crash app - mesh is optional for offline mode
      // User can still create posts and messages locally
    }
  }

  /// Register device fingerprint with server (async, non-blocking)
  Future<void> _registerDeviceWithServer(String fingerprint, String publicKey) async {
    print('🔑 [Identity] Starting device registration...');
    try {
      // Detect platform
      final platform = Platform.isIOS ? 'ios' : 'android';
      
      final success = await ApiService.registerDevice(
        fingerprint: fingerprint,
        publicKey: publicKey,
        platform: platform,
      );
      
      if (success) {
        print('✅ [Identity] Device registered with server');
      } else {
        print('⚠️ [Identity] Device registration failed (will retry later)');
      }
    } catch (e) {
      print('⚠️ [Identity] Could not reach server for device registration: $e');
      // Not critical - device can still work offline
    }
  }

  /// Sync friend fingerprints from server and add to mesh trusted list
  Future<void> _syncFriendFingerprints() async {
    print('🔑 [Identity] Starting friend fingerprints sync...');
    try {
      final friendFingerprints = await ApiService.getFriendFingerprints();
      
      if (friendFingerprints.isEmpty) {
        print('📭 [Identity] No friend fingerprints to sync');
        return;
      }
      
      print('📥 [Identity] Syncing ${friendFingerprints.length} friend fingerprints...');
      
      for (final friend in friendFingerprints) {
        final fingerprint = friend['fingerprint'] as String?;
        final username = friend['username'] as String?;
        
        if (fingerprint != null && fingerprint.isNotEmpty) {
          await MeshBridge.addTrustedPeer(fingerprint);
          print('✅ [Identity] Added trusted peer: ${username ?? "unknown"} (${fingerprint.substring(0, 16)}...)');
        }
      }
      
      print('✅ [Identity] Friend fingerprints synced - friends can auto-connect via mesh');
    } catch (e) {
      print('⚠️ [Identity] Could not sync friend fingerprints: $e');
      // Not critical - app will work with local trusted list from Keychain
    }
  }


  Future<void> _showNotification(String title, [String? body]) async {
    const androidDetails = AndroidNotificationDetails(
      'mesh_channel',
      'Mesh Messages',
      channelDescription: 'Notifications for mesh messages',
      importance: Importance.high,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
    );
    const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
    
    await FlutterLocalNotificationsPlugin().show(
      0,
      title,
      body ?? '',
      details,
    );
  }

  Future<void> _handleScreenshot() async {
    // Deduplicate events within 5-second window
    final now = DateTime.now();
    final eventKey = 'screenshot_${now.millisecondsSinceEpoch ~/ 5000}';
    
    if (_recentEvents.containsKey(eventKey)) {
      log('⚠️ Duplicate screenshot event detected, ignoring');
      return;
    }
    
    _recentEvents[eventKey] = now;
    
    // Cleanup old events (keep last 10)
    if (_recentEvents.length > 10) {
      final oldest = _recentEvents.keys.first;
      _recentEvents.remove(oldest);
    }
    
    print("📸 Screenshot taken by ME. Sending alert.");
    await send("<<SCREENSHOT_TAKEN>>");
  }

  Future<void> send(String text, {BuildContext? context}) async {
    if (currentUser == null) {
      log("❌ Cannot send: No user logged in");
      return;
    }
    
    final roomId = _getRoomId(currentUser!.id, currentChatId);
    final message = ChatMessage(
      id: const Uuid().v4(),
      roomId: roomId,
      senderId: currentUser!.id,
      senderName: currentUser!.username,
      recipientId: currentChatId,
      text: text,
      timestamp: DateTime.now(),
      status: MessageStatus.sent,
      type: MessageType.text,
    );
    
    // ALWAYS save locally first
    try {
      await _db.insertMessage(message);
      // ✅ DEDUPE: Only add if not already in list
      if (!messages.any((m) => m.id == message.id)) {
        messages.add(message);
      }
      notifyListeners();
      log("✅ Message saved locally");
    } catch (e) {
      log("❌ Failed to save message locally: $e");
      return; // Can't proceed without local save
    }
    
    // ✅ Check friend status from DB (always fresh!)
    final isFriendInDb = await _db.areFriends(currentChatId);
    log('🔍 [send] Friend check: isCurrentChatFriend=$isCurrentChatFriend, isFriendInDb=$isFriendInDb');
    
    // Update the variable if DB says different (sync fix)
    if (isFriendInDb && !isCurrentChatFriend) {
      isCurrentChatFriend = true;
      log('🔄 [send] Updated isCurrentChatFriend to true from DB');
    }
    
    // Try WiFi if enabled and we're friends
    if (context != null && isFriendInDb) {
      try {
        final networkMode = context.read<NetworkModeService>();
        log('🌐 [send] WiFi mode: ${networkMode.isWiFiMode}');
        if (networkMode.isWiFiMode) {
          final success = await ApiService.sendMessage(
            recipientId: message.recipientId,
            content: message.text,
            messageId: message.id, // For idempotency
          );
          if (success) {
            log('✅ [send] WiFi send successful');
            return; // Success, we're done
          } else {
            log('❌ [send] WiFi send returned false');
          }
        }
      } catch (e) {
        log('⚠️ [send] WiFi failed: $e, trying Bluetooth');
      }
    } else {
      if (!isFriendInDb) {
        log('⚠️ [send] Not friends in DB - WiFi disabled');
      }
    }
    
    // Bluetooth/Mesh messaging
    if (meshPeers.isNotEmpty) {
      final myId = currentUser!.id;
      final otherId = currentChatId;
      
      // ✅ Check if they are Friends (status=1)
      final friendStatus = await _db.getFriendStatus(myId, otherId);
      final isFriend = (friendStatus == 1);
      
      if (isFriend) {
        // ✅ Friends can ALWAYS message via Mesh - no phone contact required
        log('✅ [send] Friend detected (status=1), Mesh allowed without phone contact check');
      } else {
        // ⚠️ Strangers need phone contact verification (anti-spam)
        final recipient = await _db.getUserById(otherId);
        
        if (recipient != null) {
          final isInPhoneContacts = await ContactService.isInContacts(
            email: recipient.email,
            phone: recipient.phone,
          );
          
          if (!isInPhoneContacts) {
            log('❌ Bluetooth blocked: stranger not in phone contacts');
            
            if (context != null && context.mounted) {
              ToastService.showWarning(
                'Send a friend request first, or add them to phone contacts.',
              );
            }
            return; // Block Mesh send for strangers not in contacts
          }
        }
        log('✅ Stranger in phone contacts, Mesh allowed');
      }
      
      try {
        // ✅ FIX: Use existing message object instead of creating new one in sendToUser
        // This prevents duplicate messages with different IDs
        await _router.sendMessage(message);
        log('✅ Bluetooth/Mesh send successful');
      } catch (e) {
        log('⚠️ Bluetooth/Mesh failed: $e (message saved offline)');
      }
    } else {
      log('⚠️ No mesh peers, message saved offline only');
    }
  }

  /// Send voice message with audio URL
  Future<void> sendVoiceMessage({
    required String recipientId,
    String? audioUrl,           // CDN URL (may be null if upload failed)
    String? localPath,          // Local file path for offline playback
    required Duration duration,
    String? text,
  }) async {
    if (currentUser == null) return;
    
    log('🎤 [sendVoiceMessage] START - recipientId: $recipientId, duration: ${duration.inSeconds}s');
    log('🎤 [sendVoiceMessage] audioUrl: $audioUrl, localPath: $localPath');
    
    final roomId = _getRoomId(currentUser!.id, recipientId);
    
    // Create voice message with both audioUrl and localPath
    final msg = ChatMessage(
      id: const Uuid().v4(),
      roomId: roomId,
      senderId: currentUser!.id,
      senderName: currentUser!.username,
      recipientId: recipientId,
      text: text ?? '🎤 Voice (${duration.inSeconds}s)',
      timestamp: DateTime.now(),
      type: MessageType.voice,
      audioUrl: audioUrl,
      localPath: localPath,  // For offline playback
      audioDurationSeconds: duration.inSeconds,  // ✅ Store real duration
      status: MessageStatus.pending,
      syncState: audioUrl != null ? SyncState.synced : SyncState.localOnly,
    );
    
    // Add to local messages list
    // ✅ DEDUPE: Only add if not already in list
    if (!messages.any((m) => m.id == msg.id)) {
      messages.add(msg);
    }
    notifyListeners();
    
    // Save to local DB
    await _db.insertMessage(msg);
    
    // Update conversation preview
    await _db.touchConversation(
      otherUserId: recipientId,
      otherUsername: currentChatName ?? 'User',
      preview: text ?? '🎤 Voice message',
      time: DateTime.now(),
      incoming: false,
    );
    
    // ✅ Only send via API if audioUrl exists (i.e., upload succeeded)
    // If audioUrl is null, SyncManager will handle upload + sync later
    if (audioUrl != null) {
      try {
        final sent = await ApiService.sendMessage(
          recipientId: recipientId,
          content: msg.text,
          messageId: msg.id,  // ✅ Idempotency key prevents duplicates
          audioUrl: audioUrl,
        );
        if (sent) {
          log('✅ [sendVoiceMessage] Sent via API');
          // Update message status to delivered
          await _db.updateMessageStatus(msg.id, MessageStatus.delivered);
          final idx = messages.indexWhere((m) => m.id == msg.id);
          if (idx != -1) {
            messages[idx] = messages[idx].copyWith(
              status: MessageStatus.delivered,
              syncState: SyncState.synced,
            );
            notifyListeners();
          }
        }
      } catch (e) {
        log('⚠️ [sendVoiceMessage] API send failed: $e');
      }
    } else {
      log('⏳ [sendVoiceMessage] audioUrl is null, will sync later via SyncManager');
    }
    
    log('✅ [sendVoiceMessage] DONE');
  }

  /// Send media message (image or file)
  /// 
  /// Similar to sendVoiceMessage but for images and documents.
  /// Uses the extended ApiService.sendMessage() with messageType and mediaUrl.
  Future<void> sendMediaMessage({
    required String recipientId,
    required String mediaUrl,      // CDN URL from upload
    required String messageType,   // 'image' or 'file'
    String? mimeType,              // e.g., 'image/png', 'application/pdf'
    String? filename,              // Original filename for files
  }) async {
    if (currentUser == null) return;
    
    log('🖼️ [sendMediaMessage] START - recipientId: $recipientId, type: $messageType');
    log('🖼️ [sendMediaMessage] mediaUrl: $mediaUrl, mimeType: $mimeType');
    
    final roomId = _getRoomId(currentUser!.id, recipientId);
    
    // Determine MessageType enum from string
    final msgType = messageType == 'image' ? MessageType.image : MessageType.file;
    
    // ✅ No emoji in stored text - UI bubble adds icon when rendering
    final displayText = messageType == 'image' 
        ? 'Photo' 
        : filename ?? 'Document';
    
    // Create media message
    final msg = ChatMessage(
      id: const Uuid().v4(),
      roomId: roomId,
      senderId: currentUser!.id,
      senderName: currentUser!.username,
      recipientId: recipientId,
      text: displayText,
      timestamp: DateTime.now().toUtc(),
      type: msgType,
      audioUrl: mediaUrl,      // CDN URL for media
      fileName: filename,      // ✅ Store original filename for receiver display
      mimeType: mimeType,      // ✅ Store MIME type for proper file handling
      status: MessageStatus.pending,
      syncState: SyncState.synced,  // Already uploaded
    );
    
    // Add to local messages list (dedupe)
    if (!messages.any((m) => m.id == msg.id)) {
      messages.add(msg);
    }
    notifyListeners();
    
    // Save to local DB
    await _db.insertMessage(msg);
    
    // Update conversation preview
    await _db.touchConversation(
      otherUserId: recipientId,
      otherUsername: currentChatName ?? 'User',
      preview: displayText,
      time: DateTime.now(),
      incoming: false,
    );
    
    // Send via API with proper media type
    try {
      final sent = await ApiService.sendMessage(
        recipientId: recipientId,
        content: displayText,
        messageId: msg.id,
        messageType: messageType,
        mediaUrl: mediaUrl,
        fileName: filename,   // ✅ Send filename for receiver display
        mimeType: mimeType,   // ✅ Send MIME type for proper handling
      );
      
      if (sent) {
        log('✅ [sendMediaMessage] Sent via API');
        // Update message status
        await _db.updateMessageStatus(msg.id, MessageStatus.delivered);
        final idx = messages.indexWhere((m) => m.id == msg.id);
        if (idx != -1) {
          messages[idx] = messages[idx].copyWith(
            status: MessageStatus.delivered,
            syncState: SyncState.synced,
          );
          notifyListeners();
          emitChatUpdate(); // ✅ Trigger ChatPage stream update
        }
      }
    } catch (e) {
      log('⚠️ [sendMediaMessage] API send failed: $e');
    }
    
    log('✅ [sendMediaMessage] DONE');
  }

  /// Send a reply message to another user
  Future<void> sendReplyMessage({
    required String recipientId,
    required String text,
    required ChatMessage replyToMessage,
    String sendMode = 'instant',
    DateTime? scheduledAtUtc,
  }) async {
    if (currentUser == null) return;
    
    log('↩️ [sendReplyMessage] START - replying to: ${replyToMessage.id}');
    
    final roomId = _getRoomId(currentUser!.id, recipientId);
    
    // Create preview text (max 50 chars)
    String previewText;
    if (replyToMessage.type == MessageType.voice) {
      previewText = 'Voice message';
    } else if (replyToMessage.type == MessageType.image) {
      previewText = 'Photo';
    } else if (replyToMessage.type == MessageType.file) {
      previewText = 'Document';
    } else {
      final txt = replyToMessage.text;
      previewText = txt.length > 50 ? '${txt.substring(0, 50)}...' : txt;
    }
    
    // ✅ For scheduled messages, set status=scheduled so worker handles sending
    final isScheduled = sendMode == 'scheduled' && scheduledAtUtc != null;
    
    final msg = ChatMessage(
      id: const Uuid().v4(),
      roomId: roomId,
      senderId: currentUser!.id,
      senderName: currentUser!.username,
      recipientId: recipientId,
      text: text,
      timestamp: DateTime.now().toUtc(),
      type: MessageType.text,
      status: isScheduled ? MessageStatus.scheduled : MessageStatus.pending,
      via: 'wifi',
      // Reply metadata
      replyToMessageId: replyToMessage.id,
      replyToTextPreview: previewText,
      replyToSenderName: replyToMessage.senderName,
      replyToType: replyToMessage.type,
      // ✅ Scheduled message fields
      sendMode: sendMode,
      scheduledAtUtc: scheduledAtUtc,
    );
    
    // Add to messages list
    messages.add(msg);
    notifyListeners();
    
    // Save to local DB
    await DatabaseHelper.instance.insertMessage(msg);
    
    // ✅ For scheduled messages, skip immediate sending - worker will handle it
    if (isScheduled) {
      log('⏰ [sendReplyMessage] Scheduled reply created, will send at: $scheduledAtUtc');
      return;
    }
    
    // Send via API
    try {
      final success = await ApiService.sendMessage(
        recipientId: recipientId,
        content: text,
        messageId: msg.id,
        // ✅ Reply fields for receiver to see preview
        replyToMessageId: msg.replyToMessageId,
        replyToTextPreview: msg.replyToTextPreview,
        replyToSenderName: msg.replyToSenderName,
        replyToType: msg.replyToType?.name,
        sendMode: sendMode,
        scheduledAtUtc: scheduledAtUtc,
      );
      if (success) {
        log('✅ [sendReplyMessage] Sent successfully');
        final idx = messages.indexWhere((m) => m.id == msg.id);
        if (idx != -1) {
          messages[idx] = messages[idx].copyWith(status: MessageStatus.sent);
        }
        notifyListeners();
      }
    } catch (e) {
      log('⚠️ [sendReplyMessage] API failed: $e');
    }
    
    log('✅ [sendReplyMessage] DONE');
  }

  Future<void> sendToUser(
    String targetId, 
    String text, {
    String sendMode = 'instant',
    DateTime? scheduledAtUtc,
  }) async {
    if (currentUser == null) return;
    
    log('📤 [sendToUser] START - targetId: $targetId, text: ${text.substring(0, text.length < 20 ? text.length : 20)}...');
    
    // Use local helper _getRoomId
    final roomId = _getRoomId(currentUser!.id, targetId);
    
    // ✅ For scheduled messages, set status=scheduled so worker handles sending
    final isScheduled = sendMode == 'scheduled' && scheduledAtUtc != null;
    
    final msg = ChatMessage(
      id: const Uuid().v4(),
      roomId: roomId,
      senderId: currentUser!.id,
      senderName: currentUser!.showUsername ? currentUser!.username : "Anonymous",
      recipientId: targetId,
      text: text,
      timestamp: DateTime.now().toUtc(), // Store in UTC for consistency
      status: isScheduled ? MessageStatus.scheduled : MessageStatus.pending,
      type: MessageType.text,
      // ✅ Scheduled message fields
      sendMode: sendMode,
      scheduledAtUtc: scheduledAtUtc,
    );
    
    // ✅ Use upsertMessage for dedupe + sort + notify
    upsertMessage(msg);
    await _db.insertMessage(msg); // ✅ Persist to DB
    
    // 🔍 DEBUG: Verify insertion
    print('🔍 [DEBUG sendToUser] Total in memory: ${messages.length}');
    final dbCount = (await _db.getMessagesForRoom(roomId)).length;
    print('🔍 [DEBUG sendToUser] Messages in DB for roomId=$roomId: $dbCount');
    
    await _db.incrementMessageCount(currentUser!.id, targetId);
    currentChatMsgCount++;
    
    // ✅ Update conversation list
    await _db.touchConversation(
      otherUserId: targetId,
      otherUsername: currentChatName,  // Use current chat name
      preview: text,
      time: DateTime.now(),
      incoming: false,
    );
    
    notifyListeners();
    print('🔍 [DEBUG sendToUser] notifyListeners called');
    
    // ✅ For scheduled messages, skip immediate sending - worker will handle it
    if (isScheduled) {
      log('⏰ [sendToUser] Scheduled message created, will send at: $scheduledAtUtc');
      return;  // Worker will pick up and send at scheduled time
    }
    
    // ✅ Try WiFi/API first if we're friends
    bool wifiSent = false;
    log('🔍 [sendToUser] isCurrentChatFriend=$isCurrentChatFriend, targetId=$targetId, currentChatId=$currentChatId');
    
    if (isCurrentChatFriend || targetId == currentChatId) {
      try {
        log('📡 [sendToUser] Trying WiFi/API first...');
        final success = await ApiService.sendMessage(
          recipientId: targetId,
          content: text,
          messageId: msg.id,  // For idempotency
          // ✅ Scheduled message fields
          sendMode: sendMode,
          scheduledAtUtc: scheduledAtUtc,
        );
        if (success) {
          wifiSent = true;
          log('✅ [sendToUser] WiFi send successful!');
          // Update message status
          final idx = messages.indexWhere((m) => m.id == msg.id);
          if (idx != -1) {
            messages[idx] = messages[idx].copyWith(status: MessageStatus.sent);
          }
          notifyListeners();
        } else {
          log('⚠️ [sendToUser] WiFi returned false, will try Mesh');
        }
      } catch (e) {
        log('⚠️ [sendToUser] WiFi EXCEPTION: $e');
        log('📡 [sendToUser] Falling back to Mesh...');
      }
    } else {
      log('⚠️ [sendToUser] Not a friend, skipping WiFi, going direct to Mesh');
    }
    
    // Fallback to Mesh if WiFi didn't work
    if (!wifiSent) {
      log('📤 [sendToUser] Calling router.sendMessage (Mesh)...');
      await _router.sendMessage(msg);
      log('📤 [sendToUser] router.sendMessage completed');
    }
    
    log('✅ [sendToUser] DONE');
  }

  // Respond to Friend Request
  Future<void> respondFriendRequest(String userId, bool accept) async {
    if (accept) {
       await _updateContactStatus(userId, 1); // Friend
       await sendToUser(userId, "<<FRIEND_ACCEPT>>");
       if (currentChatId == userId) isCurrentChatFriend = true;
    } else {
       await _updateContactStatus(userId, 0); // Stranger/Rejected
    }
    notifyListeners();
  }
  
  // When we receive an ACCEPT
  Future<void> _handleFriendAccept(String userId) async {
     await _updateContactStatus(userId, 1);
     if (currentChatId == userId) isCurrentChatFriend = true;
     notifyListeners();
     _showNotification("Friend request accepted!");
  }

  /// Complete QR-based friend pairing
  /// Creates mutual friendship and shows success toast
  Future<void> _completeFriendPairing({
    required String theirUserId,
    required String theirUsername,
    required String theirFingerprint,
    required String theirPubKey,
    String? theirAvatarUrl,
  }) async {
    if (currentUser == null) return;
    
    log('🤝 [QR] Completing friend pairing with @$theirUsername');
    
    try {
      // 1. Update friend status to Friend (1)
      await _db.updateFriendStatus(
        currentUser!.id,
        theirUserId,
        1, // Friend status
        username: theirUsername,
        avatarPath: theirAvatarUrl,
      );
      
      // 2. Add to mesh trusted peers for auto-connect
      await MeshBridge.addTrustedPeer(theirFingerprint);
      
      // 3. Register their identity for E2EE
      await IdentityService.instance.registerIdentity(
        userId: theirUserId,
        publicKey: theirPubKey,
      );
      
      // 4. Show success toast via notification overlay
      if (_notificationController != null) {
        _notificationController!.add(
          OverlayNotification(
            id: 'friend_success_$theirUserId',
            type: OverlayNotificationType.friendRequest, // Green icon
            title: 'New Friend! 🎉',
            body: 'You and @$theirUsername are now friends',
            time: DateTime.now(),
          ),
        );
      }
      
      // 5. Update UI if we're looking at their chat
      if (currentChatId == theirUserId) {
        isCurrentChatFriend = true;
      }
      
      log('✅ [QR] Friend pairing completed with @$theirUsername');
      notifyListeners();
    } catch (e) {
      log('❌ [QR] Error completing friend pairing: $e');
    }
  }

  Future<void> _updateContactStatus(String userId, int status) async {
     final contact = Contact(
       id: const Uuid().v4(),
       userId: userId,
       username: currentChatName,
       addedAt: DateTime.now(),
       status: status
     );
     await _db.upsertContact(contact, status);
  }
  
  // === App Store Compliance: Report/Block ===
  
  Future<void> reportUser(String userId, String reason) async {
    if (currentUser == null) return;
    
    await _db.insertReport(
      reporterId: currentUser!.id,
      reportedUserId: userId,
      reportedContentType: 'user',
      reason: reason,
    );
    
    log('✅ Reported user $userId for $reason');
  }
  
  Future<void> blockUser(String userId) async {
    await _db.blockUser(userId);
    
    // Remove from current chat if we're in it
    if (currentChatId == userId) {
      currentChatId = '';
      currentChatName = '';
      messages.clear();
    }
    
    notifyListeners();
    log('✅ Blocked user $userId');
  }
}
