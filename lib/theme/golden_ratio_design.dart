/// Golden Ratio Design System
/// φ (phi) ≈ 1.618033988749
/// 
/// This file contains all design constants based on the Golden Ratio
/// for mathematically balanced, premium aesthetics.

class GoldenRatio {
  // Core constants
  static const double phi = 1.618033988749;
  static const double phiReciprocal = 0.618033988749;
  
  // ==================== Spacing Scale ====================
  // Base: 16px, derived using φ
  
  static const double space4 = 4.0;
  static const double space8 = 8.0;
  static const double space10 = 10.0;   // 16/φ ≈ 9.9
  static const double space12 = 12.0;   // 20/φ ≈ 12.4
  static const double space16 = 16.0;
  static const double space20 = 20.0;
  static const double space24 = 24.0;   // 16×1.5
  static const double space26 = 26.0;   // 16×φ ≈ 25.9
  static const double space40 = 40.0;   // 24×φ ≈ 38.8
  static const double space64 = 64.0;   // 40×φ ≈ 64.7
  
  // ==================== Typography Scale ====================
  // Progressive scale using φ
  
  static const double fontCaption = 10.0;
  static const double fontSmall = 12.0;
  static const double fontBody = 16.0;
  static const double fontSubtitle = 20.0;  // 12×φ ≈ 19.4
  static const double fontTitle = 26.0;     // 16×φ ≈ 25.9
  static const double fontHeading = 42.0;   // 26×φ ≈ 42.1
  
  // ==================== Component Dimensions ====================
  
  // Bottom Dock
  static const double dockHeight = 56.0;
  static const double dockCollapsedSize = 20.0;
  static const double dockIconSize = 34.0;       // 56/φ ≈ 34.6
  static const double dockRadius = 20.0;
  static const double dockInnerRadius = 12.0;    // 20/φ ≈ 12.4
  
  // Post Cards
  static const double cardMaxWidth = 343.0;      // iPhone 15 Pro safe width
  static const double cardHeight = 212.0;        // 343/φ ≈ 212.0
  static const double cardPadding = 16.0;
  static const double cardInnerPadding = 10.0;   // 16/φ ≈ 9.9
  static const double cardRadius = 16.0;
  static const double cardInnerRadius = 10.0;    // 16/φ
  
  // Glass Cards (smaller variants)
  static const double glassCardPadding = 12.0;
  static const double glassCardInnerPadding = 8.0;  // 12/φ ≈ 7.4
  
  // ==================== Layout Proportions ====================
  // For 680px usable height
  
  static const double headerHeight = 260.0;      // 680/(1+φ) ≈ 259.8
  static const double bodyHeight = 420.0;        // 680 - 260
  
  // CTA Positioning
  static const double ctaVerticalPosition = 0.618;  // From top or bottom
  
  // ==================== Helper Methods ====================
  
  /// Calculate φ-based dimension from base value
  static double scaled(double base, {int steps = 1}) {
    return base * (phi * steps);
  }
  
  /// Calculate reciprocal φ dimension
  static double reciprocal(double base) {
    return base * phiReciprocal;
  }
  
  /// Get spacing value at specific step
  static double spacing(int step) {
    switch (step) {
      case 1: return space4;
      case 2: return space8;
      case 3: return space10;
      case 4: return space12;
      case 5: return space16;
      case 6: return space20;
      case 7: return space24;
      case 8: return space26;
      case 9: return space40;
      case 10: return space64;
      default: return space16;
    }
  }
}
