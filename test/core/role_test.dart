import 'package:flutter_test/flutter_test.dart';
import 'package:biokey/core/role.dart';

void main() {
  test('roleForPlatform maps mobile to phone and desktop to desktop', () {
    expect(roleForPlatform(isAndroid: true, isIOS: false, isDesktop: false), Role.phone);
    expect(roleForPlatform(isAndroid: false, isIOS: true, isDesktop: false), Role.phone);
    expect(roleForPlatform(isAndroid: false, isIOS: false, isDesktop: true), Role.desktop);
  });
}
