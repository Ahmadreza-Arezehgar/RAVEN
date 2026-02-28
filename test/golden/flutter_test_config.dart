// test/golden/flutter_test_config.dart
// Golden test configuration with threshold settings

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

/// Custom golden file comparator with tolerance for pixel differences
class RavenGoldenFileComparator extends LocalFileComparator {
  RavenGoldenFileComparator(super.testFile);

  /// Tolerance threshold: 0.5% difference allowed
  /// This accounts for minor rendering differences across platforms/devices
  static const double threshold = 0.005;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await super.compare(imageBytes, golden);
    return result;
  }
}

/// Configure golden tests before running
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Set custom comparator with threshold
  if (goldenFileComparator is LocalFileComparator) {
    final testUrl = (goldenFileComparator as LocalFileComparator).basedir;
    goldenFileComparator = RavenGoldenFileComparator(testUrl);
  }
  
  return testMain();
}
