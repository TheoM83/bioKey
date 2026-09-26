final class QrPayload {
  const QrPayload({required this.pcId, required this.name, required this.host, required this.port, required this.fingerprint, required this.token});
  final String pcId, name, host;
  final int port;
  final String fingerprint, token;

  Uri toUri() => Uri(scheme: 'biokey', host: 'pair', queryParameters: {
        'v': '1', 'id': pcId, 'n': name, 'h': host, 'p': '$port', 'fp': fingerprint, 't': token,
      });

  static QrPayload parse(String text) {
    final u = Uri.tryParse(text);
    if (u == null || u.scheme != 'biokey' || u.host != 'pair') throw const FormatException('pas un QR BioKey');
    final q = u.queryParameters;
    if (q['v'] != '1') throw const FormatException('version de QR non prise en charge');
    String need(String k) => q[k] ?? (throw FormatException('champ $k manquant'));
    final port = int.tryParse(need('p'));
    if (port == null || port < 1 || port > 65535) throw const FormatException('port invalide');
    return QrPayload(pcId: need('id'), name: need('n'), host: need('h'), port: port, fingerprint: need('fp'), token: need('t'));
  }

  @override
  bool operator ==(Object other) => other is QrPayload && other.pcId == pcId && other.name == name && other.host == host && other.port == port && other.fingerprint == fingerprint && other.token == token;
  @override
  int get hashCode => Object.hash(pcId, name, host, port, fingerprint, token);
}
