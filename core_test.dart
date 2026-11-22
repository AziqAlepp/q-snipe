import 'package:flutter_test/flutter_test.dart';
import 'package:queue_sniper/core/button_matcher.dart';
import 'package:queue_sniper/core/discord_rest.dart';
import 'package:queue_sniper/core/models.dart';

Map<String, dynamic> _btn(String id, String label,
        {int style = 1, bool disabled = false}) =>
    {
      'type': 2,
      'custom_id': id,
      'label': label,
      'style': style,
      'disabled': disabled,
    };

List<Map<String, dynamic>> _row(List<Map<String, dynamic>> buttons) => [
      {'type': 1, 'components': buttons},
    ];

void main() {
  const g = '111111111111111111';
  const c = '222222222222222222';

  group('findButton', () {
    test('exact custom id wins over keywords', () {
      const t = QueueTarget(guildId: g, channelId: c, customButtonId: 'q_join');
      final m = findButton(
        _row([_btn('other', 'Join queue'), _btn('q_join', 'Go')]),
        t,
      );
      expect(m?.customId, 'q_join');
    });

    test('custom id set but absent -> null (no keyword fallback)', () {
      const t = QueueTarget(guildId: g, channelId: c, customButtonId: 'nope');
      expect(findButton(_row([_btn('a', 'Join queue')]), t), isNull);
    });

    test('keyword match is case-insensitive on label', () {
      const t = QueueTarget(guildId: g, channelId: c);
      final m = findButton(_row([_btn('x1', 'Leave'), _btn('x2', 'JOIN')]), t);
      expect(m?.customId, 'x2');
    });

    test('skips disabled and link buttons', () {
      const t = QueueTarget(guildId: g, channelId: c);
      final m = findButton(
        _row([
          _btn('a', 'Join', disabled: true),
          _btn('b', 'Join', style: 5),
          _btn('c', 'Join'),
        ]),
        t,
      );
      expect(m?.customId, 'c');
    });

    test('empty keywords -> first clickable button', () {
      const t = QueueTarget(guildId: g, channelId: c, keywords: []);
      expect(findButton(_row([_btn('first', 'Whatever')]), t)?.customId,
          'first');
    });

    test('finds buttons nested in container/section layouts', () {
      const t = QueueTarget(guildId: g, channelId: c);
      final comps = [
        {
          'type': 17,
          'components': [
            {
              'type': 9,
              'components': [
                {'type': 10, 'content': 'text'}
              ],
              'accessory': _btn('deep', 'Join'),
            }
          ],
        }
      ];
      expect(findButton(comps, t)?.customId, 'deep');
    });

    test('keyword mode never picks a leave/cancel button', () {
      const t = QueueTarget(guildId: g, channelId: c);
      final m = findButton(
        _row([_btn('leave_queue', 'Leave Queue'), _btn('go', 'Join Queue')]),
        t,
      );
      expect(m?.customId, 'go');
    });

    test('keyword phrase matches loosely, not only 100%', () {
      const t = QueueTarget(
        guildId: g,
        channelId: c,
        keywords: ['join queue'],
      );
      for (final label in [
        'Join',
        'JOIN QUEUE',
        'Queue Now',
        'Join the queue!',
        '✅ Join-Queue',
        'Joinn Queu',
      ]) {
        expect(findButton(_row([_btn('x', label)]), t)?.customId, 'x',
            reason: label);
      }
    });

    test('best scoring button wins over the first partial one', () {
      const t = QueueTarget(guildId: g, channelId: c, keywords: ['join queue']);
      final m = findButton(
        _row([_btn('info', 'Queue info'), _btn('go', 'Join Queue')]),
        t,
      );
      expect(m?.customId, 'go');
    });

    test('unrelated labels still do not match', () {
      const t = QueueTarget(guildId: g, channelId: c, keywords: ['join queue']);
      expect(findButton(_row([_btn('a', 'Rules'), _btn('b', 'Stats')]), t),
          isNull);
    });

    test('custom id falls back to a partial id match', () {
      const t = QueueTarget(
          guildId: g, channelId: c, customButtonId: 'join_queue');
      expect(findButton(_row([_btn('btn_join_queue_v2', 'x')]), t)?.customId,
          'btn_join_queue_v2');
    });

    test('no match -> null', () {
      const t = QueueTarget(guildId: g, channelId: c);
      expect(findButton(_row([_btn('a', 'Leave')]), t), isNull);
      expect(findButton(null, t), isNull);
    });
  });

  group('fancy-font normalisation', () {
    test('every common "fancy text" style still matches plain keywords', () {
      const t = QueueTarget(guildId: g, channelId: c, keywords: ['join queue']);
      for (final label in [
        '𝐉𝐨𝐢𝐧 𝐐𝐮𝐞𝐮𝐞', // bold
        '𝙹𝚘𝚒𝚗 𝚀𝚞𝚎𝚞𝚎', // monospace
        '𝑱𝒐𝒊𝒏 𝑸𝒖𝒆𝒖𝒆', // bold italic
        '𝒥𝑜𝒾𝓃 𝒬𝓊𝑒𝓊𝑒', // script
        '𝔍𝔬𝔦𝔫 𝔔𝔲𝔢𝔲𝔢', // fraktur
        '𝕁𝕠𝕚𝕟 𝕼𝕦𝕖𝕦𝕖', // double-struck
        'ＪＯＩＮ ＱＵＥＵＥ', // fullwidth
        'Ⓙⓞⓘⓝ Ⓠⓤⓔⓤⓔ', // circled
        '✅ Join Queue 🔥', // emoji around plain text
      ]) {
        expect(findButton(_row([_btn('x', label)]), t)?.customId, 'x',
            reason: label);
      }
    });

    test('fancy digits fold to ascii too', () {
      expect(normalizeText('𝟏𝟐𝟑'), '123'); // bold digits
      expect(normalizeText('１２３'), '123'); // fullwidth digits
    });
  });

  group('nonce and body', () {
    test('nonce is the discord snowflake of the timestamp', () {
      expect(generateNonce(nowMs: discordEpochMs + 1), '4194304');
    });

    test('interaction body carries the click fields', () {
      final b = buildInteractionBody(
        guildId: g,
        channelId: c,
        messageId: '3',
        messageFlags: 0,
        applicationId: '4',
        sessionId: 's',
        customId: 'q',
        nonce: 'n',
      );
      expect(b['type'], 3);
      expect(b['data'], {'component_type': 2, 'custom_id': 'q'});
      expect(b['session_id'], 's');
    });
  });

  group('models', () {
    test('snowflake and webhook validation', () {
      expect(isSnowflake('123456789012345678'), isTrue);
      expect(isSnowflake('abc'), isFalse);
      expect(
          isValidWebhookUrl('https://discord.com/api/webhooks/1/abc'), isTrue);
      expect(isValidWebhookUrl('https://evil.example/api/webhooks/1/abc'),
          isFalse);
      expect(isValidWebhookUrl('http://discord.com/api/webhooks/1/abc'),
          isFalse);
    });

    test('captured token normalisation', () {
      const tok = 'MTExMTExMTExMTExMTExMTEx.abcdef.0123456789abcdefghij';
      expect(normalizeCapturedToken(tok), tok);
      expect(normalizeCapturedToken('"$tok"'), tok);
      expect(normalizeCapturedToken('"\\"$tok\\""'), tok);
      expect(normalizeCapturedToken('null'), isNull);
      expect(normalizeCapturedToken('short'), isNull);
      expect(normalizeCapturedToken('has space in the middle of it ok'),
          isNull);
    });

    test('config round-trips and survives garbage', () {
      const cfg = SniperConfig(
        targets: [QueueTarget(guildId: g, channelId: c, customButtonId: 'b')],
        webhookUrl: 'https://discord.com/api/webhooks/1/abc',
        soundEnabled: false,
      );
      final back = SniperConfig.decode(cfg.encode());
      expect(back.targets.single.customButtonId, 'b');
      expect(back.soundEnabled, isFalse);
      expect(SniperConfig.decode('not json').targets, isEmpty);
    });
  });

  group('profiles, spam settings, helpers', () {
    test('spam settings are clamped', () {
      final c = const SniperConfig()
          .copyWith(spamCount: 5000, spamIntervalMs: -4, spamWindowMs: 999999);
      expect(c.spamCount, SniperConfig.maxSpamCount);
      expect(c.spamIntervalMs, 0);
      expect(c.spamWindowMs, SniperConfig.maxSpamWindowMs);
      expect(const SniperConfig().copyWith(spamWindowMs: 1).spamWindowMs,
          SniperConfig.minSpamWindowMs);
    });

    test('webhook is fixed and always a valid discord webhook url', () {
      expect(isValidWebhookUrl(kFixedWebhookUrl), isTrue);
    });

    test('queue position is pulled from common phrasings, else null', () {
      expect(extractQueuePosition('{"data":{"content":"You are number 42 in queue"}}'), '42');
      expect(extractQueuePosition('{"data":{"embeds":[{"description":"Position: 7"}]}}'), '7');
      expect(extractQueuePosition('{"data":{"content":"Queue spot #13"}}'), '13');
      expect(extractQueuePosition('{"data":{"content":"You joined!"}}'), isNull);
      expect(extractQueuePosition('not json'), isNull);
    });

    test('profiles round-trip without any token in the JSON', () {
      final list = [
        Profile(
          id: '1',
          label: 'Main',
          username: 'vx',
          config: const SniperConfig(spamEnabled: true, spamCount: 7),
        ),
        const Profile(id: '2', label: 'Alt', enabled: false),
      ];
      final raw = encodeProfiles(list);
      expect(raw.contains('token'), isFalse);
      final back = decodeProfiles(raw);
      expect(back.length, 2);
      expect(back.first.config.spamCount, 7);
      expect(back.first.display, 'Main (@vx)');
      expect(back.last.enabled, isFalse);
      expect(decodeProfiles('garbage'), isEmpty);
    });

    test('detection settings round-trip and clamp', () {
      final c = const SniperConfig().copyWith(scanOnStart: false, pollSeconds: 999);
      expect(c.pollSeconds, SniperConfig.maxPollSeconds);
      final back = SniperConfig.decode(c.encode());
      expect(back.scanOnStart, isFalse);
      expect(back.pollSeconds, SniperConfig.maxPollSeconds);
      expect(const SniperConfig().scanOnStart, isTrue);
    });

    test('retryAfterMs reads and caps the 429 body', () {
      expect(retryAfterMs('{"retry_after": 0.25}'), 250);
      expect(retryAfterMs('{"retry_after": 30}'), 2000);
      expect(retryAfterMs('not json'), 500);
    });

    test('describeButtons lists labels, ids and flags', () {
      final out = describeButtons(_row([
        _btn('a', 'Join'),
        _btn('b', 'Site', style: 5),
        _btn('c', 'Full', disabled: true),
      ]));
      expect(out.length, 3);
      expect(out[0], '"Join" id=a');
      expect(out[1].contains('link'), isTrue);
      expect(out[2].contains('disabled'), isTrue);
    });
  });
}
