import 'dart:convert';

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

/// Start of each 26-letter run in the Mathematical Alphanumeric Symbols
/// block (U+1D400-1D7FF), paired with the ascii case it folds to (0x41='A',
/// 0x61='a'). Covers bold, italic, bold italic, script, bold script,
/// fraktur, double-struck, bold fraktur, sans-serif (+bold/italic/bold
/// italic) and monospace - every style Discord "fancy text" generators
/// commonly produce for button labels.
const List<List<int>> _mathLetterRuns = [
  [0x1D400, 0x41], [0x1D41A, 0x61], // bold
  [0x1D434, 0x41], [0x1D44E, 0x61], // italic
  [0x1D468, 0x41], [0x1D482, 0x61], // bold italic
  [0x1D49C, 0x41], [0x1D4B6, 0x61], // script
  [0x1D4D0, 0x41], [0x1D4EA, 0x61], // bold script
  [0x1D504, 0x41], [0x1D51E, 0x61], // fraktur
  [0x1D538, 0x41], [0x1D552, 0x61], // double-struck
  [0x1D56C, 0x41], [0x1D586, 0x61], // bold fraktur
  [0x1D5A0, 0x41], [0x1D5BA, 0x61], // sans-serif
  [0x1D5D4, 0x41], [0x1D5EE, 0x61], // sans-serif bold
  [0x1D608, 0x41], [0x1D622, 0x61], // sans-serif italic
  [0x1D63C, 0x41], [0x1D656, 0x61], // sans-serif bold italic
  [0x1D670, 0x41], [0x1D68A, 0x61], // monospace
];

/// Start of each 10-digit run (bold, double-struck, sans-serif, sans-serif
/// bold, monospace); '0' is the first of each run.
const List<int> _mathDigitStarts = [0x1D7CE, 0x1D7D8, 0x1D7E2, 0x1D7EC, 0x1D7F6];

/// A handful of Mathematical Alphanumeric Symbols codepoints are left
/// unassigned by Unicode (to avoid clashing with pre-existing characters);
/// those letters are instead found at these older codepoints, mostly in
/// the Letterlike Symbols block.
const Map<int, int> _letterlikeHoles = {
  0x210E: 0x68, // italic h (PLANCK CONSTANT)
  0x212C: 0x42, 0x2130: 0x45, 0x2131: 0x46, 0x210B: 0x48, // script B E F H
  0x2110: 0x49, 0x2112: 0x4C, 0x2133: 0x4D, 0x211B: 0x52, // script I L M R
  0x212F: 0x65, 0x210A: 0x67, 0x2134: 0x6F, // script e g o
  0x212D: 0x43, 0x210C: 0x48, 0x2111: 0x49, 0x211C: 0x52, // fraktur C H I R
  0x2128: 0x5A, // fraktur Z
  0x2102: 0x43, 0x210D: 0x48, 0x2115: 0x4E, 0x2119: 0x50, // double-struck C H N P
  0x211A: 0x51, 0x211D: 0x52, 0x2124: 0x5A, // double-struck Q R Z
};

/// Folds a single "fancy" letter/digit (fullwidth, circled, parenthesized,
/// or any Mathematical Alphanumeric Symbols style) to its plain ascii
/// codepoint, or returns null when [cp] is not one of those (left for the
/// caller to handle, e.g. the punctuation/emoji strip in [normalizeText]).
int? foldFancyLetter(int cp) {
  if (cp >= 0xFF21 && cp <= 0xFF3A) return 0x41 + (cp - 0xFF21); // fullwidth A-Z
  if (cp >= 0xFF41 && cp <= 0xFF5A) return 0x61 + (cp - 0xFF41); // fullwidth a-z
  if (cp >= 0xFF10 && cp <= 0xFF19) return 0x30 + (cp - 0xFF10); // fullwidth 0-9

  if (cp >= 0x24B6 && cp <= 0x24CF) return 0x41 + (cp - 0x24B6); // circled A-Z
  if (cp >= 0x24D0 && cp <= 0x24E9) return 0x61 + (cp - 0x24D0); // circled a-z
  if (cp >= 0x249C && cp <= 0x24B5) return 0x61 + (cp - 0x249C); // parenthesized a-z
  if (cp >= 0x2460 && cp <= 0x2468) return 0x31 + (cp - 0x2460); // circled 1-9
  if (cp == 0x24EA) return 0x30; // circled 0

  for (final run in _mathLetterRuns) {
    final start = run[0], base = run[1];
    if (cp >= start && cp < start + 26) return base + (cp - start);
  }
  for (final start in _mathDigitStarts) {
    if (cp >= start && cp < start + 10) return 0x30 + (cp - start);
  }
  final hole = _letterlikeHoles[cp];
  if (hole != null) return hole;

  return null;
}

/// Lower-cases, folds fancy Unicode letters/digits (any font style, see
/// [foldFancyLetter]) to plain ascii, and turns everything else that is not
/// a letter or digit (emoji, punctuation, underscores, extra spaces) into
/// single spaces.
String normalizeText(String s) {
  final folded = String.fromCharCodes(
    s.runes.map((cp) => foldFancyLetter(cp) ?? cp),
  );
  return folded
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
}

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

/// Best-effort extraction of a queue position number from an interaction
/// response body (what Discord sends back right after the component click).
/// This bot has never seen a real "you are number N in queue" payload for
/// this specific queue system, so the shape is not verified - this walks
/// every string value in the JSON response (content, embed titles/
/// descriptions/fields, ...) and pattern-matches common phrasings
/// ("position 42", "number 42", "#42", "queue: 42", "spot 42"). Returns
/// null when nothing matches, which the caller must treat as "unknown",
/// never as position 0 or similar.
String? extractQueuePosition(String body) {
  final parts = <String>[];
  void walk(dynamic v) {
    if (v is String) {
      parts.add(v);
    } else if (v is Map) {
      v.values.forEach(walk);
    } else if (v is List) {
      v.forEach(walk);
    }
  }

  try {
    walk(jsonDecode(body));
  } catch (_) {
    parts.add(body);
  }
  final hay = parts.join('\n');

  final patterns = [
    RegExp(r'position[^0-9]{0,12}(\d{1,6})', caseSensitive: false),
    RegExp(r'queue[^0-9]{0,12}(\d{1,6})', caseSensitive: false),
    RegExp(r'spot[^0-9]{0,12}(\d{1,6})', caseSensitive: false),
    RegExp(r'(?:number|no\.?|#)\s*(\d{1,6})\b', caseSensitive: false),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(hay);
    if (m != null) return m.group(1);
  }
  return null;
}
