import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_de.dart';
import 'app_localizations_en.dart';
import 'app_localizations_es.dart';
import 'app_localizations_fa.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen_l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('de'),
    Locale('en'),
    Locale('es'),
    Locale('fa'),
    Locale('zh')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'RAVEN'**
  String get appTitle;

  /// No description provided for @appSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Mesh + Internet'**
  String get appSubtitle;

  /// No description provided for @signIn.
  ///
  /// In en, this message translates to:
  /// **'Sign In'**
  String get signIn;

  /// No description provided for @signUp.
  ///
  /// In en, this message translates to:
  /// **'Sign Up'**
  String get signUp;

  /// No description provided for @username.
  ///
  /// In en, this message translates to:
  /// **'Username'**
  String get username;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @confirmPassword.
  ///
  /// In en, this message translates to:
  /// **'Confirm Password'**
  String get confirmPassword;

  /// No description provided for @firstName.
  ///
  /// In en, this message translates to:
  /// **'First Name'**
  String get firstName;

  /// No description provided for @lastName.
  ///
  /// In en, this message translates to:
  /// **'Last Name'**
  String get lastName;

  /// No description provided for @birthYear.
  ///
  /// In en, this message translates to:
  /// **'Birth Year'**
  String get birthYear;

  /// No description provided for @welcomeMessage.
  ///
  /// In en, this message translates to:
  /// **'Welcome to RAVEN'**
  String get welcomeMessage;

  /// No description provided for @dontHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account?'**
  String get dontHaveAccount;

  /// No description provided for @alreadyHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'Already have an account?'**
  String get alreadyHaveAccount;

  /// No description provided for @errorUsername.
  ///
  /// In en, this message translates to:
  /// **'Please enter username'**
  String get errorUsername;

  /// No description provided for @errorPassword.
  ///
  /// In en, this message translates to:
  /// **'Please enter password'**
  String get errorPassword;

  /// No description provided for @errorPasswordMatch.
  ///
  /// In en, this message translates to:
  /// **'Passwords don\'t match'**
  String get errorPasswordMatch;

  /// No description provided for @errorFirstName.
  ///
  /// In en, this message translates to:
  /// **'Please enter first name'**
  String get errorFirstName;

  /// No description provided for @errorLastName.
  ///
  /// In en, this message translates to:
  /// **'Please enter last name'**
  String get errorLastName;

  /// No description provided for @errorBirthYear.
  ///
  /// In en, this message translates to:
  /// **'Please enter birth year'**
  String get errorBirthYear;

  /// No description provided for @invalidCredentials.
  ///
  /// In en, this message translates to:
  /// **'Invalid username or password'**
  String get invalidCredentials;

  /// No description provided for @usernameTaken.
  ///
  /// In en, this message translates to:
  /// **'Username already taken'**
  String get usernameTaken;

  /// No description provided for @signUpSuccess.
  ///
  /// In en, this message translates to:
  /// **'Account created successfully!'**
  String get signUpSuccess;

  /// No description provided for @signInSuccess.
  ///
  /// In en, this message translates to:
  /// **'Welcome back!'**
  String get signInSuccess;

  /// No description provided for @friendsTab.
  ///
  /// In en, this message translates to:
  /// **'Friends'**
  String get friendsTab;

  /// No description provided for @nearbyTab.
  ///
  /// In en, this message translates to:
  /// **'Nearby'**
  String get nearbyTab;

  /// No description provided for @home.
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get home;

  /// No description provided for @notifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifications;

  /// No description provided for @enterRoom.
  ///
  /// In en, this message translates to:
  /// **'Enter'**
  String get enterRoom;

  /// No description provided for @roomLabel.
  ///
  /// In en, this message translates to:
  /// **'Room'**
  String get roomLabel;

  /// No description provided for @typeMessage.
  ///
  /// In en, this message translates to:
  /// **'Type message...'**
  String get typeMessage;

  /// No description provided for @send.
  ///
  /// In en, this message translates to:
  /// **'Send'**
  String get send;

  /// No description provided for @screenshotDetected.
  ///
  /// In en, this message translates to:
  /// **'📸 Screenshot taken!'**
  String get screenshotDetected;

  /// No description provided for @friendRequestSent.
  ///
  /// In en, this message translates to:
  /// **'Friend Request Sent'**
  String get friendRequestSent;

  /// No description provided for @wantsToBeFriends.
  ///
  /// In en, this message translates to:
  /// **'{name} wants to be friends!'**
  String wantsToBeFriends(Object name);

  /// No description provided for @accept.
  ///
  /// In en, this message translates to:
  /// **'Accept'**
  String get accept;

  /// No description provided for @youAreFriends.
  ///
  /// In en, this message translates to:
  /// **'You are now friends.'**
  String get youAreFriends;

  /// No description provided for @limitReached.
  ///
  /// In en, this message translates to:
  /// **'Limit reached'**
  String get limitReached;

  /// No description provided for @addFriend.
  ///
  /// In en, this message translates to:
  /// **'Add Friend'**
  String get addFriend;

  /// No description provided for @limitReachedMessage.
  ///
  /// In en, this message translates to:
  /// **'You exchanged 3 messages. Add as friend to continue?'**
  String get limitReachedMessage;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @spanish.
  ///
  /// In en, this message translates to:
  /// **'Spanish'**
  String get spanish;

  /// No description provided for @persian.
  ///
  /// In en, this message translates to:
  /// **'Persian (فارسی)'**
  String get persian;

  /// No description provided for @chinese.
  ///
  /// In en, this message translates to:
  /// **'Chinese (中文)'**
  String get chinese;

  /// No description provided for @messageLimitReached.
  ///
  /// In en, this message translates to:
  /// **'Message limit reached! Send friend request to continue.'**
  String get messageLimitReached;

  /// No description provided for @sendFriendRequest.
  ///
  /// In en, this message translates to:
  /// **'Send Friend Request'**
  String get sendFriendRequest;

  /// No description provided for @whatsHappening.
  ///
  /// In en, this message translates to:
  /// **'What\'s happening?'**
  String get whatsHappening;

  /// No description provided for @post.
  ///
  /// In en, this message translates to:
  /// **'Post'**
  String get post;

  /// No description provided for @like.
  ///
  /// In en, this message translates to:
  /// **'Like'**
  String get like;

  /// No description provided for @comment.
  ///
  /// In en, this message translates to:
  /// **'Comment'**
  String get comment;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @messages.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get messages;

  /// No description provided for @search.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get search;

  /// No description provided for @account.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get account;

  /// No description provided for @accountSettings.
  ///
  /// In en, this message translates to:
  /// **'Account Settings'**
  String get accountSettings;

  /// No description provided for @changePassword.
  ///
  /// In en, this message translates to:
  /// **'Change Password'**
  String get changePassword;

  /// No description provided for @editBio.
  ///
  /// In en, this message translates to:
  /// **'Edit Bio'**
  String get editBio;

  /// No description provided for @searchPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Search Privacy'**
  String get searchPrivacy;

  /// No description provided for @newsInterests.
  ///
  /// In en, this message translates to:
  /// **'News Interests'**
  String get newsInterests;

  /// No description provided for @faq.
  ///
  /// In en, this message translates to:
  /// **'FAQ'**
  String get faq;

  /// No description provided for @currentPassword.
  ///
  /// In en, this message translates to:
  /// **'Current Password'**
  String get currentPassword;

  /// No description provided for @newPassword.
  ///
  /// In en, this message translates to:
  /// **'New Password'**
  String get newPassword;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @delete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get delete;

  /// No description provided for @edit.
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get edit;

  /// No description provided for @loading.
  ///
  /// In en, this message translates to:
  /// **'Loading...'**
  String get loading;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// No description provided for @success.
  ///
  /// In en, this message translates to:
  /// **'Success'**
  String get success;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @technology.
  ///
  /// In en, this message translates to:
  /// **'Technology'**
  String get technology;

  /// No description provided for @business.
  ///
  /// In en, this message translates to:
  /// **'Business'**
  String get business;

  /// No description provided for @science.
  ///
  /// In en, this message translates to:
  /// **'Science'**
  String get science;

  /// No description provided for @health.
  ///
  /// In en, this message translates to:
  /// **'Health'**
  String get health;

  /// No description provided for @sports.
  ///
  /// In en, this message translates to:
  /// **'Sports'**
  String get sports;

  /// No description provided for @entertainment.
  ///
  /// In en, this message translates to:
  /// **'Entertainment'**
  String get entertainment;

  /// No description provided for @general.
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get general;

  /// No description provided for @german.
  ///
  /// In en, this message translates to:
  /// **'German'**
  String get german;

  /// No description provided for @public.
  ///
  /// In en, this message translates to:
  /// **'Public'**
  String get public;

  /// No description provided for @private.
  ///
  /// In en, this message translates to:
  /// **'Private'**
  String get private;

  /// No description provided for @bio.
  ///
  /// In en, this message translates to:
  /// **'Bio'**
  String get bio;

  /// No description provided for @noBioYet.
  ///
  /// In en, this message translates to:
  /// **'No bio yet'**
  String get noBioYet;

  /// No description provided for @user.
  ///
  /// In en, this message translates to:
  /// **'User'**
  String get user;

  /// No description provided for @fontSize.
  ///
  /// In en, this message translates to:
  /// **'Font Size'**
  String get fontSize;

  /// No description provided for @fontSizeSmall.
  ///
  /// In en, this message translates to:
  /// **'Small'**
  String get fontSizeSmall;

  /// No description provided for @fontSizeMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get fontSizeMedium;

  /// No description provided for @fontSizeLarge.
  ///
  /// In en, this message translates to:
  /// **'Large'**
  String get fontSizeLarge;

  /// No description provided for @fontSizeExtraLarge.
  ///
  /// In en, this message translates to:
  /// **'Extra Large'**
  String get fontSizeExtraLarge;

  /// No description provided for @privacyAndSecurity.
  ///
  /// In en, this message translates to:
  /// **'Privacy and Security'**
  String get privacyAndSecurity;

  /// No description provided for @manageBlockedUsersAndSecurity.
  ///
  /// In en, this message translates to:
  /// **'Manage blocked users and security'**
  String get manageBlockedUsersAndSecurity;

  /// No description provided for @blockedUsers.
  ///
  /// In en, this message translates to:
  /// **'Blocked Users'**
  String get blockedUsers;

  /// No description provided for @noBlockedUsers.
  ///
  /// In en, this message translates to:
  /// **'No blocked users'**
  String get noBlockedUsers;

  /// No description provided for @blocked.
  ///
  /// In en, this message translates to:
  /// **'blocked'**
  String get blocked;

  /// No description provided for @unblock.
  ///
  /// In en, this message translates to:
  /// **'Unblock'**
  String get unblock;

  /// No description provided for @unblockUser.
  ///
  /// In en, this message translates to:
  /// **'Unblock User'**
  String get unblockUser;

  /// No description provided for @unblockUserConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to unblock {username}?'**
  String unblockUserConfirmation(Object username);

  /// No description provided for @userUnblocked.
  ///
  /// In en, this message translates to:
  /// **'{username} has been unblocked'**
  String userUnblocked(Object username);

  /// No description provided for @passcodeAndFaceId.
  ///
  /// In en, this message translates to:
  /// **'Passcode & Face ID'**
  String get passcodeAndFaceId;

  /// No description provided for @setupPasscode.
  ///
  /// In en, this message translates to:
  /// **'Set up app lock'**
  String get setupPasscode;

  /// No description provided for @enterPasscode.
  ///
  /// In en, this message translates to:
  /// **'Enter Passcode'**
  String get enterPasscode;

  /// No description provided for @confirmPasscode.
  ///
  /// In en, this message translates to:
  /// **'Confirm Passcode'**
  String get confirmPasscode;

  /// No description provided for @enterCurrentPasscode.
  ///
  /// In en, this message translates to:
  /// **'Enter Current Passcode'**
  String get enterCurrentPasscode;

  /// No description provided for @passcodeMismatch.
  ///
  /// In en, this message translates to:
  /// **'Passcodes do not match'**
  String get passcodeMismatch;

  /// No description provided for @passcodeSet.
  ///
  /// In en, this message translates to:
  /// **'Passcode set successfully'**
  String get passcodeSet;

  /// No description provided for @passcodeEnabled.
  ///
  /// In en, this message translates to:
  /// **'Passcode Enabled'**
  String get passcodeEnabled;

  /// No description provided for @changePasscode.
  ///
  /// In en, this message translates to:
  /// **'Change Passcode'**
  String get changePasscode;

  /// No description provided for @removePasscode.
  ///
  /// In en, this message translates to:
  /// **'Remove Passcode'**
  String get removePasscode;

  /// No description provided for @removePasscodeConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to remove your passcode?'**
  String get removePasscodeConfirmation;

  /// No description provided for @passcodeRemoved.
  ///
  /// In en, this message translates to:
  /// **'Passcode removed'**
  String get passcodeRemoved;

  /// No description provided for @unlockApp.
  ///
  /// In en, this message translates to:
  /// **'Unlock App'**
  String get unlockApp;

  /// No description provided for @incorrectPasscode.
  ///
  /// In en, this message translates to:
  /// **'Incorrect passcode'**
  String get incorrectPasscode;

  /// No description provided for @setupPasscodeFirst.
  ///
  /// In en, this message translates to:
  /// **'Please set up a passcode first'**
  String get setupPasscodeFirst;

  /// No description provided for @enableBiometric.
  ///
  /// In en, this message translates to:
  /// **'Enable biometric authentication'**
  String get enableBiometric;

  /// No description provided for @useBiometricToUnlock.
  ///
  /// In en, this message translates to:
  /// **'Use {biometricName} to unlock the app'**
  String useBiometricToUnlock(Object biometricName);

  /// No description provided for @twoStepVerification.
  ///
  /// In en, this message translates to:
  /// **'Two-Step Verification'**
  String get twoStepVerification;

  /// No description provided for @addExtraSecurity.
  ///
  /// In en, this message translates to:
  /// **'Add an extra layer of security'**
  String get addExtraSecurity;

  /// No description provided for @enable2FA.
  ///
  /// In en, this message translates to:
  /// **'Enable Two-Factor Authentication'**
  String get enable2FA;

  /// No description provided for @disable2FA.
  ///
  /// In en, this message translates to:
  /// **'Disable Two-Factor Authentication'**
  String get disable2FA;

  /// No description provided for @enabled.
  ///
  /// In en, this message translates to:
  /// **'Enabled'**
  String get enabled;

  /// No description provided for @disabled.
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get disabled;

  /// No description provided for @verificationVia.
  ///
  /// In en, this message translates to:
  /// **'Verification via {method}'**
  String verificationVia(Object method);

  /// No description provided for @twoFactorDescription.
  ///
  /// In en, this message translates to:
  /// **'Two-step verification adds an extra layer of security by requiring a code from your email or phone when signing in'**
  String get twoFactorDescription;

  /// No description provided for @chooseVerificationMethod.
  ///
  /// In en, this message translates to:
  /// **'Choose Verification Method'**
  String get chooseVerificationMethod;

  /// No description provided for @verificationMethod.
  ///
  /// In en, this message translates to:
  /// **'Verification Method'**
  String get verificationMethod;

  /// No description provided for @emailVerification.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get emailVerification;

  /// No description provided for @smsVerification.
  ///
  /// In en, this message translates to:
  /// **'SMS'**
  String get smsVerification;

  /// No description provided for @comingSoon.
  ///
  /// In en, this message translates to:
  /// **'Coming soon'**
  String get comingSoon;

  /// No description provided for @enterVerificationCode.
  ///
  /// In en, this message translates to:
  /// **'Enter Verification Code'**
  String get enterVerificationCode;

  /// No description provided for @sixDigitCode.
  ///
  /// In en, this message translates to:
  /// **'6-digit code'**
  String get sixDigitCode;

  /// No description provided for @verify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get verify;

  /// No description provided for @twoFactorEnabled.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication enabled'**
  String get twoFactorEnabled;

  /// No description provided for @twoFactorDisabled.
  ///
  /// In en, this message translates to:
  /// **'Two-factor authentication disabled'**
  String get twoFactorDisabled;

  /// No description provided for @disable2FAConfirmation.
  ///
  /// In en, this message translates to:
  /// **'Are you sure you want to disable two-factor authentication?'**
  String get disable2FAConfirmation;

  /// No description provided for @invalidCode.
  ///
  /// In en, this message translates to:
  /// **'Invalid verification code'**
  String get invalidCode;

  /// No description provided for @disable.
  ///
  /// In en, this message translates to:
  /// **'Disable'**
  String get disable;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @autoDeleteMessages.
  ///
  /// In en, this message translates to:
  /// **'Auto-Delete Messages'**
  String get autoDeleteMessages;

  /// No description provided for @automaticallyDeleteOldMessages.
  ///
  /// In en, this message translates to:
  /// **'Automatically delete old messages'**
  String get automaticallyDeleteOldMessages;

  /// No description provided for @autoDeletePeriod.
  ///
  /// In en, this message translates to:
  /// **'Delete messages after'**
  String get autoDeletePeriod;

  /// No description provided for @never.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get never;

  /// No description provided for @twentyFourHours.
  ///
  /// In en, this message translates to:
  /// **'24 hours'**
  String get twentyFourHours;

  /// No description provided for @sevenDays.
  ///
  /// In en, this message translates to:
  /// **'7 days'**
  String get sevenDays;

  /// No description provided for @thirtyDays.
  ///
  /// In en, this message translates to:
  /// **'30 days'**
  String get thirtyDays;

  /// No description provided for @autoDeleteEnabled.
  ///
  /// In en, this message translates to:
  /// **'Auto-delete enabled'**
  String get autoDeleteEnabled;

  /// No description provided for @autoDeleteDisabled.
  ///
  /// In en, this message translates to:
  /// **'Auto-delete disabled'**
  String get autoDeleteDisabled;

  /// No description provided for @autoDeleteDescription.
  ///
  /// In en, this message translates to:
  /// **'Messages older than the selected period will be automatically deleted from your device'**
  String get autoDeleteDescription;

  /// No description provided for @messagesOlderThan.
  ///
  /// In en, this message translates to:
  /// **'Messages older than {period} will be deleted'**
  String messagesOlderThan(Object period);

  /// No description provided for @autoDeleteWarning.
  ///
  /// In en, this message translates to:
  /// **'Warning: Deleted messages cannot be recovered'**
  String get autoDeleteWarning;

  /// No description provided for @editProfile.
  ///
  /// In en, this message translates to:
  /// **'Edit Profile'**
  String get editProfile;

  /// No description provided for @showUsernameTitle.
  ///
  /// In en, this message translates to:
  /// **'Show Username'**
  String get showUsernameTitle;

  /// No description provided for @showUsernameSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Display your username to others'**
  String get showUsernameSubtitle;

  /// No description provided for @sosModeTitle.
  ///
  /// In en, this message translates to:
  /// **'SOS Mode (Mesh Relay)'**
  String get sosModeTitle;

  /// No description provided for @enableRelayTitle.
  ///
  /// In en, this message translates to:
  /// **'Enable Relay'**
  String get enableRelayTitle;

  /// No description provided for @enableRelaySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Allow your device to forward messages for others'**
  String get enableRelaySubtitle;

  /// No description provided for @maxHops.
  ///
  /// In en, this message translates to:
  /// **'Max Hops'**
  String get maxHops;

  /// No description provided for @hopsCount.
  ///
  /// In en, this message translates to:
  /// **'{count} hops'**
  String hopsCount(Object count);

  /// No description provided for @sosModeDescription.
  ///
  /// In en, this message translates to:
  /// **'SOS mode routes messages through nearby devices when direct connection is unavailable.'**
  String get sosModeDescription;

  /// No description provided for @meshNetwork.
  ///
  /// In en, this message translates to:
  /// **'Mesh Network'**
  String get meshNetwork;

  /// No description provided for @nearbyPeers.
  ///
  /// In en, this message translates to:
  /// **'Nearby Peers: {count}'**
  String nearbyPeers(Object count);

  /// No description provided for @debugLogs.
  ///
  /// In en, this message translates to:
  /// **'Debug Logs'**
  String get debugLogs;

  /// No description provided for @clearAllDataTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear All Data'**
  String get clearAllDataTitle;

  /// No description provided for @clearAllDataSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Delete all messages, contacts, and posts'**
  String get clearAllDataSubtitle;

  /// No description provided for @clearAllDataDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear All Data?'**
  String get clearAllDataDialogTitle;

  /// No description provided for @clearAllDataDialogContent.
  ///
  /// In en, this message translates to:
  /// **'This will delete all your messages, contacts, and posts. This cannot be undone.'**
  String get clearAllDataDialogContent;

  /// No description provided for @allDataCleared.
  ///
  /// In en, this message translates to:
  /// **'All data cleared!'**
  String get allDataCleared;

  /// No description provided for @faqTitle.
  ///
  /// In en, this message translates to:
  /// **'Help & FAQ'**
  String get faqTitle;

  /// No description provided for @faqQuickStartTitle.
  ///
  /// In en, this message translates to:
  /// **'🚀 Quick Start Guide'**
  String get faqQuickStartTitle;

  /// No description provided for @faqQuickStartSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Learn how to use all RAVEN features'**
  String get faqQuickStartSubtitle;

  /// No description provided for @faqSendMessageTitle.
  ///
  /// In en, this message translates to:
  /// **'📱 Send Message'**
  String get faqSendMessageTitle;

  /// No description provided for @faqSendMessageQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I send a message?'**
  String get faqSendMessageQuestion;

  /// No description provided for @faqSendMessageSteps.
  ///
  /// In en, this message translates to:
  /// **'1. Tap the \"Messages\" tab\n2. Tap the ➕ or ✏️ icon\n3. Search for or select a contact\n4. Type your message and tap send ✓\n\nImportant: If you don\'t have internet, messages go via Bluetooth to nearby phones!'**
  String get faqSendMessageSteps;

  /// No description provided for @faqAddFriendTitle.
  ///
  /// In en, this message translates to:
  /// **'👥 Add Friend'**
  String get faqAddFriendTitle;

  /// No description provided for @faqAddFriendQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I add friends?'**
  String get faqAddFriendQuestion;

  /// No description provided for @faqAddFriendSteps.
  ///
  /// In en, this message translates to:
  /// **'Method 1 - Search:\n1. Go to \"Search\" tab\n2. Type your friend\'s username\n3. Tap their name and \"Send Friend Request\"\n\nMethod 2 - QR Code:\n1. Go to Settings → \"My QR Code\"\n2. Have your friend scan your QR or scan theirs\nThis is the fastest and safest way!'**
  String get faqAddFriendSteps;

  /// No description provided for @faqCreatePostTitle.
  ///
  /// In en, this message translates to:
  /// **'📝 Create Post'**
  String get faqCreatePostTitle;

  /// No description provided for @faqCreatePostQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I post?'**
  String get faqCreatePostQuestion;

  /// No description provided for @faqCreatePostSteps.
  ///
  /// In en, this message translates to:
  /// **'1. Tap the \"Home\" tab\n2. Tap the ➕ button at the bottom\n3. Write your text (max 280 characters)\n4. You can also add a photo 📷\n5. Tap \"Post\"\n\nNote: Posts are public! Use Messages for private conversations.'**
  String get faqCreatePostSteps;

  /// No description provided for @faqAiTitle.
  ///
  /// In en, this message translates to:
  /// **'🤖 AI Assistant'**
  String get faqAiTitle;

  /// No description provided for @faqAiQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I ask the AI?'**
  String get faqAiQuestion;

  /// No description provided for @faqAiSteps.
  ///
  /// In en, this message translates to:
  /// **'In any post\'s comments:\n1. Open a post\'s comments\n2. Type: @time_ask your question\n3. Example: \"@time_ask what\'s the weather today?\"\n4. AI will reply as a comment!\n\nThis feature is for general questions, translations, and getting help.'**
  String get faqAiSteps;

  /// No description provided for @faqVoiceTitle.
  ///
  /// In en, this message translates to:
  /// **'🔊 Voice Message'**
  String get faqVoiceTitle;

  /// No description provided for @faqVoiceQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I send voice messages?'**
  String get faqVoiceQuestion;

  /// No description provided for @faqVoiceSteps.
  ///
  /// In en, this message translates to:
  /// **'1. Go to a chat\n2. Hold the 🎤 (microphone) button\n3. Talk while holding\n4. Release to send!\n\nTip: Slide left to cancel.'**
  String get faqVoiceSteps;

  /// No description provided for @faqBackupTitle.
  ///
  /// In en, this message translates to:
  /// **'💾 Backup'**
  String get faqBackupTitle;

  /// No description provided for @faqBackupQuestion.
  ///
  /// In en, this message translates to:
  /// **'How do I backup my chats?'**
  String get faqBackupQuestion;

  /// No description provided for @faqBackupSteps.
  ///
  /// In en, this message translates to:
  /// **'1. Go to \"Settings\"\n2. Tap \"Backup & Restore\"\n3. Tap \"Create Backup\"\n4. Wait for upload to complete ✓\n\nBackups are stored on iCloud and encrypted.'**
  String get faqBackupSteps;

  /// No description provided for @faqSectionTitle.
  ///
  /// In en, this message translates to:
  /// **'❓ Frequently Asked Questions'**
  String get faqSectionTitle;

  /// No description provided for @faqSectionSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Answers to common questions'**
  String get faqSectionSubtitle;

  /// No description provided for @faqWhatIsRaivenTitle.
  ///
  /// In en, this message translates to:
  /// **'What is RAVEN? 🐦'**
  String get faqWhatIsRaivenTitle;

  /// No description provided for @faqWhatIsRaivenAnswer.
  ///
  /// In en, this message translates to:
  /// **'RAVEN is a special and unique messaging app!\n\nWhy special? Because it works even without internet!\n\nWith internet → Messages go through the server (fast)\nWithout internet → Messages go via Bluetooth (smart)\n\nThis means in the subway, mountains, or anywhere without signal, you can still message! ✨'**
  String get faqWhatIsRaivenAnswer;

  /// No description provided for @faqOfflineTitle.
  ///
  /// In en, this message translates to:
  /// **'How does offline messaging work? 📡'**
  String get faqOfflineTitle;

  /// No description provided for @faqOfflineAnswer.
  ///
  /// In en, this message translates to:
  /// **'It\'s simple:\n\n1. You send a message\n2. No internet, so it\'s stored on your phone\n3. Your phone uses Bluetooth\n4. Message goes to nearby phones with RAVEN\n5. They forward to others\n6. Until it reaches the destination!\n\nLike a chain! Each phone is a link 🔗'**
  String get faqOfflineAnswer;

  /// No description provided for @faqSecurityTitle.
  ///
  /// In en, this message translates to:
  /// **'Are my messages secure? 🔒'**
  String get faqSecurityTitle;

  /// No description provided for @faqSecurityAnswer.
  ///
  /// In en, this message translates to:
  /// **'100% secure!\n\n✅ End-to-end encryption\nOnly you and the recipient can read\n\n✅ Keys stored on your device\nNo one, not even us, has access\n\n✅ Bluetooth messages are also encrypted\nEven relay devices can\'t read them\n\nRest assured! 🛡️'**
  String get faqSecurityAnswer;

  /// No description provided for @faqStatusTitle.
  ///
  /// In en, this message translates to:
  /// **'What do the message symbols mean? ✓'**
  String get faqStatusTitle;

  /// No description provided for @faqStatusAnswer.
  ///
  /// In en, this message translates to:
  /// **'⏳ Pending - Message is in send queue\n✓ Sent - Message left your phone\n✓✓ Delivered - Message reached recipient\'s phone\n👁 Read - Recipient opened the message\n\nNote: If it takes long, recipient may be offline.'**
  String get faqStatusAnswer;

  /// No description provided for @faqBridgeTitle.
  ///
  /// In en, this message translates to:
  /// **'What is Bridge Mode? 🌉'**
  String get faqBridgeTitle;

  /// No description provided for @faqBridgeAnswer.
  ///
  /// In en, this message translates to:
  /// **'An awesome feature!\n\nImagine you don\'t have internet but send a message.\nMessage goes via Bluetooth to nearby phones.\nOne of those phones HAS internet!\nThat phone sends your message via server.\n\nSo it crosses a bridge! 🎯\nThis happens automatically.'**
  String get faqBridgeAnswer;

  /// No description provided for @faqInternetTitle.
  ///
  /// In en, this message translates to:
  /// **'Do I need internet? 📶'**
  String get faqInternetTitle;

  /// No description provided for @faqInternetAnswer.
  ///
  /// In en, this message translates to:
  /// **'No! This is RAVEN\'s biggest advantage!\n\nWith internet → Everything is faster\nWithout internet → Bluetooth is used\n\nThe app auto-detects and switches.\nJust write your message, we handle the rest! 💪'**
  String get faqInternetAnswer;

  /// No description provided for @faqDuplicateTitle.
  ///
  /// In en, this message translates to:
  /// **'Will I get duplicate messages? 🔄'**
  String get faqDuplicateTitle;

  /// No description provided for @faqDuplicateAnswer.
  ///
  /// In en, this message translates to:
  /// **'No!\n\nEach message has a unique ID (like a fingerprint).\nEven if a message arrives via multiple routes (Bluetooth AND server), the app knows and shows it only once.\n\nDon\'t worry about duplicates! ✓'**
  String get faqDuplicateAnswer;

  /// No description provided for @faqDtnTitle.
  ///
  /// In en, this message translates to:
  /// **'What is DTN? 🔬'**
  String get faqDtnTitle;

  /// No description provided for @faqDtnAnswer.
  ///
  /// In en, this message translates to:
  /// **'DTN = Delay-Tolerant Networking\nMeans \"network that tolerates delays\"\n\nSimply put:\nA technology that stores the message, carries it, and sends when conditions are right.\n\nEven if it takes a day! (But usually much faster 😄)\n\nThis technology was originally built for spacecraft communication! 🚀'**
  String get faqDtnAnswer;

  /// No description provided for @faqLanguagesTitle.
  ///
  /// In en, this message translates to:
  /// **'What languages are supported? 🌍'**
  String get faqLanguagesTitle;

  /// No description provided for @faqLanguagesAnswer.
  ///
  /// In en, this message translates to:
  /// **'RAVEN is fully translated to:\n\n🇺🇸 English\n🇮🇷 Persian (with RTL support)\n🇪🇸 Spanish\n🇩🇪 German\n🇨🇳 Chinese\n\nGo to Settings → Language to change!'**
  String get faqLanguagesAnswer;

  /// No description provided for @faqTipsTitle.
  ///
  /// In en, this message translates to:
  /// **'💡 Tips & Tricks'**
  String get faqTipsTitle;

  /// No description provided for @faqTipsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Use better!'**
  String get faqTipsSubtitle;

  /// No description provided for @faqTipBluetooth.
  ///
  /// In en, this message translates to:
  /// **'Keep Bluetooth on'**
  String get faqTipBluetooth;

  /// No description provided for @faqTipBluetoothDesc.
  ///
  /// In en, this message translates to:
  /// **'Even with internet! You help others get their messages.'**
  String get faqTipBluetoothDesc;

  /// No description provided for @faqTipBackup.
  ///
  /// In en, this message translates to:
  /// **'Backup regularly'**
  String get faqTipBackup;

  /// No description provided for @faqTipBackupDesc.
  ///
  /// In en, this message translates to:
  /// **'Backup weekly so you don\'t lose your chats.'**
  String get faqTipBackupDesc;

  /// No description provided for @faqTipQr.
  ///
  /// In en, this message translates to:
  /// **'Use QR codes'**
  String get faqTipQr;

  /// No description provided for @faqTipQrDesc.
  ///
  /// In en, this message translates to:
  /// **'For adding friends, QR scan is faster and safer!'**
  String get faqTipQrDesc;

  /// No description provided for @faqTipNotifications.
  ///
  /// In en, this message translates to:
  /// **'Check notifications'**
  String get faqTipNotifications;

  /// No description provided for @faqTipNotificationsDesc.
  ///
  /// In en, this message translates to:
  /// **'Friend requests, likes and comments are there!'**
  String get faqTipNotificationsDesc;

  /// No description provided for @faqContactTitle.
  ///
  /// In en, this message translates to:
  /// **'Have a question?'**
  String get faqContactTitle;

  /// No description provided for @faqContactEmail.
  ///
  /// In en, this message translates to:
  /// **'info@raven-messager.com'**
  String get faqContactEmail;

  /// No description provided for @faqWhitepaperTitle.
  ///
  /// In en, this message translates to:
  /// **'Where is the technical whitepaper? 📄'**
  String get faqWhitepaperTitle;

  /// No description provided for @faqWhitepaperAnswer.
  ///
  /// In en, this message translates to:
  /// **'We have a full technical whitepaper on our website!\\n\\n📍 Visit: raven-messager.com/technology.html\\n\\nIt covers:\\n• Hybrid Architecture (Internet + Mesh)\\n• Offline Delivery (DTN Protocol)\\n• Anti-Duplicate Algorithm\\n• Privacy Model\\n• Security Overview\\n\\nVersion: v0.1 — January 2026'**
  String get faqWhitepaperAnswer;

  /// No description provided for @technicalOverviewTitle.
  ///
  /// In en, this message translates to:
  /// **'How RAVEN Works'**
  String get technicalOverviewTitle;

  /// No description provided for @technicalOverviewSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Technical overview of architecture and security'**
  String get technicalOverviewSubtitle;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['de', 'en', 'es', 'fa', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'de':
      return AppLocalizationsDe();
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
    case 'fa':
      return AppLocalizationsFa();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
