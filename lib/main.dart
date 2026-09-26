import 'package:flutter/material.dart';
import 'core/role.dart';
import 'desktop/desktop_app.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (detectRole() == Role.desktop) {
    await runDesktop(args);
    return;
  }
  runApp(BioKeyRoot(role: detectRole(), args: args));
}

class BioKeyRoot extends StatelessWidget {
  const BioKeyRoot({super.key, required this.role, required this.args});
  final Role role;
  final List<String> args;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BioKey',
      theme: ThemeData(colorSchemeSeed: const Color(0xFFD71921), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFFD71921), brightness: Brightness.dark, useMaterial3: true),
      home: Scaffold(body: Center(child: Text(role == Role.phone ? 'BioKey · Téléphone' : 'BioKey · Ordinateur'))),
    );
  }
}
