import 'dart:convert';
import 'dart:io';

final class SingleInstance {
  SingleInstance._(this._server);
  static const port = 47622;
  final ServerSocket _server;

  static Future<SingleInstance?> acquire({required void Function(List<String> args) onArgs}) async {
    final ServerSocket s;
    try {
      s = await ServerSocket.bind(InternetAddress.loopbackIPv4, port, shared: false);
    } on SocketException {
      return null;
    }
    s.listen((sock) {
      sock.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        final List<String> l;
        try {
          l = (jsonDecode(line) as List<Object?>).cast<String>().toList();
        } on Object {
          return;
        }
        onArgs(l);
      }, onDone: sock.close, onError: (Object _) {});
    }, onError: (Object _) {});
    return SingleInstance._(s);
  }

  static Future<bool> forward(List<String> args) async {
    try {
      final sock = await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: const Duration(seconds: 1));
      sock.write('${jsonEncode(args)}\n');
      await sock.flush();
      await sock.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  Future<void> dispose() => _server.close();
}
