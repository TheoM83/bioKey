import 'dart:io';
import 'protected_app.dart';

Future<String> createProtectedShortcut({required ProtectedApp app, required String exePath, String? dir}) async {
  final desktop = dir ?? '${Platform.environment['USERPROFILE']}\\Desktop';
  final lnk = '$desktop\\${app.label.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')} (BioKey).lnk';
  String q(String s) => s.replaceAll("'", "''");
  final ps = "\$s=(New-Object -ComObject WScript.Shell).CreateShortcut('${q(lnk)}');"
      "\$s.TargetPath='${q(exePath)}';\$s.Arguments='open ${app.id}';"
      "${app.target.contains('://') ? '' : "\$s.IconLocation='${q(app.target)},0';"}\$s.Save()";
  final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]);
  if (r.exitCode != 0) throw Exception('Création du raccourci impossible : ${r.stderr}');
  return lnk;
}
