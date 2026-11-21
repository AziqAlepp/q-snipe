import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'button_matcher.dart';
import 'discord_rest.dart';
import 'gateway_client.dart';
import 'models.dart';

class SnipeResult {
  const SnipeResult({
    required this.label,
    required this.latencyMs,
    required this.guildId,
    required this.channelId,
  });
  final String label;
  final int latencyMs;
  final String guildId;
  final String channelId;
}

/// Ties Gateway + REST together: when a MESSAGE_CREATE/MESSAGE_UPDATE in a
/// configured guild/channel carries a matching button, it is clicked at once
/// (once, or spammed, depending on the profile settings).
///
/// Besides live gateway events, the latest messages of each watched channel
/// are read over REST on start, after a new session, and (optionally) every
/// few seconds, so a queue that was already open is not missed.
class SniperEngine {
  SniperEngine({
    required this.token,
    required this.config,
    required this.onLog,
    required this.onSnipe,
    required this.onFatal,
  });

  static const int maxAttemptsPerButton = 3;
  static const int maxTrackedKeys = 500;

  final String token;
  final SniperConfig config;
  final void Function(String) onLog;
  final void Function(SnipeResult) onSnipe;
  final void Function(String) onFatal;

  late final DiscordRest _rest = DiscordRest(token);
  GatewayClient? _gateway;
  bool _running = false;
  bool _scanning = false;
  Timer? _pollTimer;

  /// "messageId:customId" -> snipe rounds so far; a value >= maxAttemptsPerButton
  /// also marks a click that already succeeded. Insertion-ordered and bounded.
  final LinkedHashMap<String, int> _attempts = LinkedHashMap();
  final Set<String> _inFlight = {};
  final LinkedHashSet<String> _reported = LinkedHashSet();

  bool get running => _running;

  Future<void> start() async {
    if (_running) return;
    if (config.targets.isEmpty) {
      onFatal('No queue configured.');
      return;
    }
    _running = true;
    try {
      final name = await _rest.validateToken();
      onLog('Token OK, account: $name');
    } on StateError catch (e) {
      _running = false;
      onFatal(e.message);
      return;
    } catch (e) {
      // Network hiccup: keep going, the gateway has its own reconnect loop.
      onLog('Token check skipped: $e');
    }
    // Sockets ready before the first click is needed.
    final conns = config.spamEnabled
        ? (config.spamCount < 8 ? config.spamCount : 8)
        : 1;
    unawaited(() async {
      final rtts = await _rest.warm(conns);
      if (rtts.isEmpty) {
        onLog('Connection warm-up failed (offline?), will retry.');
      } else {
        onLog('Warmed ${rtts.length} connection(s), REST round trip '
            '${rtts.reduce((a, b) => a < b ? a : b)} ms.');
      }
    }());
    _rest.keepWarm(conns, (r) {
      if (config.verbose && r.isNotEmpty) {
        onLog('[debug] keep-warm: ${r.length} connection(s), '
            '${r.reduce((a, b) => a < b ? a : b)} ms');
      }
    });
    final gw = GatewayClient(
      token: token,
      onDispatch: _onDispatch,
      onLog: onLog,
      onReady: () {
        if (config.scanOnStart) unawaited(_scan('ready'));
      },
      onFatal: (m) {
        _running = false;
        onFatal(m);
      },
    );
    _gateway = gw;
    await gw.start();
    if (config.pollSeconds > 0) {
      _pollTimer = Timer.periodic(
        Duration(seconds: config.pollSeconds),
        (_) => unawaited(_scan('poll')),
      );
    }
    onLog('Watching ${config.targets.length} queue channel(s)'
        '${config.spamEnabled ? ', spam x${config.spamCount} every ${config.spamIntervalMs} ms' : ''}'
        '${config.scanOnStart ? ', scan on start' : ''}'
        '${config.pollSeconds > 0 ? ', poll every ${config.pollSeconds}s' : ''}'
        '${config.verbose ? ', debug log ON' : ''}.');
  }

  Future<void> stop() async {
    _running = false;
    _pollTimer?.cancel();
    await _gateway?.stop();
    _gateway = null;
    _rest.close();
  }

  QueueTarget? _targetFor(String guildId, String channelId) {
    for (final t in config.targets) {
      if (t.guildId == guildId && t.channelId == channelId) return t;
    }
    return null;
  }

  /// True the first time [key] is seen (bounded memory).
  bool _firstTime(String key) {
    if (!_reported.add(key)) return false;
    while (_reported.length > maxTrackedKeys) {
      _reported.remove(_reported.first);
    }
    return true;
  }

  void _onDispatch(String type, Map<String, dynamic> d, Stopwatch sw) {
    if (!_running) return;
    if (type != 'MESSAGE_CREATE' && type != 'MESSAGE_UPDATE') return;
    final guildId = d['guild_id'];
    if (guildId is! String) {
      if (config.verbose) onLog('[debug] $type ignored: no guild id (DM?)');
      return;
    }
    _handleMessage(type, guildId, d, sw);
  }

  /// Reads the latest messages of every watched channel and treats each one
  /// like a fresh event. Already-clicked buttons are skipped by the dedupe map.
  Future<void> _scan(String reason) async {
    if (_scanning || !_running) return;
    _scanning = true;
    try {
      for (final t in config.targets) {
        if (!_running) return;
        try {
          final r = await _rest.getChannelMessages(t.channelId, limit: 10);
          final sw = Stopwatch()..start();
          if (r.status == 401) {
            _running = false;
            onFatal('Invalid Discord token or unauthorized (401).');
            return;
          }
          if (!r.ok) {
            onLog('Scan of channel ${t.channelId} failed: HTTP ${r.status} '
                '${_short(r.body)}');
            continue;
          }
          final list = jsonDecode(r.body);
          if (list is! List) continue;
          var withComponents = 0;
          for (final m in list.whereType<Map<String, dynamic>>()) {
            final c = m['components'];
            if (c is List && c.isNotEmpty) withComponents++;
            // Newest first: only the newest message with a matching button
            // is acted on, older queue messages are left alone.
            if (_handleMessage('SCAN', t.guildId, m, sw)) break;
          }
          if (config.verbose || reason == 'ready') {
            onLog('Scan ($reason) channel ${t.channelId}: ${list.length} '
                'message(s), $withComponents with buttons.');
          }
        } catch (e) {
          onLog('Scan error: $e');
        }
      }
    } finally {
      _scanning = false;
    }
  }

  /// Shared by gateway events and the REST scan. Returns true when the
  /// message carries a button that matches (whether or not it was clicked now).
  bool _handleMessage(
    String type,
    String guildId,
    Map<String, dynamic> d,
    Stopwatch sw,
  ) {
    final channelId = d['channel_id'];
    final messageId = d['id'];
    if (channelId is! String || messageId is! String) return false;

    final target = _targetFor(guildId, channelId);
    final components = d['components'];

    // Unwatched traffic returns here without any further work.
    if (target == null) {
      if (config.verbose) {
        final author = d['author'];
        final who = author is Map ? author['username'] : '?';
        onLog('[debug] $type guild=$guildId channel=$channelId from=$who '
            'buttons=${describeButtons(components).length} (not watched)');
      }
      return false;
    }
    if (config.verbose) {
      onLog('[debug] $type guild=$guildId channel=$channelId '
          'buttons=${describeButtons(components).length}');
    }

    // Partial MESSAGE_UPDATEs (embed unfurls etc.) have no components.
    if (components is! List || components.isEmpty) return false;

    final match = findButton(components, target);
    if (match == null) {
      if (_firstTime('$messageId:nomatch')) {
        final buttons = describeButtons(components);
        final wanted = target.customButtonId.isNotEmpty
            ? 'button id "${target.customButtonId}"'
            : 'keywords [${target.keywords.join(', ')}]';
        onLog('Message $messageId in the watched channel has '
            '${buttons.length} button(s) but none matches $wanted: '
            '${buttons.isEmpty ? 'only non-button components' : buttons.join('; ')}');
      }
      return false;
    }

    final key = '$messageId:${match.customId}';
    if (_inFlight.contains(key)) return true;
    final tries = _attempts[key] ?? 0;
    if (tries >= maxAttemptsPerButton) return true;

    final flags = d['flags'];
    final author = d['author'];
    final appId = (d['application_id'] ??
            (author is Map ? author['id'] : null))
        ?.toString();
    final sessionId = _gateway?.sessionId;
    if (appId == null || appId.isEmpty) {
      onLog('Button "${match.label}" found but message has no '
          'application id, skipped.');
      return true;
    }
    if (sessionId == null) {
      onLog('Button "${match.label}" found but gateway session is not '
          'ready, skipped.');
      return true;
    }

    _attempts[key] = tries + 1;
    while (_attempts.length > maxTrackedKeys) {
      _attempts.remove(_attempts.keys.first);
    }
    _inFlight.add(key);
    onLog('Button detected: "${match.label}" ($type). Executing snip...');

    unawaited(_snipe(
      key: key,
      target: target,
      match: match,
      sw: sw,
      newBody: () => buildInteractionBody(
        guildId: guildId,
        channelId: channelId,
        messageId: messageId,
        messageFlags: flags is int ? flags : 0,
        applicationId: appId,
        sessionId: sessionId,
        customId: match.customId,
      ),
    ));
    return true;
  }

  /// One snipe round: a single click, or in spam mode up to `spamCount`
  /// clicks (all at once when the interval is 0, otherwise staggered), which
  /// stop as soon as one succeeds. In spam mode the same button may be
  /// clicked several times before the first answer arrives.
  Future<void> _snipe({
    required String key,
    required QueueTarget target,
    required ButtonMatch match,
    required Stopwatch sw,
    required Map<String, dynamic> Function() newBody,
  }) async {
    final total = config.spamEnabled ? config.spamCount : 1;
    final gap = config.spamEnabled ? config.spamIntervalMs : 0;
    var success = false;
    var fatal = false;
    var sent = 0;
    var lastFail = '';

    Future<void> one() async {
      if (success || fatal || !_running) return;
      sent++;
      try {
        final r = await _rest.postInteraction(newBody());
        if (success) return; // an earlier click already won
        if (r.ok) {
          success = true;
          final ms = sw.elapsedMilliseconds;
          _attempts[key] = maxAttemptsPerButton; // done, never click again
          onLog('Successfully sniped queue button "${match.label}" '
              '(Latency: ${ms}ms, click $sent of $total)');
          onSnipe(SnipeResult(
            label: match.label,
            latencyMs: ms,
            guildId: target.guildId,
            channelId: target.channelId,
          ));
          unawaited(_relay(match.label, ms));
        } else if (r.status == 401) {
          fatal = true;
          onLog('Interaction rejected: 401, token is no longer valid.');
          _running = false;
          onFatal('Invalid Discord token or unauthorized (401).');
        } else {
          lastFail = 'HTTP ${r.status} ${_short(r.body)}';
          if (r.status == 429) {
            await Future<void>.delayed(
              Duration(milliseconds: retryAfterMs(r.body)),
            );
          }
        }
      } catch (e) {
        lastFail = 'error $e';
      }
    }

    try {
      if (gap == 0) {
        await Future.wait([for (var i = 0; i < total; i++) one()]);
      } else {
        final pending = <Future<void>>[];
        for (var i = 0; i < total; i++) {
          if (success || fatal || !_running) break;
          pending.add(one());
          if (i < total - 1) {
            await Future<void>.delayed(Duration(milliseconds: gap));
          }
        }
        await Future.wait(pending);
      }
      if (!success && !fatal) {
        onLog('Button interaction failed after $sent attempt(s) (possibly '
            'rate limited or queue full): $lastFail');
      }
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<void> _relay(String label, int ms) async {
    final url = config.webhookUrl.trim();
    if (url.isEmpty) return;
    if (!isValidWebhookUrl(url)) {
      onLog('Webhook URL ignored: not a Discord webhook URL.');
      return;
    }
    try {
      final r = await _rest.postWebhook(url, {
        'content': 'Successfully sniped queue button **"$label"** '
            '(Latency: ${ms}ms)',
      });
      if (!r.ok) onLog('Webhook relay failed: HTTP ${r.status}');
    } catch (e) {
      onLog('Webhook relay error: $e');
    }
  }

  String _short(String s) => s.length <= 160 ? s : '${s.substring(0, 160)}...';
}
