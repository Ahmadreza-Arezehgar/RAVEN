import 'dart:math';
import 'package:geolocator/geolocator.dart';

/// Geohash Service - Location encoding for Dead Drops
/// 
/// Encodes GPS coordinates into geohash strings for proximity-based
/// message discovery. Precision 9 gives ~4.77m accuracy.
class GeohashService {
  static final GeohashService _instance = GeohashService._();
  static GeohashService get instance => _instance;
  GeohashService._();

  // Geohash base32 alphabet
  static const _base32 = '0123456789bcdefghjkmnpqrstuvwxyz';
  
  // Cached location
  Position? _cachedPosition;
  DateTime? _cacheTime;
  static const _cacheValiditySeconds = 60; // 1 minute cache

  /// Get current geohash cell (precision 9 ~= 4.77m)
  /// Falls back to empty string if location unavailable
  Future<String> getCurrentGeohash({int precision = 9}) async {
    try {
      final position = await _getPosition();
      if (position == null) return '';
      
      return encode(position.latitude, position.longitude, precision: precision);
    } catch (e) {
      print('⚠️ [GeohashService] Error getting geohash: $e');
      return '';
    }
  }

  /// Get cached position or fetch new one
  Future<Position?> _getPosition() async {
    // Return cached if still valid
    if (_cachedPosition != null && _cacheTime != null) {
      final age = DateTime.now().difference(_cacheTime!).inSeconds;
      if (age < _cacheValiditySeconds) {
        return _cachedPosition;
      }
    }
    
    // Check permissions
    if (!await _checkPermissions()) {
      return null;
    }
    
    // Fetch new position
    try {
      _cachedPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 10),
      );
      _cacheTime = DateTime.now();
      return _cachedPosition;
    } catch (e) {
      print('⚠️ [GeohashService] Position fetch failed: $e');
      return null;
    }
  }

  /// Check location permissions
  Future<bool> _checkPermissions() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;
    
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    
    return permission == LocationPermission.always || 
           permission == LocationPermission.whileInUse;
  }

  /// Encode latitude/longitude to geohash string
  String encode(double latitude, double longitude, {int precision = 9}) {
    double latMin = -90.0, latMax = 90.0;
    double lngMin = -180.0, lngMax = 180.0;
    
    final buffer = StringBuffer();
    var isEven = true;
    var bit = 0;
    var ch = 0;
    
    while (buffer.length < precision) {
      if (isEven) {
        // Longitude
        final mid = (lngMin + lngMax) / 2;
        if (longitude >= mid) {
          ch |= (1 << (4 - bit));
          lngMin = mid;
        } else {
          lngMax = mid;
        }
      } else {
        // Latitude
        final mid = (latMin + latMax) / 2;
        if (latitude >= mid) {
          ch |= (1 << (4 - bit));
          latMin = mid;
        } else {
          latMax = mid;
        }
      }
      
      isEven = !isEven;
      bit++;
      
      if (bit == 5) {
        buffer.write(_base32[ch]);
        bit = 0;
        ch = 0;
      }
    }
    
    return buffer.toString();
  }

  /// Decode geohash string to latitude/longitude bounds
  Map<String, double> decode(String geohash) {
    double latMin = -90.0, latMax = 90.0;
    double lngMin = -180.0, lngMax = 180.0;
    
    var isEven = true;
    
    for (int i = 0; i < geohash.length; i++) {
      final ch = _base32.indexOf(geohash[i].toLowerCase());
      if (ch == -1) continue;
      
      for (int bit = 4; bit >= 0; bit--) {
        final bitValue = (ch >> bit) & 1;
        
        if (isEven) {
          final mid = (lngMin + lngMax) / 2;
          if (bitValue == 1) {
            lngMin = mid;
          } else {
            lngMax = mid;
          }
        } else {
          final mid = (latMin + latMax) / 2;
          if (bitValue == 1) {
            latMin = mid;
          } else {
            latMax = mid;
          }
        }
        
        isEven = !isEven;
      }
    }
    
    return {
      'latitude': (latMin + latMax) / 2,
      'longitude': (lngMin + lngMax) / 2,
      'latMin': latMin,
      'latMax': latMax,
      'lngMin': lngMin,
      'lngMax': lngMax,
    };
  }

  /// Get neighboring geohash cells
  List<String> getNeighbors(String geohash) {
    if (geohash.isEmpty) return [];
    
    final bounds = decode(geohash);
    final lat = bounds['latitude']!;
    final lng = bounds['longitude']!;
    
    // Calculate cell size
    final latDelta = bounds['latMax']! - bounds['latMin']!;
    final lngDelta = bounds['lngMax']! - bounds['lngMin']!;
    
    // Get 8 neighbors
    final neighbors = <String>[];
    for (int dLat = -1; dLat <= 1; dLat++) {
      for (int dLng = -1; dLng <= 1; dLng++) {
        if (dLat == 0 && dLng == 0) continue;
        
        final neighborLat = lat + dLat * latDelta;
        final neighborLng = lng + dLng * lngDelta;
        
        if (neighborLat >= -90 && neighborLat <= 90 &&
            neighborLng >= -180 && neighborLng <= 180) {
          neighbors.add(encode(neighborLat, neighborLng, precision: geohash.length));
        }
      }
    }
    
    return neighbors;
  }

  /// Calculate distance between two positions in meters
  double distanceBetween(double lat1, double lng1, double lat2, double lng2) {
    const earthRadius = 6371000.0; // meters
    
    final dLat = _toRadians(lat2 - lat1);
    final dLng = _toRadians(lng2 - lng1);
    
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_toRadians(lat1)) * cos(_toRadians(lat2)) *
        sin(dLng / 2) * sin(dLng / 2);
    
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    
    return earthRadius * c;
  }

  double _toRadians(double degrees) => degrees * pi / 180;

  /// Get readable geohash precision levels
  static String getPrecisionDescription(int precision) {
    switch (precision) {
      case 1: return '~5000 km';
      case 2: return '~1250 km';
      case 3: return '~156 km';
      case 4: return '~39 km';
      case 5: return '~4.9 km';
      case 6: return '~1.2 km';
      case 7: return '~153 m';
      case 8: return '~38 m';
      case 9: return '~4.8 m';
      default: return '~${pow(0.25, precision - 4)} km';
    }
  }
}
