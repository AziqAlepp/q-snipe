import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const String kForegroundChannelId = 'qs_foreground';
const String kAlertChannelId = 'qs_alerts';
const int kForegroundNotificationId = 8811;
const int _kAlertNotificationId = 8812;

/// Notifications + sound, usable from both the UI and the service isolate.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  AudioPlayer? _player;
  bool _inited = false;

  Future<void> init({bool createChannels = false}) async {
    if (!_inited) {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      await _plugin.initialize(const InitializationSettings(android: android));
      _inited = true;
    }
    if (createChannels) {
      final impl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await impl?.createNotificationChannel(const AndroidNotificationChannel(
        kForegroundChannelId,
        'Sniper status',
        description: 'Keeps the sniper alive in the background',
        importance: Importance.low,
      ));
      await impl?.createNotificationChannel(const AndroidNotificationChannel(
        kAlertChannelId,
        'Snipe alerts',
        description: 'Pop-up when a queue button was clicked',
        importance: Importance.max,
        enableVibration: true,
      ));
    }
  }

  Future<bool> requestPermission() async {
    final impl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await impl?.requestNotificationsPermission() ?? false;
  }

  Future<void> showSnipe(String title, String body) async {
    await _plugin.show(
      _kAlertNotificationId,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          kAlertChannelId,
          'Snipe alerts',
          channelDescription: 'Pop-up when a queue button was clicked',
          importance: Importance.max,
          priority: Priority.high,
          playSound: false, // the bundled sound is played by playSnipeSound
          enableVibration: true,
        ),
      ),
    );
  }

  Future<void> playSnipeSound() async {
    try {
      _player ??= AudioPlayer();
      await _player!.play(AssetSource('sounds/snipe.wav'));
    } catch (_) {
      // Sound is best-effort and must never break the sniper loop.
    }
  }
}
