class HubConfig {
  const HubConfig({
    required this.baseUrl,
    required this.family,
    required this.serial,
    required this.hubKey,
    this.firmwareVersion = 'intercom-emulator/0.1.0',
    this.healthStatus = 'ok',
    this.statusIntervalSec = 20,
  });

  final String baseUrl;
  final String family;
  final String serial;
  final String hubKey;
  final String firmwareVersion;
  final String healthStatus;
  final int statusIntervalSec;

  static const String defaultBaseUrl = String.fromEnvironment(
    'EMU_BASE_URL',
    defaultValue: 'https://staging.igcsolutions.org',
  );
  static const String defaultFamily = String.fromEnvironment(
    'EMU_FAMILY',
    defaultValue: 'igci',
  );
  static const String defaultSerial = String.fromEnvironment(
    'EMU_SERIAL',
    defaultValue: 'igci000001',
  );
  static const String defaultHubKey = String.fromEnvironment(
    'HUB_KEY',
    defaultValue: '',
  );

  List<String> get missingRequiredFields {
    final missing = <String>[];
    if (baseUrl.trim().isEmpty) {
      missing.add('baseUrl');
    }
    if (family.trim().isEmpty) {
      missing.add('family');
    }
    if (serial.trim().isEmpty) {
      missing.add('serial');
    }
    if (hubKey.trim().isEmpty) {
      missing.add('hubKey');
    }
    return missing;
  }

  bool get isValid => missingRequiredFields.isEmpty;

  HubConfig copyWith({
    String? baseUrl,
    String? family,
    String? serial,
    String? hubKey,
    String? firmwareVersion,
    String? healthStatus,
    int? statusIntervalSec,
  }) {
    return HubConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      family: family ?? this.family,
      serial: serial ?? this.serial,
      hubKey: hubKey ?? this.hubKey,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      healthStatus: healthStatus ?? this.healthStatus,
      statusIntervalSec: statusIntervalSec ?? this.statusIntervalSec,
    );
  }

  HubConfig withRequiredFallbacks(HubConfig fallback) {
    return HubConfig(
      baseUrl: baseUrl.trim().isEmpty ? fallback.baseUrl : baseUrl,
      family: family.trim().isEmpty ? fallback.family : family,
      serial: serial.trim().isEmpty ? fallback.serial : serial,
      hubKey: hubKey.trim().isEmpty ? fallback.hubKey : hubKey,
      firmwareVersion: firmwareVersion,
      healthStatus: healthStatus,
      statusIntervalSec: statusIntervalSec,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'baseUrl': baseUrl,
      'family': family,
      'serial': serial,
      'hubKey': hubKey,
      'firmwareVersion': firmwareVersion,
      'healthStatus': healthStatus,
      'statusIntervalSec': statusIntervalSec,
    };
  }

  static HubConfig fromJson(Map<String, dynamic> map) {
    final interval = (map['statusIntervalSec'] is int)
        ? map['statusIntervalSec'] as int
        : int.tryParse('${map['statusIntervalSec']}') ?? 20;

    return HubConfig(
      baseUrl: '${map['baseUrl'] ?? ''}',
      family: '${map['family'] ?? ''}',
      serial: '${map['serial'] ?? ''}',
      hubKey: '${map['hubKey'] ?? ''}',
      firmwareVersion: '${map['firmwareVersion'] ?? 'intercom-emulator/0.1.0'}',
      healthStatus: '${map['healthStatus'] ?? 'ok'}',
      statusIntervalSec: interval,
    );
  }

  static HubConfig defaults() {
    return const HubConfig(
      baseUrl: defaultBaseUrl,
      family: defaultFamily,
      serial: defaultSerial,
      hubKey: defaultHubKey,
    );
  }
}
