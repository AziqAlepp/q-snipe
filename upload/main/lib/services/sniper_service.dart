import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';

import '../core/sniper_engine.dart';
import 'notification_service.dart';
import 'storage.dart';

/// Events sent from the service isolate to the UI via service.invoke():
///   'log'     {line}
///   'snipe'   {profile, label, latency}
///   'stopped' {reason}
Future<void> configureSniperService() async {
  await NotificationService.instance.init(createChannels: true);
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onSniperServiceStart,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: kForegroundChannelId,
      initialNotificationTitle: 'Queue Sniper',
      initialNotificationContent: 'Starting...',
      foregroundServiceNotificationId: kForegroundNotificationId,
      foregroundServiceTypes: [AndroidForegroundType.specialUse],
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

String _stamp() {
  final n = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
}

/// Entry point of the background isolate. Runs one engine per enabled
/// profile; every log line is tagged with the profile label.
@pragma('vm:entry-point')
Future<void> onSniperServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  void log(String line) =>
      service.invoke('log', {'line': '[${_stamp()}] $line'});

  void status(String text) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Queue Sniper',
        content: text,
      );
    }
  }

  final storage = Storage();
  await NotificationService.instance.init();

  final engines = <SniperEngine>[];
  final names = <String>[];
  var snipes = 0;
  var alive = 0;
  var stopping = false;

  Future<void> shutdown(String reason) async {
    if (stopping) return;
    stopping = true;
    for (final e in engines) {
      await e.stop();
    }
    service.invoke('stopped', {'reason': reason});
    await service.stopSelf();
  }

  final profiles = (await storage.loadProfiles()).where((p) => p.enabled);
  for (final p in profiles) {
    final tag = '[${p.label}]';
    final token = await storage.readToken(p.id);
    if (token == null || token.isEmpty) {
      log('$tag no token saved, skipped.');
      continue;
    }
    if (p.config.targets.isEmpty) {
      log('$tag no queue channel configured, skipped.');
      continue;
    }
    final cfg = p.config;
    late final SniperEngine engine;
    engine = SniperEngine(
      token: token,
      config: cfg,
      onLog: (m) => log('$tag $m'),
      onFatal: (m) {
        log('$tag FATAL: $m');
        unawaited(engine.stop());
        alive--;
        if (alive <= 0) unawaited(shutdown('all profiles stopped'));
      },
      onSnipe: (r) {
        snipes++;
        status('Watching: ${names.join(', ')} | Snipes: $snipes');
        service.invoke('snipe', {
          'profile': p.label,
          'label': r.label,
          'latency': r.latencyMs,
        });
        if (cfg.soundEnabled) {
          unawaited(NotificationService.instance.playSnipeSound());
        }
        if (cfg.notifyEnabled) {
          unawaited(NotificationService.instance.showSnipe(
            '${p.label}: queue button clicked',
            '"${r.label}" in ${r.latencyMs} ms',
          ));
        }
      },
    );
    engines.add(engine);
    names.add(p.label);
  }

  service.on('stop').listen((_) {
    unawaited(shutdown('stopped by user'));
  });

  if (engines.isEmpty) {
    log('Nothing to run: enable a profile that has a token and a queue.');
    await shutdown('nothing to run');
    return;
  }

  alive = engines.length;
  status('Connecting: ${names.join(', ')}');
  await Future.wait(engines.map((e) => e.start()));
  if (!stopping) status('Watching: ${names.join(', ')} | Snipes: 0');
}
