import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Milliseconds to wait after an HTTP 429. Reads `retry_after` (seconds,
/// may be fractional) from the body; default 500 ms, capped at 2000 ms so a
/// snipe never stalls for long.
int retryAfterMs(String body) {
  try {
    final j = jsonDecode(body);
    if (j is Map && j['retry_after'] is num) {
      final ms = ((j['retry_after'] as num) * 1000).round();
      return ms < 0 ? 0 : (ms > 2000 ? 2000 : ms);
    }
  } catch (_) {}
  return 500;
}

class RestResult {
  const RestResult(this.status, this.body);
  final int status;
  final String body;
  bool get ok => status >= 200 && status < 300;
}

/// Minimal REST client on dart:io. One HttpClient is kept alive so the TLS
/// connection to discord.com is reused (warmed by [validateToken]).
class DiscordRest {
  DiscordRest(this._token) {
    _http
      ..userAgent = userAgent
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 90);
  }

  /// String taken from the reference APK's string table.
  static const String userAgent =
      'Discord-Android/219014; Mozilla/5.0 (Linux; Android 15; Mobile)';
  static const String apiBase = 'https://discord.com/api/v10';

  final String _token;
  final HttpClient _http = HttpClient();

  Future<RestResult> _send(
    String method,
    Uri uri, {
    Object? json,
    bool auth = true,
  }) async {
    final req = await _http.openUrl(method, uri);
    if (auth) req.headers.set(HttpHeaders.authorizationHeader, _token);
    if (json != null) {
      final bytes = utf8.encode(jsonEncode(json));
      req.headers.contentType = ContentType.json;
      // A fixed length avoids chunked transfer encoding (one less round of
      // framing before Discord can act on the click).
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close().timeout(const Duration(seconds: 10));
    final text = await utf8.decodeStream(res);
    return RestResult(res.statusCode, text);
  }

  /// GET /users/@me. Returns the username, or throws [StateError] on 401.
  Future<String> validateToken() async {
    final r = await _send('GET', Uri.parse('$apiBase/users/@me'));
    if (r.status == 401) {
      throw StateError('Invalid Discord token or unauthorized (401).');
    }
    if (!r.ok) throw StateError('users/@me returned HTTP ${r.status}');
    final j = jsonDecode(r.body);
    if (j is Map && j['username'] is String) return j['username'] as String;
    return '?';
  }

  /// Latest messages of a channel, newest first (needs read access).
  Future<RestResult> getChannelMessages(String channelId, {int limit = 10}) =>
      _send('GET', Uri.parse('$apiBase/channels/$channelId/messages?limit=$limit'));

  static final Uri _interactionsUri = Uri.parse('$apiBase/interactions');

  Future<RestResult> postInteraction(Map<String, dynamic> body) =>
      _send('POST', _interactionsUri, json: body);

  /// Opens [connections] TLS connections to discord.com in parallel with a
  /// cheap public request, so the pool holds ready sockets when a click has
  /// to go out. Returns the round-trip time in ms of each request that worked.
  Future<List<int>> warm(int connections) async {
    final n = connections < 1 ? 1 : (connections > 8 ? 8 : connections);
    final times = await Future.wait([
      for (var i = 0; i < n; i++) _warmOne(),
    ]);
    return times.whereType<int>().toList();
  }

  Future<int?> _warmOne() async {
    final sw = Stopwatch()..start();
    try {
      final req = await _http.getUrl(Uri.parse('$apiBase/gateway'));
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  Timer? _warmTimer;

  /// Repeats [warm] so idle sockets are not dropped between queue openings.
  void keepWarm(int connections, void Function(List<int>) onResult) {
    _warmTimer?.cancel();
    _warmTimer = Timer.periodic(const Duration(seconds: 25), (_) async {
      onResult(await warm(connections));
    });
  }

  /// Webhook calls carry no Authorization header.
  Future<RestResult> postWebhook(String url, Map<String, dynamic> body) =>
      _send('POST', Uri.parse(url), json: body, auth: false);

  void close() {
    _warmTimer?.cancel();
    _http.close(force: true);
  }
}
