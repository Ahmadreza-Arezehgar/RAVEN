import 'package:flutter_test/flutter_test.dart';
import 'package:hybrid_messenger/utils/raven_invite.dart';

void main() {
  const addr = 'rvn1q9yj9dcp4gvs6ah3uhgepslz7rqfuk9445njwaku';
  const pub = 'd77c39dac44b539bdd28e59e3688953be41898288a0a5e9de48e40e6e36798a8';

  test('encode produces raven:addr:pub', () {
    expect(RavenInvite.encode(address: addr, pubHex: pub),
        'raven:$addr:$pub');
  });

  test('decode exact raven: string', () {
    final d = RavenInvite.decode('raven:$addr:$pub')!;
    expect(d.address, addr);
    expect(d.pubHex, pub);
    expect(d.fingerprint, isNotEmpty);
  });

  test('decode ash whoami block', () {
    final block = '''
address     $addr
fingerprint SSK3-AaoZ-DXbx
pub_hex     $pub
''';
    final d = RavenInvite.decode(block)!;
    expect(d.address, addr);
    expect(d.pubHex, pub);
  });

  test('decode from noisy surrounding text', () {
    final d = RavenInvite.decode(
        'hey here is my raven: $addr and my key is $pub thanks!')!;
    expect(d.address, addr);
    expect(d.pubHex, pub);
  });

  test('returns null for garbage', () {
    expect(RavenInvite.decode('hello world'), isNull);
    expect(RavenInvite.decode('raven:bad'), isNull);
  });

  test('uppercase hex normalized to lowercase', () {
    final d = RavenInvite.decode('raven:$addr:${pub.toUpperCase()}')!;
    expect(d.pubHex, pub);
  });
}
