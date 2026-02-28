// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => 'RAVEN';

  @override
  String get appSubtitle => '网状网络 + 互联网';

  @override
  String get signIn => '登录';

  @override
  String get signUp => '注册';

  @override
  String get username => '用户名';

  @override
  String get password => '密码';

  @override
  String get confirmPassword => '确认密码';

  @override
  String get firstName => '名字';

  @override
  String get lastName => '姓氏';

  @override
  String get birthYear => '出生年份';

  @override
  String get welcomeMessage => '欢迎使用 RAVEN';

  @override
  String get dontHaveAccount => '还没有账户？';

  @override
  String get alreadyHaveAccount => '已有账户？';

  @override
  String get errorUsername => '请输入用户名';

  @override
  String get errorPassword => '请输入密码';

  @override
  String get errorPasswordMatch => '密码不匹配';

  @override
  String get errorFirstName => '请输入名字';

  @override
  String get errorLastName => '请输入姓氏';

  @override
  String get errorBirthYear => '请输入出生年份';

  @override
  String get invalidCredentials => '用户名或密码无效';

  @override
  String get usernameTaken => '用户名已被使用';

  @override
  String get signUpSuccess => '账户创建成功！';

  @override
  String get signInSuccess => '欢迎回来！';

  @override
  String get friendsTab => '好友';

  @override
  String get nearbyTab => '附近';

  @override
  String get home => '主页';

  @override
  String get notifications => '通知';

  @override
  String get enterRoom => '进入';

  @override
  String get roomLabel => '房间';

  @override
  String get typeMessage => '输入信息...';

  @override
  String get send => '发送';

  @override
  String get screenshotDetected => '📸 检测到截屏！';

  @override
  String get friendRequestSent => '好友请求已发送';

  @override
  String wantsToBeFriends(Object name) {
    return '$name 想成为你的好友！';
  }

  @override
  String get accept => '接受';

  @override
  String get youAreFriends => '你们现在是好友了。';

  @override
  String get limitReached => '达到限制';

  @override
  String get addFriend => '加为好友';

  @override
  String get limitReachedMessage => '已交换3条消息。加为好友继续？';

  @override
  String get settings => '设置';

  @override
  String get language => '语言';

  @override
  String get english => '英语';

  @override
  String get spanish => '西班牙语';

  @override
  String get persian => '波斯语 (فارسی)';

  @override
  String get chinese => '中文';

  @override
  String get messageLimitReached => '消息限制已达！发送好友请求以继续。';

  @override
  String get sendFriendRequest => '发送好友请求';

  @override
  String get whatsHappening => '发生了什么？';

  @override
  String get post => '发布';

  @override
  String get like => '点赞';

  @override
  String get comment => '评论';

  @override
  String get share => '分享';

  @override
  String get messages => '消息';

  @override
  String get search => '搜索';

  @override
  String get account => '账户';

  @override
  String get accountSettings => '账户设置';

  @override
  String get changePassword => '更改密码';

  @override
  String get editBio => '编辑简介';

  @override
  String get searchPrivacy => '搜索隐私';

  @override
  String get newsInterests => '新闻兴趣';

  @override
  String get faq => '常见问题';

  @override
  String get currentPassword => '当前密码';

  @override
  String get newPassword => '新密码';

  @override
  String get save => '保存';

  @override
  String get cancel => '取消';

  @override
  String get delete => '删除';

  @override
  String get edit => '编辑';

  @override
  String get loading => '加载中...';

  @override
  String get error => '错误';

  @override
  String get success => '成功';

  @override
  String get retry => '重试';

  @override
  String get close => '关闭';

  @override
  String get technology => '科技';

  @override
  String get business => '商业';

  @override
  String get science => '科学';

  @override
  String get health => '健康';

  @override
  String get sports => '体育';

  @override
  String get entertainment => '娱乐';

  @override
  String get general => '综合';

  @override
  String get german => '德语';

  @override
  String get public => '公开';

  @override
  String get private => '私密';

  @override
  String get bio => '简介';

  @override
  String get noBioYet => '还没有简介';

  @override
  String get user => '用户';

  @override
  String get fontSize => '字体大小';

  @override
  String get fontSizeSmall => '小';

  @override
  String get fontSizeMedium => '中';

  @override
  String get fontSizeLarge => '大';

  @override
  String get fontSizeExtraLarge => '特大';

  @override
  String get privacyAndSecurity => 'Privacy and Security';

  @override
  String get manageBlockedUsersAndSecurity =>
      'Manage blocked users and security';

  @override
  String get blockedUsers => 'Blocked Users';

  @override
  String get noBlockedUsers => 'No blocked users';

  @override
  String get blocked => 'blocked';

  @override
  String get unblock => 'Unblock';

  @override
  String get unblockUser => 'Unblock User';

  @override
  String unblockUserConfirmation(Object username) {
    return 'Are you sure you want to unblock $username?';
  }

  @override
  String userUnblocked(Object username) {
    return '$username has been unblocked';
  }

  @override
  String get passcodeAndFaceId => 'Passcode & Face ID';

  @override
  String get setupPasscode => 'Set up app lock';

  @override
  String get enterPasscode => 'Enter Passcode';

  @override
  String get confirmPasscode => 'Confirm Passcode';

  @override
  String get enterCurrentPasscode => 'Enter Current Passcode';

  @override
  String get passcodeMismatch => 'Passcodes do not match';

  @override
  String get passcodeSet => 'Passcode set successfully';

  @override
  String get passcodeEnabled => 'Passcode Enabled';

  @override
  String get changePasscode => 'Change Passcode';

  @override
  String get removePasscode => 'Remove Passcode';

  @override
  String get removePasscodeConfirmation =>
      'Are you sure you want to remove your passcode?';

  @override
  String get passcodeRemoved => 'Passcode removed';

  @override
  String get unlockApp => 'Unlock App';

  @override
  String get incorrectPasscode => 'Incorrect passcode';

  @override
  String get setupPasscodeFirst => 'Please set up a passcode first';

  @override
  String get enableBiometric => 'Enable biometric authentication';

  @override
  String useBiometricToUnlock(Object biometricName) {
    return 'Use $biometricName to unlock the app';
  }

  @override
  String get twoStepVerification => 'Two-Step Verification';

  @override
  String get addExtraSecurity => 'Add an extra layer of security';

  @override
  String get enable2FA => 'Enable Two-Factor Authentication';

  @override
  String get disable2FA => 'Disable Two-Factor Authentication';

  @override
  String get enabled => 'Enabled';

  @override
  String get disabled => 'Disabled';

  @override
  String verificationVia(Object method) {
    return 'Verification via $method';
  }

  @override
  String get twoFactorDescription =>
      'Two-step verification adds an extra layer of security by requiring a code from your email or phone when signing in';

  @override
  String get chooseVerificationMethod => 'Choose Verification Method';

  @override
  String get verificationMethod => 'Verification Method';

  @override
  String get emailVerification => 'Email';

  @override
  String get smsVerification => 'SMS';

  @override
  String get comingSoon => 'Coming soon';

  @override
  String get enterVerificationCode => 'Enter Verification Code';

  @override
  String get sixDigitCode => '6-digit code';

  @override
  String get verify => 'Verify';

  @override
  String get twoFactorEnabled => 'Two-factor authentication enabled';

  @override
  String get twoFactorDisabled => 'Two-factor authentication disabled';

  @override
  String get disable2FAConfirmation =>
      'Are you sure you want to disable two-factor authentication?';

  @override
  String get invalidCode => 'Invalid verification code';

  @override
  String get disable => 'Disable';

  @override
  String get remove => 'Remove';

  @override
  String get autoDeleteMessages => 'Auto-Delete Messages';

  @override
  String get automaticallyDeleteOldMessages =>
      'Automatically delete old messages';

  @override
  String get autoDeletePeriod => 'Delete messages after';

  @override
  String get never => 'Never';

  @override
  String get twentyFourHours => '24 hours';

  @override
  String get sevenDays => '7 days';

  @override
  String get thirtyDays => '30 days';

  @override
  String get autoDeleteEnabled => 'Auto-delete enabled';

  @override
  String get autoDeleteDisabled => 'Auto-delete disabled';

  @override
  String get autoDeleteDescription =>
      'Messages older than the selected period will be automatically deleted from your device';

  @override
  String messagesOlderThan(Object period) {
    return 'Messages older than $period will be deleted';
  }

  @override
  String get autoDeleteWarning =>
      'Warning: Deleted messages cannot be recovered';

  @override
  String get editProfile => 'Edit Profile';

  @override
  String get showUsernameTitle => 'Show Username';

  @override
  String get showUsernameSubtitle => 'Display your username to others';

  @override
  String get sosModeTitle => 'SOS Mode (Mesh Relay)';

  @override
  String get enableRelayTitle => 'Enable Relay';

  @override
  String get enableRelaySubtitle =>
      'Allow your device to forward messages for others';

  @override
  String get maxHops => 'Max Hops';

  @override
  String hopsCount(Object count) {
    return '$count hops';
  }

  @override
  String get sosModeDescription =>
      'SOS mode routes messages through nearby devices when direct connection is unavailable.';

  @override
  String get meshNetwork => 'Mesh Network';

  @override
  String nearbyPeers(Object count) {
    return 'Nearby Peers: $count';
  }

  @override
  String get debugLogs => 'Debug Logs';

  @override
  String get clearAllDataTitle => 'Clear All Data';

  @override
  String get clearAllDataSubtitle => 'Delete all messages, contacts, and posts';

  @override
  String get clearAllDataDialogTitle => 'Clear All Data?';

  @override
  String get clearAllDataDialogContent =>
      'This will delete all your messages, contacts, and posts. This cannot be undone.';

  @override
  String get allDataCleared => 'All data cleared!';

  @override
  String get faqTitle => '帮助与常见问题';

  @override
  String get faqQuickStartTitle => '🚀 快速入门指南';

  @override
  String get faqQuickStartSubtitle => '学习使用 RAVEN 的所有功能';

  @override
  String get faqSendMessageTitle => '📱 发送消息';

  @override
  String get faqSendMessageQuestion => '如何发送消息？';

  @override
  String get faqSendMessageSteps =>
      '1. 点击\"消息\"标签\n2. 点击 ➕ 或 ✏️ 图标\n3. 搜索或选择联系人\n4. 输入消息并点击发送 ✓\n\n重要提示：如果没有网络，消息会通过蓝牙发送到附近的手机！';

  @override
  String get faqAddFriendTitle => '👥 添加好友';

  @override
  String get faqAddFriendQuestion => '如何添加好友？';

  @override
  String get faqAddFriendSteps =>
      '方法一 - 搜索：\n1. 前往\"搜索\"标签\n2. 输入好友的用户名\n3. 点击他们的名字并\"发送好友请求\"\n\n方法二 - 二维码：\n1. 前往设置 → \"我的二维码\"\n2. 让好友扫描你的二维码或扫描他们的\n这是最快最安全的方式！';

  @override
  String get faqCreatePostTitle => '📝 创建帖子';

  @override
  String get faqCreatePostQuestion => '如何发布帖子？';

  @override
  String get faqCreatePostSteps =>
      '1. 点击\"主页\"标签\n2. 点击底部的 ➕ 按钮\n3. 写下你的文字（最多280个字符）\n4. 还可以添加照片 📷\n5. 点击\"发布\"\n\n注意：帖子是公开的！使用消息进行私人对话。';

  @override
  String get faqAiTitle => '🤖 AI 助手';

  @override
  String get faqAiQuestion => '如何询问 AI？';

  @override
  String get faqAiSteps =>
      '在任何帖子的评论中：\n1. 打开帖子的评论\n2. 输入：@time_ask 你的问题\n3. 例如：\"@time_ask 今天天气怎么样？\"\n4. AI 会以评论形式回复！\n\n此功能用于一般问题、翻译和获取帮助。';

  @override
  String get faqVoiceTitle => '🔊 语音消息';

  @override
  String get faqVoiceQuestion => '如何发送语音消息？';

  @override
  String get faqVoiceSteps =>
      '1. 进入聊天\n2. 按住 🎤（麦克风）按钮\n3. 按住时说话\n4. 松开即可发送！\n\n提示：向左滑动可取消。';

  @override
  String get faqBackupTitle => '💾 备份';

  @override
  String get faqBackupQuestion => '如何备份聊天记录？';

  @override
  String get faqBackupSteps =>
      '1. 前往\"设置\"\n2. 点击\"备份与恢复\"\n3. 点击\"创建备份\"\n4. 等待上传完成 ✓\n\n备份存储在 iCloud 并已加密。';

  @override
  String get faqSectionTitle => '❓ 常见问题';

  @override
  String get faqSectionSubtitle => '常见问题解答';

  @override
  String get faqWhatIsRaivenTitle => '什么是 RAVEN？🐦';

  @override
  String get faqWhatIsRaivenAnswer =>
      'RAVEN 是一款特别独特的消息应用！\n\n为什么特别？因为即使没有网络也能使用！\n\n有网络 → 消息通过服务器发送（快速）\n无网络 → 消息通过蓝牙发送（智能）\n\n这意味着在地铁、山区或任何没有信号的地方，你仍然可以发消息！✨';

  @override
  String get faqOfflineTitle => '离线消息如何工作？📡';

  @override
  String get faqOfflineAnswer =>
      '很简单：\n\n1. 你发送消息\n2. 没有网络，所以存储在你的手机上\n3. 你的手机使用蓝牙\n4. 消息发送到附近装有 RAVEN 的手机\n5. 他们转发给其他人\n6. 直到到达目的地！\n\n像一条链！每部手机都是一个环节 🔗';

  @override
  String get faqSecurityTitle => '我的消息安全吗？🔒';

  @override
  String get faqSecurityAnswer =>
      '100% 安全！\n\n✅ 端到端加密\n只有你和收件人可以阅读\n\n✅ 密钥存储在你的设备上\n没有人，包括我们，可以访问\n\n✅ 蓝牙消息也已加密\n即使中转设备也无法读取\n\n请放心！🛡️';

  @override
  String get faqStatusTitle => '消息符号是什么意思？✓';

  @override
  String get faqStatusAnswer =>
      '⏳ 待发送 - 消息在发送队列中\n✓ 已发送 - 消息离开了你的手机\n✓✓ 已送达 - 消息到达收件人手机\n👁 已读 - 收件人打开了消息\n\n注意：如果要等很久，收件人可能离线。';

  @override
  String get faqBridgeTitle => '什么是桥接模式？🌉';

  @override
  String get faqBridgeAnswer =>
      '一个很棒的功能！\n\n想象你没有网络但发送了一条消息。\n消息通过蓝牙发送到附近的手机。\n其中一部手机有网络！\n那部手机通过服务器发送你的消息。\n\n所以它过了一座桥！🎯\n这是自动发生的。';

  @override
  String get faqInternetTitle => '我需要网络吗？📶';

  @override
  String get faqInternetAnswer =>
      '不！这是 RAVEN 最大的优势！\n\n有网络 → 一切更快\n没网络 → 使用蓝牙\n\n应用自动检测并切换。\n只需写下消息，其余的我们来处理！💪';

  @override
  String get faqDuplicateTitle => '我会收到重复的消息吗？🔄';

  @override
  String get faqDuplicateAnswer =>
      '不会！\n\n每条消息都有唯一的 ID（像指纹一样）。\n即使消息通过多条路径到达（蓝牙和服务器），应用知道并只显示一次。\n\n不用担心重复！✓';

  @override
  String get faqDtnTitle => '什么是 DTN？🔬';

  @override
  String get faqDtnAnswer =>
      'DTN = 延迟容忍网络\n意思是\"能够容忍延迟的网络\"\n\n简单说：\n一种存储消息、携带它并在条件合适时发送的技术。\n\n即使需要一天！（但通常快得多 😄）\n\n这项技术最初是为航天器通信而建造的！🚀';

  @override
  String get faqLanguagesTitle => '支持哪些语言？🌍';

  @override
  String get faqLanguagesAnswer =>
      'RAVEN 完全翻译为：\n\n🇺🇸 英语\n🇮🇷 波斯语（支持从右到左）\n🇪🇸 西班牙语\n🇩🇪 德语\n🇨🇳 中文\n\n前往设置 → 语言进行更改！';

  @override
  String get faqTipsTitle => '💡 提示与技巧';

  @override
  String get faqTipsSubtitle => '更好地使用！';

  @override
  String get faqTipBluetooth => '保持蓝牙开启';

  @override
  String get faqTipBluetoothDesc => '即使有网络！你可以帮助其他人收到消息。';

  @override
  String get faqTipBackup => '定期备份';

  @override
  String get faqTipBackupDesc => '每周备份以免丢失聊天记录。';

  @override
  String get faqTipQr => '使用二维码';

  @override
  String get faqTipQrDesc => '添加好友时，扫描二维码更快更安全！';

  @override
  String get faqTipNotifications => '开启通知';

  @override
  String get faqTipNotificationsDesc => '这样你不会错过重要消息。';

  @override
  String get faqContactTitle => '需要更多帮助？';

  @override
  String get faqContactEmail => 'info@raven-messager.com';

  @override
  String get faqWhitepaperTitle => 'Where is the technical whitepaper? 📄';

  @override
  String get faqWhitepaperAnswer =>
      'We have a full technical whitepaper on our website!\\n\\n📍 Visit: raven-messager.com/technology.html\\n\\nIt covers:\\n• Hybrid Architecture (Internet + Mesh)\\n• Offline Delivery (DTN Protocol)\\n• Anti-Duplicate Algorithm\\n• Privacy Model\\n• Security Overview\\n\\nVersion: v0.1 — January 2026';

  @override
  String get technicalOverviewTitle => 'How RAVEN Works';

  @override
  String get technicalOverviewSubtitle =>
      'Technical overview of architecture and security';
}
