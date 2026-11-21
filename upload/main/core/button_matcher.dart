import 'models.dart';

/// Pure helpers (no I/O) so they can be unit-tested without Discord.

const int discordEpochMs = 1420070400000; // 2015-01-01T00:00:00Z

class ButtonMatch {
  const ButtonMatch({required this.customId, required this.label});
  final String customId;
  final String label;
}

/// Discord snowflake built from the current time; used as interaction nonce.
/// Dart VM ints are 64-bit, so the shift cannot overflow on Android.
String generateNonce({int? nowMs}) {
  final ms = nowMs ?? DateTime.now().millisecondsSinceEpoch;
  return ((ms - discordEpochMs) << 22).toString();
}

/// Walks the component tree. Handles classic action rows (type 1 ->
/// components) and nested layouts (containers/sections with `components`
/// or `accessory`), collecting every button (type 2).
void _collectButtons(dynamic node, List<Map<String, dynamic>> out) {
  if (node is List) {
    for (final e in node) {
      _collectButtons(e, out);
    }
  } else if (node is Map) {
    if (node['type'] == 2) {
      out.add(Map<String, dynamic>.from(node));
    }
    _collectButtons(node['components'], out);
    _collectButtons(node['accessory'], out);
  }
}

/// Human-readable list of every button in a message, for the log:
/// `"Join" id=q_join`, with (disabled)/(link) flags.
List<String> describeButtons(dynamic components) {
  final buttons = <Map<String, dynamic>>[];
  _collectButtons(components, buttons);
  return buttons.map((b) {
    final flags = [
      if (b['disabled'] == true) 'disabled',
      if (b['style'] == 5) 'link',
    ];
    final label = (b['label'] ?? '').toString();
    final id = (b['custom_id'] ?? '-').toString();
    return '"$label" id=$id${flags.isEmpty ? '' : ' (${flags.join(', ')})'}';
  }).toList();
}

const List<String> _negativeWords = ['leave', 'cancel', 'exit', 'quit'];

/// Lower-cases and turns everything that is not a letter or digit (emoji,
/// punctuation, underscores, extra spaces) into single spaces.
String normalizeText(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

int _editDistance(String a, String b) {
  if (a == b) return 0;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final best = prev[j - 1] + cost;
      final del = prev[j] + 1;
      final ins = cur[j - 1] + 1;
      cur[j] = best < del ? (best < ins ? best : ins) : (del < ins ? del : ins);
    }
    prev = cur;
  }
  return prev[b.length];
}

/// A keyword word matches when the normalised text contains it, or (for words
/// of 5+ letters) when one word of the text is at most one typo away.
bool _wordMatches(String word, String hay, List<String> hayTokens) {
  if (hay.contains(word)) return true;
  if (word.length < 5) return false;
  return hayTokens.any(
    (t) => (t.length - word.length).abs() <= 1 && _editDistance(t, word) <= 1,
  );
}

/// How many distinct keyword words appear in [hay] (already normalised).
int keywordScore(List<String> keywords, String hay) {
  final tokens = hay.split(' ').where((t) => t.isNotEmpty).toList();
  final words = <String>{};
  for (final k in keywords) {
    for (final w in normalizeText(k).split(' ')) {
      if (w.length >= 2) words.add(w);
    }
  }
  var score = 0;
  for (final w in words) {
    if (_wordMatches(w, hay, tokens)) score++;
  }
  return score;
}

/// Returns the button to click, or null.
/// - Link buttons (style 5) and disabled buttons are never clickable.
/// - If [target.customButtonId] is set: an exact custom_id wins; otherwise a
///   button whose custom_id merely contains it (ignoring case/punctuation).
/// - Otherwise keywords are matched loosely, word by word: "join queue"
///   matches "Join", "JOIN QUEUE", "Queue Now", "Join the queue!" and even
///   a one-letter typo. The button matching the most keyword words wins (ties:
///   the first one). Labels with leave/cancel/exit/quit are never picked.
///   With no keywords, the first clickable button is used.
ButtonMatch? findButton(dynamic components, QueueTarget target) {
  final buttons = <Map<String, dynamic>>[];
  _collectButtons(components, buttons);

  final wanted = target.customButtonId.trim();
  final wantedNorm = normalizeText(wanted);
  final keywords = target.keywords
      .map((k) => k.trim())
      .where((k) => normalizeText(k).isNotEmpty)
      .toList();

  ButtonMatch? best;
  var bestScore = 0;
  ButtonMatch? partialId;

  for (final b in buttons) {
    if (b['style'] == 5 || b['disabled'] == true) continue;
    final id = b['custom_id'];
    if (id is! String || id.isEmpty) continue;
    final label = (b['label'] ?? '').toString();
    final match = ButtonMatch(customId: id, label: label);

    if (wanted.isNotEmpty) {
      if (id == wanted) return match;
      if (partialId == null &&
          wantedNorm.isNotEmpty &&
          normalizeText(id).contains(wantedNorm)) {
        partialId = match;
      }
      continue;
    }

    final hay = normalizeText('$label $id');
    // Keyword mode must never press "Leave queue" and friends.
    final tokens = hay.split(' ');
    if (_negativeWords.any((n) => tokens.any((t) => t.startsWith(n)))) {
      continue;
    }
    if (keywords.isEmpty) return match;
    final score = keywordScore(keywords, hay);
    if (score > bestScore) {
      best = match;
      bestScore = score;
    }
  }
  return wanted.isNotEmpty ? partialId : best;
}

/// Body for POST /api/v10/interactions (component click).
/// Field set taken from the string table of the reference APK plus the
/// public behaviour of Discord clients; not yet verified against live traffic.
Map<String, dynamic> buildInteractionBody({
  required String guildId,
  required String channelId,
  required String messageId,
  required int messageFlags,
  required String applicationId,
  required String sessionId,
  required String customId,
  String? nonce,
}) =>
    {
      'type': 3,
      'nonce': nonce ?? generateNonce(),
      'guild_id': guildId,
      'channel_id': channelId,
      'message_flags': messageFlags,
      'message_id': messageId,
      'application_id': applicationId,
      'session_id': sessionId,
      'data': {
        'component_type': 2,
        'custom_id': customId,
      },
    };
