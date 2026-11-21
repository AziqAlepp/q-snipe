import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

typedef DispatchHandler = void Function(
  String type,
  Map<String, dynamic> data,
  Stopwatch sinceReceived,
);

/// Discord Gateway v10 client (JSON, no compression) for a user token.
/// Handles HELLO, IDENTIFY, heartbeat + zombie detection, RESUME,
/// RECONNECT, INVALID_SESSION and backoff reconnects.
class GatewayClient {
  GatewayClient({
    required this.token,
    required this.onDispatch,
    required this.onLog,
    required this.onFatal,
    this.onReady,
    this.capabilities,
  });

  /// URL taken from the reference APK's string table.
  static const String defaultUrl =
      'wss://gateway.discord.gg/?v=10&encoding=json';

  /// 4004 = authentication failed: retrying can't help.
  static const Set<int> fatalCloseCodes = {4004};

  /// Values sent in IDENTIFY `properties`.
  static const Map<String, String> clientProperties = {
    'os': 'Android',
    'browser': 'Discord Android',
    'device': 'Android',
  };

  final String token;
  final DispatchHandler onDispatch;
  final void Function(String) onLog;
  final void Function(String) onFatal;

  /// Called after a fresh READY (new session), not after RESUMED.
  final void Function()? onReady;

  /// Optional IDENTIFY `capabilities` bitfield. The reference APK sends the
  /// key but its value is UNKNOWN here, so it is omitted unless set.
  final int? capabilities;

  WebSocket? _ws;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  bool _stopped = true;
  bool _connecting = false;
  bool _ackReceived = true;
  int _attempt = 0;
  int? _seq;
  String? _resumeUrl;
  final Random _rng = Random();

  String? sessionId;
  String? username;
  bool _ready = false;

  /// True once READY/RESUMED arrived on the current socket.
  bool get ready => _ready && sessionId != null;

  Future<void> start() async {
    _stopped = false;
    await _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    final ws = _ws;
    _ws = null;
    _ready = false;
    sessionId = null;
    _resumeUrl = null;
    _seq = null;
    try {
      await ws?.close(1000, 'bye');
    } catch (_) {}
    onLog('Gateway shut down.');
  }

  Future<void> _connect() async {
    if (_stopped || _connecting) return;
    _connecting = true;
    final resuming = sessionId != null && _seq != null && _resumeUrl != null;
    final url = resuming ? '$_resumeUrl/?v=10&encoding=json' : defaultUrl;
    onLog('Connecting to Discord Gateway v10...');
    try {
      // No permessage-deflate: nothing to inflate before an event is seen.
      final ws = await WebSocket.connect(
        url,
        compression: CompressionOptions.compressionOff,
      ).timeout(const Duration(seconds: 15));
      if (_stopped) {
        await ws.close(1000);
        return;
      }
      _ws = ws;
      ws.listen(
        (raw) => _onData(ws, raw),
        onDone: () => _onClosed(ws),
        onError: (Object e) {
          onLog('Gateway Socket Error: $e');
          _onClosed(ws);
        },
        cancelOnError: true,
      );
      onLog('Connected to Gateway WebSocket.');
    } catch (e) {
      onLog('Failed to connect to Gateway: $e');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _send(Map<String, dynamic> payload) {
    try {
      _ws?.add(jsonEncode(payload));
    } catch (e) {
      onLog('Gateway send failed: $e');
    }
  }

  Map<String, dynamic>? _decode(String raw) {
    try {
      final j = jsonDecode(raw);
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  void _onData(WebSocket ws, dynamic raw) {
    if (!identical(ws, _ws)) return;
    final sw = Stopwatch()..start();
    if (raw is! String) return; // compression is off, so frames are text
    final msg = _decode(raw);
    if (msg == null) return;

    final op = msg['op'];
    final d = msg['d'];
    switch (op) {
      case 10: // HELLO
        if (d is Map && d['heartbeat_interval'] is int) {
          _startHeartbeat(d['heartbeat_interval'] as int);
        }
        if (sessionId != null && _seq != null) {
          onLog('Resuming session...');
          _send({
            'op': 6,
            'd': {'token': token, 'session_id': sessionId, 'seq': _seq},
          });
        } else {
          _identify();
        }
        break;
      case 11: // HEARTBEAT_ACK
        _ackReceived = true;
        break;
      case 1: // server asks for an immediate heartbeat
        _send({'op': 1, 'd': _seq});
        break;
      case 7: // RECONNECT
        onLog('Discord server requested a reconnect.');
        ws.close(4000, 'reconnect requested');
        break;
      case 9: // INVALID_SESSION
        onLog('Invalid Gateway session. Resetting...');
        final resumable = d == true;
        if (!resumable) {
          sessionId = null;
          _resumeUrl = null;
          _seq = null;
        }
        _ready = false;
        Future.delayed(Duration(milliseconds: 1000 + _rng.nextInt(4000)), () {
          if (_stopped || !identical(ws, _ws)) return;
          if (resumable && sessionId != null && _seq != null) {
            _send({
              'op': 6,
              'd': {'token': token, 'session_id': sessionId, 'seq': _seq},
            });
          } else {
            _identify();
          }
        });
        break;
      case 0: // DISPATCH
        final s = msg['s'];
        if (s is int) _seq = s;
        final t = msg['t'];
        if (t is! String || d is! Map<String, dynamic>) {
          if (t == 'RESUMED') _markReady();
          return;
        }
        if (t == 'READY') {
          sessionId = d['session_id'] as String?;
          final r = d['resume_gateway_url'];
          if (r is String) _resumeUrl = r;
          final user = d['user'];
          if (user is Map) username = user['username']?.toString();
          _markReady();
          onLog('Gateway READY: Logged in as ${username ?? '?'}');
          onReady?.call();
          return;
        }
        onDispatch(t, d, sw);
        break;
    }
  }

  void _markReady() {
    _ready = true;
    _attempt = 0;
  }

  void _identify() {
    final d = <String, dynamic>{
      'token': token,
      'properties': clientProperties,
      'presence': {
        'status': 'online',
        'since': 0,
        'activities': <dynamic>[],
        'afk': false,
      },
      'compress': false,
    };
    if (capabilities != null) d['capabilities'] = capabilities;
    _send({'op': 2, 'd': d});
    onLog('Identify handshake sent.');
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeatTimer?.cancel();
    _ackReceived = true;
    final first = (intervalMs * _rng.nextDouble()).round();
    _heartbeatTimer = Timer(Duration(milliseconds: first), () {
      _beat(intervalMs);
    });
  }

  void _beat(int intervalMs) {
    final ws = _ws;
    if (ws == null || _stopped) return;
    if (!_ackReceived) {
      onLog('Heartbeat ACK not received. Zombie connection detected, '
          'reconnecting...');
      ws.close(4000, 'zombie connection');
      return;
    }
    _ackReceived = false;
    _send({'op': 1, 'd': _seq});
    _heartbeatTimer = Timer(Duration(milliseconds: intervalMs), () {
      _beat(intervalMs);
    });
  }

  void _onClosed(WebSocket ws) {
    if (!identical(ws, _ws)) return; // stale socket or already handled
    _ws = null;
    _ready = false;
    _heartbeatTimer?.cancel();
    final code = ws.closeCode;
    if (_stopped) return;
    if (code != null && fatalCloseCodes.contains(code)) {
      _stopped = true;
      onFatal('Gateway closed with $code: invalid Discord token.');
      return;
    }
    // 4007 invalid seq, 4009 session timed out: session can't be resumed.
    if (code == 4007 || code == 4009) {
      sessionId = null;
      _resumeUrl = null;
      _seq = null;
    }
    onLog('Gateway socket closed (code ${code ?? '-'}). '
        'Scheduling reconnect...');
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _reconnectTimer?.cancel();
    // 0.25 s for the first retry, then 1, 2, 4, 8, 16, 30 s.
    final ms = _attempt == 0 ? 250 : min(30000, 1000 << min(_attempt - 1, 5));
    _attempt++;
    _reconnectTimer = Timer(Duration(milliseconds: ms), _connect);
  }
}
