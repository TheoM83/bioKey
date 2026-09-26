import 'package:local_notifier/local_notifier.dart';

/// Native desktop notifications, abstracted so the controller can be
/// unit-tested without the local_notifier platform channel.
abstract interface class Notifier {
  Future<void> show(String title, String body);
}

final class LocalNotifier implements Notifier {
  Future<void> setup() => localNotifier.setup(appName: 'BioKey');

  @override
  Future<void> show(String title, String body) => LocalNotification(title: title, body: body).show();
}

final class FakeNotifier implements Notifier {
  final shown = <(String, String)>[];

  @override
  Future<void> show(String title, String body) async => shown.add((title, body));
}
