import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';

/// Profiles (labels + settings) go to plain preferences; each profile's token
/// goes to the Android keystore-backed secure storage under `token_<id>`.
/// Both the UI isolate and the background service isolate use this class.
class Storage {
  static const String _profilesKey = 'queue_sniper_profiles';

  // Keys of version 1 (single account), migrated on first load.
  static const String _legacyTokenKey = 'discord_token';
  static const String _legacyConfigKey = 'queue_sniper_config';

  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  static String newId() => DateTime.now().microsecondsSinceEpoch.toString();

  Future<String?> readToken(String profileId) =>
      _secure.read(key: 'token_$profileId');

  Future<void> writeToken(String profileId, String token) =>
      _secure.write(key: 'token_$profileId', value: token);

  Future<void> deleteToken(String profileId) =>
      _secure.delete(key: 'token_$profileId');

  Future<List<Profile>> loadProfiles() async {
    final p = await SharedPreferences.getInstance();
    await p.reload(); // the other isolate may have written it
    final list = decodeProfiles(p.getString(_profilesKey));
    if (list.isNotEmpty) return list;

    // Migrate a version 1 install (one token + one config).
    final old = await _secure.read(key: _legacyTokenKey);
    if (old == null || old.isEmpty) return const [];
    final profile = Profile(
      id: newId(),
      label: 'Main',
      config: SniperConfig.decode(p.getString(_legacyConfigKey)),
    );
    await writeToken(profile.id, old);
    await saveProfiles([profile]);
    await _secure.delete(key: _legacyTokenKey);
    return [profile];
  }

  Future<void> saveProfiles(List<Profile> list) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_profilesKey, encodeProfiles(list));
  }
}
