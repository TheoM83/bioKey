import 'package:uuid/uuid.dart';

final class ProtectedApp {
  const ProtectedApp({required this.id, required this.label, required this.target, this.unlockMinutes = 0});
  factory ProtectedApp.create({required String label, required String target, int unlockMinutes = 0}) =>
      ProtectedApp(id: const Uuid().v4(), label: label, target: target, unlockMinutes: unlockMinutes);
  final String id, label, target;
  final int unlockMinutes;

  ProtectedApp copyWith({String? label, String? target, int? unlockMinutes}) =>
      ProtectedApp(id: id, label: label ?? this.label, target: target ?? this.target, unlockMinutes: unlockMinutes ?? this.unlockMinutes);

  Map<String, Object?> toJson() => {'id': id, 'label': label, 'target': target, 'unlockMinutes': unlockMinutes};
  static ProtectedApp fromJson(Map<String, Object?> j) => ProtectedApp(
      id: j['id']! as String, label: j['label']! as String, target: j['target']! as String, unlockMinutes: (j['unlockMinutes'] as int?) ?? 0);
}
