import 'dart:io';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

/// OAuth User Data from provider
class OAuthUserData {
  final String provider; // 'google' or 'apple'
  final String providerId; // Provider's unique user ID
  final String? email;
  final String? firstName;
  final String? lastName;
  final String? idToken; // For backend verification
  final String? authorizationCode; // For Apple Sign-In

  OAuthUserData({
    required this.provider,
    required this.providerId,
    this.email,
    this.firstName,
    this.lastName,
    this.idToken,
    this.authorizationCode,
  });

  String get fullName {
    if (firstName != null && lastName != null) {
      return '$firstName $lastName';
    }
    return firstName ?? lastName ?? email ?? 'User';
  }
}

class OAuthService {
  static final OAuthService _instance = OAuthService._internal();
  factory OAuthService() => _instance;
  OAuthService._internal();

  // Google Sign-In instance
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
  );

  /// Sign in with Google
  /// Returns OAuthUserData on success, null on cancellation
  /// Throws exception on error
  Future<OAuthUserData?> signInWithGoogle() async {
    try {
      print('🔵 Starting Google Sign-In...');
      
      // Trigger the Google Sign-In flow
      final GoogleSignInAccount? account = await _googleSignIn.signIn();
      
      if (account == null) {
        // User cancelled the sign-in
        print('⚠️ Google Sign-In cancelled by user');
        return null;
      }

      // Get authentication details
      final GoogleSignInAuthentication auth = await account.authentication;
      
      print('✅ Google Sign-In successful: ${account.email}');
      
      return OAuthUserData(
        provider: 'google',
        providerId: account.id,
        email: account.email,
        firstName: account.displayName?.split(' ').first,
        lastName: account.displayName?.split(' ').skip(1).join(' '),
        idToken: auth.idToken,
      );
    } catch (e) {
      print('❌ Google Sign-In error: $e');
      throw Exception('Google Sign-In failed: $e');
    }
  }

  /// Sign in with Apple
  /// Returns OAuthUserData on success, null on cancellation
  /// Throws exception on error
  Future<OAuthUserData?> signInWithApple() async {
    // Apple Sign-In is only available on iOS and macOS
    if (!Platform.isIOS && !Platform.isMacOS) {
      throw Exception('Apple Sign-In is only available on iOS and macOS');
    }

    try {
      print('🍎 Starting Apple Sign-In...');

      // Check if Apple Sign-In is available
      final isAvailable = await SignInWithApple.isAvailable();
      if (!isAvailable) {
        throw Exception('Apple Sign-In is not available on this device');
      }

      // Trigger the Apple Sign-In flow
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      print('✅ Apple Sign-In successful: ${credential.userIdentifier}');

      // Note: Apple only provides name on first sign-in
      // After that, givenName and familyName will be null
      return OAuthUserData(
        provider: 'apple',
        providerId: credential.userIdentifier ?? '',
        email: credential.email,
        firstName: credential.givenName,
        lastName: credential.familyName,
        idToken: credential.identityToken,
        authorizationCode: credential.authorizationCode,
      );
    } catch (e) {
      print('❌ Apple Sign-In error: $e');
      
      // User cancelled
      if (e.toString().contains('canceled') || 
          e.toString().contains('The user canceled')) {
        print('⚠️ Apple Sign-In cancelled by user');
        return null;
      }
      
      throw Exception('Apple Sign-In failed: $e');
    }
  }

  /// Sign out from Google
  Future<void> signOutGoogle() async {
    try {
      await _googleSignIn.signOut();
      print('✅ Signed out from Google');
    } catch (e) {
      print('❌ Google sign-out error: $e');
    }
  }

  /// Check if user is currently signed in with Google
  Future<bool> isSignedInWithGoogle() async {
    return await _googleSignIn.isSignedIn();
  }
}
