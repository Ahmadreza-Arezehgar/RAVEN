import 'dart:io';
import 'package:flutter/material.dart';

/// Device category based on screen size
enum DeviceCategory {
  /// iPhone SE, Mini models (smaller screens)
  compact,
  /// iPhone 13/14/15 standard models
  standard,
  /// iPhone Pro Max, Plus models (larger screens)
  large,
}

/// Service to optimize UI based on iPhone model characteristics
class DeviceOptimizationService {
  /// Cache the device category to avoid recalculating
  static DeviceCategory? _cachedCategory;
  
  /// Returns device category based on screen dimensions
  /// This helps adapt UI for different iPhone sizes
  static DeviceCategory getDeviceCategory(BuildContext context) {
    if (_cachedCategory != null) return _cachedCategory!;
    
    final size = MediaQuery.of(context).size;
    final height = size.height;
    
    // iPhone SE (3rd gen): 667pt height
    // iPhone Mini: 780pt height
    // iPhone 13/14/15: 844pt - 852pt height
    // iPhone Pro Max: 926pt - 932pt height
    
    if (height < 700) {
      _cachedCategory = DeviceCategory.compact;
    } else if (height < 900) {
      _cachedCategory = DeviceCategory.standard;
    } else {
      _cachedCategory = DeviceCategory.large;
    }
    
    return _cachedCategory!;
  }
  
  /// Get optimized bottom navigation padding based on device
  static double getBottomNavPadding(BuildContext context) {
    final category = getDeviceCategory(context);
    final basePadding = MediaQuery.of(context).padding.bottom;
    
    switch (category) {
      case DeviceCategory.compact:
        return basePadding + 4; // Tighter on SE/Mini
      case DeviceCategory.standard:
        return basePadding + 8; // Standard spacing
      case DeviceCategory.large:
        return basePadding + 12; // More room on Pro Max
    }
  }
  
  /// Get optimized dock height based on device
  static double getDockHeight(BuildContext context) {
    final category = getDeviceCategory(context);
    
    switch (category) {
      case DeviceCategory.compact:
        return 52.0; // Slightly smaller on compact devices
      case DeviceCategory.standard:
        return 56.0; // Standard height
      case DeviceCategory.large:
        return 60.0; // Larger on Pro Max
    }
  }
  
  /// Get optimized icon size for bottom navigation
  static double getNavIconSize(BuildContext context) {
    final category = getDeviceCategory(context);
    
    switch (category) {
      case DeviceCategory.compact:
        return 24.0;
      case DeviceCategory.standard:
        return 26.0;
      case DeviceCategory.large:
        return 28.0;
    }
  }
  
  /// Get optimized safe area bottom offset
  /// This helps prevent overflow on different iPhone models
  static double getSafeBottomOffset(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    
    // iPhone X and later have home indicator (bottom > 0)
    // iPhone SE/8 have physical button (bottom = 0)
    if (bottom > 0) {
      // Devices with home indicator
      return bottom;
    } else {
      // Legacy devices without home indicator
      return 8.0; // Small padding for aesthetic
    }
  }
  
  /// Check if device has notch/Dynamic Island
  static bool hasNotch(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    // Devices with notch/Dynamic Island have top padding > 20
    return topPadding > 24;
  }
  
  /// Check if device has home indicator (no physical button)
  static bool hasHomeIndicator(BuildContext context) {
    return MediaQuery.of(context).padding.bottom > 0;
  }
  
  /// Get device info string for debugging
  static String getDeviceInfo(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final category = getDeviceCategory(context);
    final padding = MediaQuery.of(context).padding;
    
    return '''
Device Info:
- Screen: ${size.width.toInt()} x ${size.height.toInt()}
- Category: ${category.name}
- Safe Area Top: ${padding.top}
- Safe Area Bottom: ${padding.bottom}
- Has Notch: ${hasNotch(context)}
- Has Home Indicator: ${hasHomeIndicator(context)}
''';
  }
}
