import 'package:biokey/phone/service/proxy_signer.dart';

/// Records every notification shown/cancelled instead of touching the
/// real `flutter_local_notifications` platform channel.
class FakeAuthNotifier implements AuthNotifierApi {
  int initCalls = 0;
  final shown = <({int id, String body})>[];
  final cancelled = <int>[];

  @override
  Future<void> init() async {
    initCalls++;
  }

  @override
  Future<void> show({required int id, required String body}) async {
    shown.add((id: id, body: body));
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }
}
