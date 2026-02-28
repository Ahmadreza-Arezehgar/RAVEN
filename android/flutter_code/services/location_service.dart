import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

/// Location Service - GPS-based country detection
class LocationService {
  /// Get user's current country code (e.g., 'us', 'uk', 'de')
  static Future<String> getUserCountry() async {
    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('⚠️ Location services disabled, defaulting to US');
        return 'us';
      }

      // Check permissions
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          print('⚠️ Location permission denied, defaulting to US');
          return 'us';
        }
      }

      if (permission == LocationPermission.deniedForever) {
        print('⚠️ Location permission denied forever, defaulting to US');
        return 'us';
      }

      // Get current position
      print('📍 Getting GPS location...');
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low, // Low accuracy is sufficient
        timeLimit: const Duration(seconds: 10),
      );

      print('📍 Location: ${position.latitude}, ${position.longitude}');

      // Reverse geocode to get country
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (placemarks.isNotEmpty) {
        final country = placemarks.first.isoCountryCode?.toLowerCase() ?? 'us';
        print('🌍 Detected country: $country');
        return country;
      }

      return 'us';
    } catch (e) {
      print('❌ Error getting location: $e');
      return 'us';
    }
  }

  /// Check if location permission is granted
  static Future<bool> hasLocationPermission() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }
}
