import 'package:biokey/phone/service/foreground.dart';

/// Records every notification shown/cancelled instead of touching the
/// real `flutter_local_notifications` platform channel.
class FakeAuthNotifier implements AuthNotifierApi {
  int initCalls = 0;
  final shown = <({int id, String label, String pcName})>[];
  final cancelled = <int>[];

  @override
  Future<void> init() async {
    initCalls++;
  }

  @override
  Future<void> showAuthPrompt({required int id, required String label, required String pcName}) async {
    shown.add((id: id, label: label, pcName: pcName));
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }
}
