import 'dart:convert';

/// Discord ids are 64-bit snowflakes, 15-21 decimal digits in practice.
bool isSnowflake(String s) => RegExp(r'^\d{15,21}$').hasMatch(s);

/// Cleans a token as pasted by the user or returned by the WebView script:
/// strips (possibly nested/escaped) JSON quotes and rejects anything that
/// can't be a token. Returns null when invalid.
String? normalizeCapturedToken(String? raw) {
  var t = (raw ?? '').trim();
  for (var i = 0; i < 3; i++) {
    if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
      try {
        final d = jsonDecode(t);
        if (d is String) {
          t = d.trim();
          continue;
        }
      } catch (_) {}
      t = t.substring(1, t.length - 1);
    } else {
      break;
    }
  }
  if (t == 'null' || t.length < 20 || RegExp(r'\s').hasMatch(t)) return null;
  return t;
}

/// Only real Discord webhook URLs are accepted, so a typo can't send
/// snipe reports to an arbitrary host.
bool isValidWebhookUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme != 'https') return false;
  const hosts = {
    'discord.com',
    'ptb.discord.com',
    'canary.discord.com',
    'discordapp.com',
  };
  return hosts.contains(uri.host) && uri.path.startsWith('/api/webhooks/');
}

class QueueTarget {
  const QueueTarget({
    required this.guildId,
    required this.channelId,
    this.customButtonId = '',
    this.keywords = defaultKeywords,
  });

  /// Used when no custom button id is set. Design choice of this project,
  /// editable per queue. An empty list means "first clickable button".
  static const List<String> defaultKeywords = ['join', 'queue'];

  final String guildId;
  final String channelId;

  /// Exact `custom_id` of the button to click. Empty string = not set.
  final String customButtonId;
  final List<String> keywords;

  Map<String, dynamic> toJson() => {
        'guildId': guildId,
        'channelId': channelId,
        'customButtonId': customButtonId,
        'keywords': keywords,
      };

  factory QueueTarget.fromJson(Map<String, dynamic> json) {
    final kw = json['keywords'];
    return QueueTarget(
      guildId: (json['guildId'] ?? '').toString(),
      channelId: (json['channelId'] ?? '').toString(),
      customButtonId: (json['customButtonId'] ?? '').toString(),
      keywords: kw is List
          ? kw.map((e) => e.toString()).toList()
          : defaultKeywords,
    );
  }
}

int _clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// Per-profile settings.
class SniperConfig {
  const SniperConfig({
    this.targets = const [],
    this.webhookUrl = '',
    this.soundEnabled = true,
    this.notifyEnabled = true,
    this.spamEnabled = false,
    this.spamCount = 10,
    this.spamIntervalMs = 0,
    this.verbose = false,
    this.scanOnStart = true,
    this.pollSeconds = 0,
  });

  static const int maxPollSeconds = 60;
  static const int maxSpamCount = 100;
  static const int maxSpamIntervalMs = 5000;

  final List<QueueTarget> targets;
  final String webhookUrl;
  final bool soundEnabled;
  final bool notifyEnabled;

  /// Spam mode: on detection, send up to [spamCount] click requests,
  /// started [spamIntervalMs] apart (0 = all at once, as fast as possible),
  /// stopping as soon as one succeeds.
  final bool spamEnabled;
  final int spamCount;
  final int spamIntervalMs;

  /// Debug log: every message the gateway delivers is logged.
  final bool verbose;

  /// Read the latest messages of each watched channel on start and after a
  /// new gateway session, so a queue that is already open is joined at once.
  final bool scanOnStart;

  /// Extra safety net: re-read the watched channels every N seconds
  /// (0 = off). Costs one REST call per channel per tick.
  final int pollSeconds;

  SniperConfig copyWith({
    List<QueueTarget>? targets,
    String? webhookUrl,
    bool? soundEnabled,
    bool? notifyEnabled,
    bool? spamEnabled,
    int? spamCount,
    int? spamIntervalMs,
    bool? verbose,
    bool? scanOnStart,
    int? pollSeconds,
  }) =>
      SniperConfig(
        targets: targets ?? this.targets,
        webhookUrl: webhookUrl ?? this.webhookUrl,
        soundEnabled: soundEnabled ?? this.soundEnabled,
        notifyEnabled: notifyEnabled ?? this.notifyEnabled,
        spamEnabled: spamEnabled ?? this.spamEnabled,
        spamCount: _clampInt(spamCount ?? this.spamCount, 1, maxSpamCount),
        spamIntervalMs: _clampInt(
          spamIntervalMs ?? this.spamIntervalMs,
          0,
          maxSpamIntervalMs,
        ),
        verbose: verbose ?? this.verbose,
        scanOnStart: scanOnStart ?? this.scanOnStart,
        pollSeconds: _clampInt(
          pollSeconds ?? this.pollSeconds,
          0,
          maxPollSeconds,
        ),
      );

  Map<String, dynamic> toJson() => {
        'targets': targets.map((t) => t.toJson()).toList(),
        'webhookUrl': webhookUrl,
        'soundEnabled': soundEnabled,
        'notifyEnabled': notifyEnabled,
        'spamEnabled': spamEnabled,
        'spamCount': spamCount,
        'spamIntervalMs': spamIntervalMs,
        'verbose': verbose,
        'scanOnStart': scanOnStart,
        'pollSeconds': pollSeconds,
      };

  String encode() => jsonEncode(toJson());

  static SniperConfig fromJson(Map<String, dynamic> j) {
    final t = j['targets'];
    int intOf(String key, int fallback) {
      final v = j[key];
      return v is int ? v : fallback;
    }

    return const SniperConfig().copyWith(
      targets: t is List
          ? t
              .whereType<Map<String, dynamic>>()
              .map(QueueTarget.fromJson)
              .toList()
          : const [],
      webhookUrl: (j['webhookUrl'] ?? '').toString(),
      soundEnabled: j['soundEnabled'] != false,
      notifyEnabled: j['notifyEnabled'] != false,
      spamEnabled: j['spamEnabled'] == true,
      spamCount: intOf('spamCount', 10),
      spamIntervalMs: intOf('spamIntervalMs', 0),
      verbose: j['verbose'] == true,
      scanOnStart: j['scanOnStart'] != false,
      pollSeconds: intOf('pollSeconds', 0),
    );
  }

  static SniperConfig decode(String? raw) {
    if (raw == null || raw.isEmpty) return const SniperConfig();
    try {
      final j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return const SniperConfig();
      return fromJson(j);
    } catch (_) {
      return const SniperConfig();
    }
  }
}

/// One Discord account with its own token and settings. The token itself is
/// kept in secure storage under [tokenKey]; it is never part of this object.
class Profile {
  const Profile({
    required this.id,
    required this.label,
    this.username = '',
    this.enabled = true,
    this.config = const SniperConfig(),
  });

  final String id;

  /// Name the user gave the profile; shown in the log and notifications.
  final String label;

  /// Discord account name, read when the token was saved ('' = unknown).
  final String username;

  /// Included when the engine is started.
  final bool enabled;
  final SniperConfig config;

  String get tokenKey => 'token_$id';

  String get display => username.isEmpty ? label : '$label (@$username)';

  Profile copyWith({
    String? label,
    String? username,
    bool? enabled,
    SniperConfig? config,
  }) =>
      Profile(
        id: id,
        label: label ?? this.label,
        username: username ?? this.username,
        enabled: enabled ?? this.enabled,
        config: config ?? this.config,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'username': username,
        'enabled': enabled,
        'config': config.toJson(),
      };

  static Profile? fromJson(Map<String, dynamic> j) {
    final id = j['id'];
    if (id is! String || id.isEmpty) return null;
    final c = j['config'];
    return Profile(
      id: id,
      label: (j['label'] ?? 'Profile').toString(),
      username: (j['username'] ?? '').toString(),
      enabled: j['enabled'] != false,
      config: c is Map<String, dynamic> ? SniperConfig.fromJson(c) : const SniperConfig(),
    );
  }
}

String encodeProfiles(List<Profile> list) =>
    jsonEncode(list.map((p) => p.toJson()).toList());

List<Profile> decodeProfiles(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  try {
    final j = jsonDecode(raw);
    if (j is! List) return const [];
    return j
        .whereType<Map<String, dynamic>>()
        .map(Profile.fromJson)
        .whereType<Profile>()
        .toList();
  } catch (_) {
    return const [];
  }
}
