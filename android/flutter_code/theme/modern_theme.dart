import 'package:flutter/material.dart';

class ModernTheme {
  // ===  COLORS (Dark Mode First) ===
  
  // Backgrounds
  static const background = Color(0xFF0E0E0E);
  static const surface = Color(0xFF1C1C1E);
  static const surfaceVariant = Color(0xFF2C2C2E);
  
  // Gradients
  static final primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
  );
  
  static final accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF093FB), Color(0xFF4FACFE)],
  );
  
  static final senderBubbleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF54A5FF), Color(0xFF248CFF)],
  );
  
  static final receiverBubbleGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2C2C2E), Color(0xFF3C3C3E)],
  );
  
  // Text Colors
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFAAAAAA);
  static const textTertiary = Color(0xFF666666);
  
  // Accent Colors
  static const accentBlue = Color(0xFF54A5FF);
  static const accentPurple = Color(0xFF764BA2);
  static const accentPink = Color(0xFFF093FB);
  
  // Status Colors
  static const success = Color(0xFF42BB2F);
  static const warning = Color(0xFFFFCC00);
  static const error = Color(0xFFFF3B30);
  
  // === TYPOGRAPHY ===
  
  static const String fontFamily = 'SF Pro Display'; // iOS style
  
  static const heading1 = TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: textPrimary,
  );
  
  static const heading2 = TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    color: textPrimary,
  );
  
  static const heading3 = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: textPrimary,
  );
  
  static const body = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.2,
    color: textPrimary,
  );
  
  static const bodyBold = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    color: textPrimary,
  );
  
  static const caption = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
    color: textSecondary,
  );
  
  static const tiny = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.2,
    color: textTertiary,
  );
  
  // === SPACING ===
  
  static const double spacing4 = 4.0;
  static const double spacing8 = 8.0;
  static const double spacing12 = 12.0;
  static const double spacing16 = 16.0;
  static const double spacing20 = 20.0;
  static const double spacing24 = 24.0;
  static const double spacing32 = 32.0;
  
  // === CORNER RADIUS ===
  
  static const double radiusSmall = 8.0;
  static const double radiusMedium = 12.0;
  static const double radiusLarge = 16.0;
  static const double radiusXLarge = 20.0;
  static const double radiusRound = 9999.0;
  
  // === CHAT BUBBLE RADII ===
  
  static BorderRadius chatBubbleRadius({required bool isMe}) {
    return BorderRadius.only(
      topLeft: Radius.circular(20),
      topRight: Radius.circular(20),
      bottomLeft: isMe ? Radius.circular(20) : Radius.circular(4),
      bottomRight: isMe ? Radius.circular(4) : Radius.circular(20),
    );
  }
  
  // === SHADOWS ===
  
  static final List<BoxShadow> shadowSoft = [
    BoxShadow(
      color: Colors.black.withOpacity(0.1),
      blurRadius: 8,
      offset: Offset(0, 2),
    ),
  ];
  
  static final List<BoxShadow> shadowMedium = [
    BoxShadow(
      color: Colors.black.withOpacity(0.2),
      blurRadius: 12,
      offset: Offset(0, 4),
    ),
  ];
  
  static final List<BoxShadow> shadowStrong = [
    BoxShadow(
      color: Colors.black.withOpacity(0.3),
      blurRadius: 20,
      offset: Offset(0, 8),
    ),
  ];
  
  // === THEME DATA ===
  
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      primaryColor: accentBlue,
      colorScheme: ColorScheme.dark(
        primary: accentBlue,
        secondary: accentPurple,
        surface: surface,
        background: background,
        error: error,
      ),
      textTheme: TextTheme(
        displayLarge: heading1,
        displayMedium: heading2,
        displaySmall: heading3,
        bodyLarge: body,
        bodyMedium: body,
        bodySmall: caption,
      ),
      appBarTheme: AppBarThemeData(
        backgroundColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: heading3,
        iconTheme: IconThemeData(color: textPrimary),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: accentBlue,
        unselectedItemColor: textTertiary,
        type: BottomNavigationBarType.fixed,
      ),
      cardTheme: CardThemeData(
        color: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLarge),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusXLarge),
        ),
      ),
    );
  }
}
