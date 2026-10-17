class HubCommand {
  const HubCommand({
    required this.id,
    required this.type,
    required this.controller,
    required this.payload,
  });

  final String id;
  final String type;
  final HubControllerRef controller;
  final Map<String, dynamic> payload;

  static HubCommand? fromJson(Map<String, dynamic> map) {
    final id = '${map['id'] ?? ''}'.trim();
    final type = '${map['type'] ?? ''}'.trim();
    final controllerMap = map['controller'];
    final payloadMap = map['payload'];

    if (id.isEmpty || type.isEmpty) {
      return null;
    }
    if (controllerMap is! Map<String, dynamic>) {
      return null;
    }

    return HubCommand(
      id: id,
      type: type,
      controller: HubControllerRef.fromJson(controllerMap),
      payload: payloadMap is Map<String, dynamic>
          ? payloadMap
          : const <String, dynamic>{},
    );
  }
}

class HubControllerRef {
  const HubControllerRef({
    required this.id,
    required this.family,
    required this.serial,
  });

  final String id;
  final String family;
  final String serial;

  static HubControllerRef fromJson(Map<String, dynamic> map) {
    return HubControllerRef(
      id: '${map['id'] ?? ''}',
      family: '${map['family'] ?? ''}',
      serial: '${map['serial'] ?? ''}',
    );
  }
}
