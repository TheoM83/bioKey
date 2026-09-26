import 'dart:io' show Platform;

enum Role { phone, desktop }

Role roleForPlatform({required bool isAndroid, required bool isIOS, required bool isDesktop}) {
  if (isAndroid || isIOS) return Role.phone;
  if (isDesktop) return Role.desktop;
  throw UnsupportedError('BioKey ne prend pas en charge cette plateforme');
}

Role detectRole() => roleForPlatform(
      isAndroid: Platform.isAndroid,
      isIOS: Platform.isIOS,
      isDesktop: Platform.isWindows || Platform.isMacOS || Platform.isLinux,
    );
