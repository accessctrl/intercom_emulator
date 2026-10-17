import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../models/hub_command.dart';
import '../models/hub_config.dart';

enum HubConnectionState {
  disconnected,
  connecting,
  connected,
  authenticated,
  closing,
  failed,
}

typedef LogCallback = void Function(String message, {String? details});
typedef StateCallback = void Function(
  HubConnectionState state, {
  String? error,
});
typedef CommandCallback = Future<void> Function(HubCommand command);

class HubWsClient {
  HubWsClient({
    required this._onInfo,
    required this._onWarning,
    required this._onError,
    required this._onStateChanged,
    required this._onCommand,
  });

  final LogCallback _onInfo;
  final LogCallback _onWarning;
  final LogCallback _onError;
  final StateCallback _onStateChanged;
  final CommandCallback _onCommand;

  WebSocket? _socket;
  HubConfig? _config;
  Timer? _statusTimer;
  bool _isClosedByClient = false;
  bool _didEmitDisconnected = false;
  int _serverTimeOffsetSec = 0;
  bool _authRetriedAfterSkew = false;

  bool get isConnected => _socket != null;

  Future<void> connect(HubConfig config) async {
    await disconnect();

    _config = config;
    _isClosedByClient = false;
    _didEmitDisconnected = false;
    _emitState(HubConnectionState.connecting);

    final wsUrl = _buildWsUrl(config.baseUrl);

    try {
      await _syncServerTimeOffset(config.baseUrl);
      _onInfo(
        'Connecting to hub websocket',
        details:
            'url=$wsUrl family=${config.family.trim().toLowerCase()} serial=${config.serial.trim()}',
      );
      final socket = await WebSocket.connect(wsUrl);
      _socket = socket;
      _emitState(HubConnectionState.connected);

      socket.listen(
        _onData,
        onError: (Object error, StackTrace stackTrace) {
          _onError('WebSocket error', details: '$error');
          _emitState(HubConnectionState.failed, error: '$error');
        },
        onDone: () {
          final code = socket.closeCode;
          final reason = socket.closeReason;
          if (_isClosedByClient) {
            _onInfo(
              'WebSocket closed after client disconnect',
              details: 'code=$code reason=$reason',
            );
          } else {
            _onWarning(
              'WebSocket closed',
              details: 'code=$code reason=$reason',
            );
          }
          _cleanupAfterClose();
          if (!_isClosedByClient) {
            _emitState(
              HubConnectionState.failed,
              error: 'Connection closed by server',
            );
          } else {
            _emitDisconnectedOnce();
          }
        },
      );

      _sendAuth(config);
      _startStatusTimer(config.statusIntervalSec);
    } catch (error) {
      _onError('WebSocket connect failed', details: '$error');
      _emitState(HubConnectionState.failed, error: '$error');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _isClosedByClient = true;
    _didEmitDisconnected = false;
    _statusTimer?.cancel();
    _statusTimer = null;

    final socket = _socket;
    _socket = null;

    if (socket != null) {
      _emitState(HubConnectionState.closing);
      await socket.close(1000, 'Client disconnect');
      _emitDisconnectedOnce();
      _onInfo('Client disconnect completed');
    }
  }

  bool sendStatus({bool online = true}) {
    final config = _config;
    if (config == null) {
      _onWarning('Cannot send status: config is not loaded');
      return false;
    }

    final body = _buildStatusBody(config, online: online);
    return _sendJson(<String, dynamic>{'type': 'status', 'body': body});
  }

  bool requestPull({int max = 50}) {
    return _sendJson(<String, dynamic>{'type': 'pull', 'max': max});
  }

  bool sendCommandResults(List<Map<String, dynamic>> results) {
    if (results.isEmpty) {
      _onWarning('Skipping command_results: empty payload');
      return false;
    }

    return _sendJson(<String, dynamic>{
      'type': 'command_results',
      'results': results,
    });
  }

  bool sendEvent({required String eventType, Map<String, dynamic>? body}) {
    final trimmedType = eventType.trim();
    if (trimmedType.isEmpty) {
      _onWarning('Skipping event send: empty event type');
      return false;
    }

    return _sendJson(<String, dynamic>{
      'type': 'events',
      'event_type': trimmedType,
      'body': body ?? const <String, dynamic>{},
    });
  }

  void _sendAuth(HubConfig config) {
    final ts = _nowServerAlignedSec().toString();
    final nonce = _nonceHex();
    final body = _buildStatusBody(config, online: true);

    final signature = _computeSignature(
      key: config.hubKey,
      ts: ts,
      nonce: nonce,
      body: body,
    );

    final payload = <String, dynamic>{
      'type': 'auth',
      'family': config.family.trim().toLowerCase(),
      'serial': config.serial.trim(),
      'ts': ts,
      'nonce': nonce,
      'sign': signature,
      'body': body,
    };

    _sendJson(payload, redactSign: true);
    _onInfo(
      'Auth payload sent',
      details:
          'family=${config.family.trim().toLowerCase()} serial=${config.serial.trim()} ts=$ts offsetSec=$_serverTimeOffsetSec',
    );
    _emitState(HubConnectionState.connecting);
  }

  Map<String, dynamic> _buildStatusBody(
    HubConfig config, {
    required bool online,
  }) {
    final body = <String, dynamic>{};
    body['online'] = online;
    body['health_status'] = config.healthStatus.trim().isEmpty
        ? 'ok'
        : config.healthStatus.trim().toLowerCase();
    body['firmware_version'] = config.firmwareVersion.trim();
    body['controller_fw'] = config.firmwareVersion.trim();
    body['error_codes'] = <String>[];
    body['connected_controllers'] = const [];
    return body;
  }

  void _onData(dynamic rawData) async {
    final text = rawData is String
        ? rawData
        : utf8.decode(rawData as List<int>);

    _onInfo('WS IN frame', details: _truncate(text, max: 1500));

    Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        _onWarning('Ignoring non-object message', details: text);
        return;
      }
      map = decoded;
    } catch (error) {
      _onWarning('Invalid JSON from server', details: '$error');
      return;
    }

    final type = '${map['type'] ?? ''}'.trim().toLowerCase();
    if (type.isEmpty) {
      _onWarning('Message without type', details: text);
      return;
    }

    switch (type) {
      case 'auth_ok':
        _onInfo('Authenticated successfully', details: text);
        _emitState(HubConnectionState.authenticated);
        return;
      case 'auth_error':
        _onError('Authentication failed', details: text);

        final errorText = '${map['error'] ?? ''}'.toLowerCase();
        final cfg = _config;
        if (cfg != null &&
            !_authRetriedAfterSkew &&
            errorText.contains('timestamp out of allowed window')) {
          _authRetriedAfterSkew = true;
          _onWarning(
            'Timestamp skew detected, retrying auth after server time sync',
          );
          await _syncServerTimeOffset(cfg.baseUrl);
          _sendAuth(cfg);
          return;
        }

        _emitState(
          HubConnectionState.failed,
          error: '${map['error'] ?? 'auth_error'}',
        );
        return;
      case 'status_ok':
      case 'results_ok':
      case 'pong':
      case 'init_uid':
        _onInfo('Server message: $type', details: text);
        return;
      case 'error':
        _onWarning('Server error message', details: text);
        return;
      case 'command':
        final rawCommand = map['command'];
        if (rawCommand is Map<String, dynamic>) {
          final command = HubCommand.fromJson(rawCommand);
          if (command != null) {
            await _onCommand(command);
          }
        }
        return;
      case 'command_batch':
        final commands = map['commands'];
        if (commands is List) {
          for (final item in commands) {
            if (item is Map<String, dynamic>) {
              final command = HubCommand.fromJson(item);
              if (command != null) {
                await _onCommand(command);
              }
            }
          }
        }
        return;
      default:
        _onInfo('Unhandled server type: $type', details: text);
        return;
    }
  }

  bool _sendJson(Map<String, dynamic> payload, {bool redactSign = false}) {
    final socket = _socket;
    if (socket == null) {
      _onWarning(
        'Cannot send message: socket is not connected',
        details: 'type=${payload['type']}',
      );
      return false;
    }

    if (socket.readyState != WebSocket.open) {
      _onWarning(
        'Cannot send message: socket is not open',
        details: 'type=${payload['type']} state=${socket.readyState}',
      );
      return false;
    }

    final encoded = jsonEncode(payload);
    socket.add(encoded);
    _onInfo(
      'WS OUT frame',
      details: _truncate(
        _logPayload(payload, redactSign: redactSign),
        max: 1500,
      ),
    );
    return true;
  }

  String _logPayload(Map<String, dynamic> payload, {required bool redactSign}) {
    if (!redactSign) {
      return jsonEncode(payload);
    }
    final copy = Map<String, dynamic>.from(payload);
    final sign = '${copy['sign'] ?? ''}';
    if (sign.isNotEmpty) {
      copy['sign'] = sign.length <= 12
          ? '***'
          : '${sign.substring(0, 6)}***${sign.substring(sign.length - 4)}';
    }
    return jsonEncode(copy);
  }

  String _truncate(String value, {required int max}) {
    if (value.length <= max) {
      return value;
    }
    return '${value.substring(0, max)}... [truncated ${value.length - max} chars]';
  }

  void _startStatusTimer(int everySec) {
    _statusTimer?.cancel();
    final interval = Duration(seconds: everySec < 5 ? 5 : everySec);
    _statusTimer = Timer.periodic(interval, (_) {
      sendStatus();
    });
  }

  void _cleanupAfterClose() {
    _statusTimer?.cancel();
    _statusTimer = null;
    _socket = null;
  }

  void _emitState(HubConnectionState state, {String? error}) {
    _onStateChanged(state, error: error);
  }

  void _emitDisconnectedOnce() {
    if (_didEmitDisconnected) {
      return;
    }
    _didEmitDisconnected = true;
    _emitState(HubConnectionState.disconnected);
  }

  String _buildWsUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    final uri = Uri.parse(trimmed);

    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final host = uri.host;
    final port = uri.hasPort ? ':${uri.port}' : '';

    return '$scheme://$host$port/api/cloud/hub/ws';
  }

  Future<void> _syncServerTimeOffset(String baseUrl) async {
    try {
      final uri = Uri.parse(baseUrl.trim());
      final pingUri = uri.replace(path: '/', query: '');
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(pingUri);
      request.followRedirects = true;
      final response = await request.close();
      final dateHeader = response.headers.value(HttpHeaders.dateHeader);
      await response.drain<void>();
      client.close(force: true);

      if (dateHeader == null || dateHeader.trim().isEmpty) {
        _onWarning('Server Date header is missing, using local clock');
        _serverTimeOffsetSec = 0;
        return;
      }

      final serverDate = HttpDate.parse(dateHeader);
      final serverSec = serverDate.millisecondsSinceEpoch ~/ 1000;
      final localSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      _serverTimeOffsetSec = serverSec - localSec;

      _onInfo(
        'Server time synchronized',
        details: 'date=$dateHeader offsetSec=$_serverTimeOffsetSec',
      );
    } catch (error) {
      _serverTimeOffsetSec = 0;
      _onWarning(
        'Server time sync failed, using local clock',
        details: '$error',
      );
    }
  }

  int _nowServerAlignedSec() {
    final localSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return localSec + _serverTimeOffsetSec;
  }

  String _computeSignature({
    required String key,
    required String ts,
    required String nonce,
    required Map<String, dynamic> body,
  }) {
    final payload = '$ts.$nonce.${jsonEncode(body)}';
    final hmac = Hmac(sha256, utf8.encode(key));
    final digest = hmac.convert(utf8.encode(payload));
    return digest.toString();
  }

  String _nonceHex() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final output = StringBuffer();
    for (final byte in bytes) {
      output.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return output.toString();
  }
}
