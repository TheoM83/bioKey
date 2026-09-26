import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/crypto/random.dart';

/// Single-instance guard: the first BioKey process binds a loopback port;
/// later launches (e.g. a protected shortcut `biokey.exe open ID`) forward
/// their arguments to it instead of starting a second instance.
///
/// The channel is authenticated with a random 32-byte token that the first
/// instance writes to `%LOCALAPPDATA%\BioKey\instance.token` (readable only
/// by the same Windows user): any other local process that can reach the
/// port but not the file can't make BioKey act on its behalf. A line is
/// `{"token": "...", "args": [...]}`; accepted lines are answered `ok`.
final class SingleInstance {
  SingleInstance._(this._server);
  static const defaultPort = 47622;
  final ServerSocket _server;

  /// The port actually bound (tests bind port 0).
  int get port => _server.port;

  static String defaultTokenPath() {
    final base = Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return '$base${Platform.pathSeparator}BioKey${Platform.pathSeparator}instance.token';
  }

  static Future<SingleInstance?> acquire({
    required void Function(List<String> args) onArgs,
    int port = defaultPort,
    String? tokenPath,
  }) async {
    final ServerSocket s;
    try {
      s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port, shared: false);
    } on SocketException {
      return null;
    }
    // Only once we own the port: never clobber a running instance's token.
    final token = randomB64Url(32);
    try {
      final f = File(tokenPath ?? defaultTokenPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(token, flush: true);
    } on Object {
      await s.close();
      rethrow;
    }
    s.listen((sock) {
      sock.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final List<String> args;
        try {
          final m = jsonDecode(line) as Map<String, Object?>;
          if (!_sameToken(m['token'], token)) return;
          args = (m['args']! as List<Object?>).cast<String>().toList();
        } on Object {
          return;
        }
        try {
          sock.write('ok\n');
        } on Object {
          // The forwarder hung up early; still act on the (authenticated) args.
        }
        onArgs(args);
      }, onDone: sock.close, onError: (Object _) {});
    }, onError: (Object _) {});
    return SingleInstance._(s);
  }

  static bool _sameToken(Object? got, String want) {
    if (got is! String || got.length != want.length) return false;
    var diff = 0;
    for (var i = 0; i < want.length; i++) {
      diff |= got.codeUnitAt(i) ^ want.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Hands [args] to the running instance. True only once that instance
  /// has acknowledged them (`ok`); false if nobody listens, the token file
  /// is missing, or the token was refused.
  static Future<bool> forward(List<String> args, {int port = defaultPort, String? tokenPath}) async {
    final String token;
    try {
      token = (await File(tokenPath ?? defaultTokenPath()).readAsString()).trim();
    } on Object {
      return false;
    }
    Socket? sock;
    try {
      sock = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
      final reply = sock.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).first;
      sock.write('${jsonEncode({'token': token, 'args': args})}\n');
      await sock.flush();
      final line = await reply.timeout(const Duration(seconds: 2));
      return line.trim() == 'ok';
    } on Object {
      return false;
    } finally {
      try {
        await sock?.close();
      } on Object {
        // Already gone.
      }
      sock?.destroy();
    }
  }

  Future<void> dispose() => _server.close();
}
