import 'dart:io';
import 'protected_app.dart';

/// Escapes [s] for use inside a PowerShell single-quoted string. PowerShell
/// treats the typographic quotes ‘ ’ ‚ ‛ as single quotes too, so each of
/// them — like `'` — must be doubled, or a label such as `L’app` would end
/// the string early and let the rest run as code.
String psQuote(String s) => s.replaceAllMapped(RegExp('[\'‘’‚‛]'), (m) => '${m[0]}${m[0]}');

/// A safe `.lnk` file base name for [label]: Windows-forbidden characters
/// removed, trailing dots/spaces trimmed (Windows silently drops them),
/// capped at 100 characters, `Application` when nothing is left.
String shortcutBaseName(String label) {
  var s = label.replaceAll(RegExp(r'[\\/:*?"<>|]'), '').replaceAll(RegExp(r'[\x00-\x1f]'), '').trim();
  if (s.length > 100) s = s.substring(0, 100);
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  return s.isEmpty ? 'Application' : s;
}

Future<String> createProtectedShortcut({required ProtectedApp app, required String exePath, String? dir}) async {
  final desktop = dir ?? '${Platform.environment['USERPROFILE']}\\Desktop';
  final lnk = '$desktop\\${shortcutBaseName(app.label)} (BioKey).lnk';
  final q = psQuote;
  final ps = "\$s=(New-Object -ComObject WScript.Shell).CreateShortcut('${q(lnk)}');"
      "\$s.TargetPath='${q(exePath)}';\$s.Arguments='open ${q(app.id)}';"
      "${app.target.contains('://') ? '' : "\$s.IconLocation='${q(app.target)},0';"}\$s.Save()";
  final r = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', ps]);
  if (r.exitCode != 0) throw Exception('Création du raccourci impossible : ${r.stderr}');
  return lnk;
}
