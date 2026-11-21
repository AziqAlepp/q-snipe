import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../core/discord_rest.dart';
import '../core/models.dart';
import '../services/notification_service.dart';
import '../services/storage.dart';
import 'web_login_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const int _maxLogLines = 400;

  final Storage _storage = Storage();
  final FlutterBackgroundService _service = FlutterBackgroundService();
  final TextEditingController _webhookCtl = TextEditingController();
  final TextEditingController _spamCountCtl = TextEditingController();
  final TextEditingController _spamIntervalCtl = TextEditingController();
  final TextEditingController _pollCtl = TextEditingController();
  final List<String> _log = [];

  List<Profile> _profiles = const [];
  String? _selectedId;
  bool _running = false;
  int _snipes = 0;
  StreamSubscription<Map<String, dynamic>?>? _logSub;
  StreamSubscription<Map<String, dynamic>?>? _snipeSub;
  StreamSubscription<Map<String, dynamic>?>? _stoppedSub;

  Profile? get _sel {
    for (final p in _profiles) {
      if (p.id == _selectedId) return p;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final profiles = await _storage.loadProfiles();
    final running = await _service.isRunning();
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _selectedId = profiles.isEmpty ? null : profiles.first.id;
      _running = running;
    });
    _syncControllers();
    _logSub = _service.on('log').listen((e) {
      final line = e?['line'];
      if (line is! String || !mounted) return;
      setState(() {
        _log.add(line);
        if (_log.length > _maxLogLines) _log.removeAt(0);
      });
    });
    _snipeSub = _service.on('snipe').listen((_) {
      if (mounted) setState(() => _snipes++);
    });
    _stoppedSub = _service.on('stopped').listen((_) {
      if (mounted) setState(() => _running = false);
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _snipeSub?.cancel();
    _stoppedSub?.cancel();
    _webhookCtl.dispose();
    _spamCountCtl.dispose();
    _spamIntervalCtl.dispose();
    _pollCtl.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Copies the selected profile's settings into the text fields.
  void _syncControllers() {
    final c = _sel?.config;
    _webhookCtl.text = c?.webhookUrl ?? '';
    _spamCountCtl.text = (c?.spamCount ?? 10).toString();
    _spamIntervalCtl.text = (c?.spamIntervalMs ?? 0).toString();
    _pollCtl.text = (c?.pollSeconds ?? 0).toString();
  }

  Future<void> _updateSel(Profile Function(Profile) change) async {
    final sel = _sel;
    if (sel == null) return;
    final list = [for (final p in _profiles) p.id == sel.id ? change(p) : p];
    setState(() => _profiles = list);
    await _storage.saveProfiles(list);
  }

  Future<void> _updateConfig(SniperConfig Function(SniperConfig) change) =>
      _updateSel((p) => p.copyWith(config: change(p.config)));

  // ---- profiles ----------------------------------------------------------

  /// Returns the account name, '' if it could not be read (offline), or null
  /// if Discord rejected the token.
  Future<String?> _checkToken(String token) async {
    final rest = DiscordRest(token);
    try {
      return await rest.validateToken();
    } on StateError catch (e) {
      _toast(e.message);
      return null;
    } catch (_) {
      return '';
    } finally {
      rest.close();
    }
  }

  Future<void> _addProfile() async {
    final r = await showDialog<_ProfileResult>(
      context: context,
      builder: (_) => const _ProfileDialog(
        title: 'New profile',
        requireToken: true,
      ),
    );
    if (r == null || r.token == null) return;
    _toast('Checking token...');
    final name = await _checkToken(r.token!);
    if (name == null) return;
    final id = Storage.newId();
    final profile = Profile(id: id, label: r.label, username: name);
    await _storage.writeToken(id, r.token!);
    final list = [..._profiles, profile];
    await _storage.saveProfiles(list);
    if (!mounted) return;
    setState(() {
      _profiles = list;
      _selectedId = id;
    });
    _syncControllers();
    _toast(name.isEmpty
        ? 'Profile added.'
        : 'Profile added: @$name. Token saved to the keystore.');
  }

  Future<void> _editProfile() async {
    final sel = _sel;
    if (sel == null) return;
    final r = await showDialog<_ProfileResult>(
      context: context,
      builder: (_) => _ProfileDialog(
        title: 'Edit profile',
        initialLabel: sel.label,
        requireToken: false,
      ),
    );
    if (r == null) return;
    var username = sel.username;
    if (r.token != null) {
      _toast('Checking token...');
      final name = await _checkToken(r.token!);
      if (name == null) return;
      await _storage.writeToken(sel.id, r.token!);
      username = name;
    }
    await _updateSel((p) => p.copyWith(label: r.label, username: username));
  }

  Future<void> _removeProfile() async {
    final sel = _sel;
    if (sel == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${sel.label}"?'),
        content: const Text('Its token and settings are deleted from this phone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('REMOVE'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _storage.deleteToken(sel.id);
    final list = _profiles.where((p) => p.id != sel.id).toList();
    await _storage.saveProfiles(list);
    if (!mounted) return;
    setState(() {
      _profiles = list;
      _selectedId = list.isEmpty ? null : list.first.id;
    });
    _syncControllers();
  }

  // ---- settings of the selected profile ----------------------------------

  Future<void> _addTarget() async {
    final t = await showDialog<QueueTarget>(
      context: context,
      builder: (_) => const _TargetDialog(),
    );
    if (t == null) return;
    await _updateConfig((c) => c.copyWith(targets: [...c.targets, t]));
  }

  Future<void> _removeTarget(int i) => _updateConfig((c) {
        final list = [...c.targets]..removeAt(i);
        return c.copyWith(targets: list);
      });

  Future<void> _applyWebhook() async {
    final url = _webhookCtl.text.trim();
    if (url.isNotEmpty && !isValidWebhookUrl(url)) {
      _toast('Not a Discord webhook URL (https://discord.com/api/webhooks/...).');
      return;
    }
    await _updateConfig((c) => c.copyWith(webhookUrl: url));
    _toast(url.isEmpty ? 'Webhook cleared.' : 'Webhook applied.');
  }

  // ---- engine ------------------------------------------------------------

  List<Profile> get _runnable => _profiles
      .where((p) => p.enabled && p.config.targets.isNotEmpty)
      .toList();

  Future<void> _toggleEngine() async {
    if (_running) {
      _service.invoke('stop');
      return;
    }
    if (_profiles.isEmpty) {
      _toast('Add a profile first.');
      return;
    }
    if (_runnable.isEmpty) {
      _toast('Enable a profile that has at least one queue channel.');
      return;
    }
    await _storage.saveProfiles(_profiles);
    await NotificationService.instance.requestPermission();
    final started = await _service.startService();
    if (!mounted) return;
    setState(() {
      _running = started;
      _snipes = 0;
    });
    if (!started) _toast('Service did not start.');
  }

  // ---- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _sel;
    final cfg = sel?.config;
    return Scaffold(
      appBar: AppBar(title: const Text('Queue Sniper')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(
            title: 'ENGINE',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _running
                      ? 'RUNNING  |  snipes this run: $_snipes'
                      : 'STOPPED',
                  style: TextStyle(
                    color: _running ? scheme.primary : scheme.outline,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                if (_runnable.isEmpty)
                  const Text('No profile ready to run.')
                else
                  for (final p in _runnable) Text('• ${p.display}'),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _toggleEngine,
                    icon: Icon(_running ? Icons.stop : Icons.bolt),
                    label: Text(
                      _running ? 'HALT SNIPER ENGINE' : 'ENGAGE SNIPER',
                    ),
                  ),
                ),
                if (_running)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Stop and start again to apply changes.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          _card(
            title: 'PROFILES (${_profiles.length})',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_profiles.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('No profile yet. Add one with a Discord account.'),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final p in _profiles)
                      ChoiceChip(
                        label: Text(p.label),
                        avatar: Icon(
                          p.enabled ? Icons.check_circle : Icons.pause_circle,
                          size: 18,
                        ),
                        selected: p.id == _selectedId,
                        onSelected: (_) {
                          setState(() => _selectedId = p.id);
                          _syncControllers();
                        },
                      ),
                  ],
                ),
                if (sel != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    sel.username.isEmpty
                        ? 'Account: unknown'
                        : 'Account: @${sel.username}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Include when engine runs'),
                    value: sel.enabled,
                    onChanged: _running
                        ? null
                        : (v) => _updateSel((p) => p.copyWith(enabled: v)),
                  ),
                  Row(
                    children: [
                      OutlinedButton(
                        onPressed: _running ? null : _editProfile,
                        child: const Text('RENAME / NEW TOKEN'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _running ? null : _removeProfile,
                        child: const Text('REMOVE'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _running ? null : _addProfile,
                  icon: const Icon(Icons.person_add),
                  label: const Text('ADD PROFILE'),
                ),
              ],
            ),
          ),
          if (sel != null && cfg != null) ...[
            _card(
              title: 'QUEUE CHANNELS (${cfg.targets.length})  |  ${sel.label}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < cfg.targets.length; i++)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('GUILD ${cfg.targets[i].guildId}'),
                      subtitle: Text(
                        'channel ${cfg.targets[i].channelId}\n'
                        '${cfg.targets[i].customButtonId.isNotEmpty ? 'button id: ${cfg.targets[i].customButtonId}' : 'keywords: ${cfg.targets[i].keywords.isEmpty ? '(any button)' : cfg.targets[i].keywords.join(', ')}'}',
                      ),
                      isThreeLine: true,
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _running ? null : () => _removeTarget(i),
                      ),
                    ),
                  if (cfg.targets.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text('No queue channel yet.'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _running ? null : _addTarget,
                    icon: const Icon(Icons.add),
                    label: const Text('ADD QUEUE CHANNEL'),
                  ),
                ],
              ),
            ),
            _card(
              title: 'CLICK SPEED  |  ${sel.label}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Spam mode'),
                    subtitle: const Text(
                      'Click the button repeatedly until one click succeeds. '
                      'The same button can be pressed several times.',
                    ),
                    value: cfg.spamEnabled,
                    onChanged: _running
                        ? null
                        : (v) => _updateConfig((c) => c.copyWith(spamEnabled: v)),
                  ),
                  if (cfg.spamEnabled) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _spamCountCtl,
                      enabled: !_running,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText:
                            'Clicks per snipe (1-${SniperConfig.maxSpamCount})',
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null) {
                          _updateConfig((c) => c.copyWith(spamCount: n));
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _spamIntervalCtl,
                      enabled: !_running,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText:
                            'Interval in ms (0-${SniperConfig.maxSpamIntervalMs})',
                        helperText:
                            '0 = fire all clicks at once (fastest). Rate limits (429) are possible.',
                        helperMaxLines: 2,
                        border: const OutlineInputBorder(),
                      ),
                      onChanged: (v) {
                        final n = int.tryParse(v);
                        if (n != null) {
                          _updateConfig((c) => c.copyWith(spamIntervalMs: n));
                        }
                      },
                    ),
                  ],
                ],
              ),
            ),
            _card(
              title: 'DETECTION  |  ${sel.label}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Scan latest messages on start'),
                    subtitle: const Text(
                      'Reads the newest messages of each queue channel when '
                      'the engine connects, so a queue that is already open '
                      'is joined at once.',
                    ),
                    value: cfg.scanOnStart,
                    onChanged: _running
                        ? null
                        : (v) => _updateConfig((c) => c.copyWith(scanOnStart: v)),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _pollCtl,
                    enabled: !_running,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText:
                          'Re-check every N seconds (0-${SniperConfig.maxPollSeconds}, 0 = off)',
                      helperText:
                          'Safety net if gateway events are missed. One request per channel per check.',
                      helperMaxLines: 2,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) {
                      final n = int.tryParse(v);
                      if (n != null) {
                        _updateConfig((c) => c.copyWith(pollSeconds: n));
                      }
                    },
                  ),
                ],
              ),
            ),
            _card(
              title: 'ALERTS, WEBHOOK, DEBUG  |  ${sel.label}',
              child: Column(
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Play sound on snipe'),
                    value: cfg.soundEnabled,
                    onChanged: _running
                        ? null
                        : (v) => _updateConfig((c) => c.copyWith(soundEnabled: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Pop-up notification + vibration'),
                    value: cfg.notifyEnabled,
                    onChanged: _running
                        ? null
                        : (v) => _updateConfig((c) => c.copyWith(notifyEnabled: v)),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Debug log'),
                    subtitle: const Text(
                      'Log every message the gateway delivers, to see why a '
                      'button is not clicked.',
                    ),
                    value: cfg.verbose,
                    onChanged: _running
                        ? null
                        : (v) => _updateConfig((c) => c.copyWith(verbose: v)),
                  ),
                  TextField(
                    controller: _webhookCtl,
                    enabled: !_running,
                    decoration: const InputDecoration(
                      labelText: 'Discord webhook URL (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: _running ? null : _applyWebhook,
                      child: const Text('APPLY WEBHOOK'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          _card(
            title: 'LOG',
            child: SizedBox(
              height: 280,
              child: _log.isEmpty
                  ? const Text(
                      'Logs from Discord Gateway and queue snipes will '
                      'stream here, tagged with the profile name.',
                    )
                  : ListView.builder(
                      reverse: true,
                      itemCount: _log.length,
                      itemBuilder: (_, i) => Text(
                        _log[_log.length - 1 - i],
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({required String title, required Widget child}) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      );
}

class _ProfileResult {
  const _ProfileResult(this.label, this.token);
  final String label;

  /// Normalised token, or null when the user left the field empty (edit only).
  final String? token;
}

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({
    required this.title,
    required this.requireToken,
    this.initialLabel = '',
  });

  final String title;
  final bool requireToken;
  final String initialLabel;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final TextEditingController _label =
      TextEditingController(text: widget.initialLabel);
  final TextEditingController _token = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final t = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const WebLoginPage()),
    );
    if (t == null || !mounted) return;
    setState(() {
      _token.text = t;
      _error = null;
    });
  }

  void _submit() {
    final label = _label.text.trim();
    if (label.isEmpty) {
      setState(() => _error = 'Give the profile a name.');
      return;
    }
    final raw = _token.text.trim();
    String? token;
    if (raw.isNotEmpty || widget.requireToken) {
      token = normalizeCapturedToken(raw);
      if (token == null) {
        setState(() => _error = 'Token missing or not valid.');
        return;
      }
    }
    Navigator.pop(context, _ProfileResult(label, token));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _label,
              decoration: const InputDecoration(
                labelText: 'Profile name',
                helperText: 'Shown in the log, e.g. Main or Alt 1',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _token,
              obscureText: true,
              decoration: InputDecoration(
                labelText: widget.requireToken
                    ? 'Token'
                    : 'New token (leave empty to keep)',
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _login,
                icon: const Icon(Icons.login),
                label: const Text('LOGIN WITH DISCORD'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        FilledButton(onPressed: _submit, child: const Text('SAVE')),
      ],
    );
  }
}

class _TargetDialog extends StatefulWidget {
  const _TargetDialog();

  @override
  State<_TargetDialog> createState() => _TargetDialogState();
}

class _TargetDialogState extends State<_TargetDialog> {
  final TextEditingController _guild = TextEditingController();
  final TextEditingController _channel = TextEditingController();
  final TextEditingController _button = TextEditingController();
  final TextEditingController _keywords =
      TextEditingController(text: QueueTarget.defaultKeywords.join(', '));
  String? _error;

  @override
  void dispose() {
    _guild.dispose();
    _channel.dispose();
    _button.dispose();
    _keywords.dispose();
    super.dispose();
  }

  void _submit() {
    final g = _guild.text.trim();
    final c = _channel.text.trim();
    if (!isSnowflake(g) || !isSnowflake(c)) {
      setState(() => _error = 'Guild and channel ids must be 15-21 digits.');
      return;
    }
    final kw = _keywords.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    Navigator.pop(
      context,
      QueueTarget(
        guildId: g,
        channelId: c,
        customButtonId: _button.text.trim(),
        keywords: kw,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Queue channel'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _guild,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'GUILD ID (server)'),
            ),
            TextField(
              controller: _channel,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'CHANNEL ID (QUEUE)'),
            ),
            TextField(
              controller: _button,
              decoration: const InputDecoration(
                labelText: 'CUSTOM BUTTON ID (OPTIONAL)',
              ),
            ),
            TextField(
              controller: _keywords,
              decoration: const InputDecoration(
                labelText: 'Label keywords (used when no button id)',
                helperText:
                    'comma separated; empty = click the first button of any label',
                helperMaxLines: 2,
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCEL'),
        ),
        FilledButton(onPressed: _submit, child: const Text('ADD')),
      ],
    );
  }
}
