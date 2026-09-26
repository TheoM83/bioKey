import 'package:flutter/material.dart';
import 'core/role.dart';
import 'desktop/desktop_app.dart';
import 'phone/phone_app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (detectRole() == Role.desktop) {
    await runDesktop(args);
    return;
  }
  await runPhone();
}
