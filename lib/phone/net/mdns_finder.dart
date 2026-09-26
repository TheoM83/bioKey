import 'dart:async';
import 'package:bonsoir/bonsoir.dart';

/// Resolves a paired PC's current LAN IP via mDNS/Bonjour when its
/// last-known host stops answering (Wi-Fi roaming, DHCP lease change, …).
/// Looks for a `_biokey._tcp` service whose `id` attribute matches [pcId].
final class MdnsFinder {
  Future<String?> resolveHost(String pcId, {Duration timeout = const Duration(seconds: 4)}) async {
    final d = BonsoirDiscovery(type: '_biokey._tcp');
    StreamSubscription<BonsoirDiscoveryEvent>? sub;
    try {
      await d.initialize();
      final done = Completer<String?>();

      sub = d.eventStream?.listen((BonsoirDiscoveryEvent ev) async {
        switch (ev) {
          case BonsoirDiscoveryServiceFoundEvent(:final service):
            try {
              await service.resolve(d.serviceResolver);
            } on Object {
              // A single service failing to resolve shouldn't take down
              // discovery for every other service on the network.
            }
          case BonsoirDiscoveryServiceResolvedEvent(:final service):
            final host = service.host;
            if (host != null && service.attributes['id'] == pcId && !done.isCompleted) {
              done.complete(host);
            }
          case BonsoirDiscoveryStartedEvent():
          case BonsoirDiscoveryServiceUpdatedEvent():
          case BonsoirDiscoveryServiceResolveFailedEvent():
          case BonsoirDiscoveryServiceLostEvent():
          case BonsoirDiscoveryStoppedEvent():
          case BonsoirDiscoveryUnknownEvent():
            break;
        }
      });

      await d.start();
      return await done.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub?.cancel();
      await d.stop();
    }
  }
}
