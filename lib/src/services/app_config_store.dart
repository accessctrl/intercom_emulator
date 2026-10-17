import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/hub_config.dart';

class AppConfigStore {
  static const String _storageKey = 'hub_config_v1';

  Future<HubConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw == null || raw.isEmpty) {
      return HubConfig.defaults();
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return HubConfig.fromJson(decoded);
      }
      return HubConfig.defaults();
    } catch (_) {
      return HubConfig.defaults();
    }
  }

  Future<void> save(HubConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(config.toJson()));
  }
}
