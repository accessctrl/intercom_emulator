import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/hub_command.dart';
import '../models/hub_config.dart';
import '../services/app_config_store.dart';
import '../services/app_logger.dart';
import '../services/command_emulator.dart';
import '../services/hub_ws_client.dart';
import '../services/webrtc_manager.dart';

enum IntercomCallState { idle, calling, connected }

const int _outgoingCallDurationSec = 30;

class EmulatorController extends ChangeNotifier {
  EmulatorController({
    AppConfigStore? configStore,
    AppLogger? logger,
    CommandEmulator? commandEmulator,
    WebRtcManager? webRtcManager,
  }) : _configStore = configStore ?? AppConfigStore(),
       _logger = logger ?? AppLogger(),
       _commandEmulator = commandEmulator ?? CommandEmulator(),
       _webRtcManager = webRtcManager ?? WebRtcManager();

  final AppConfigStore _configStore;
  final AppLogger _logger;
  final CommandEmulator _commandEmulator;
  final WebRtcManager _webRtcManager;

  late final HubWsClient _client = HubWsClient(
    onInfo: _handleInfo,
    onWarning: _handleWarning,
    onError: _handleError,
    onStateChanged: _onConnectionStateChanged,
    onCommand: _onCommand,
  );

  AppLogger get logger => _logger;

  HubConfig _config = HubConfig.defaults();
  HubConfig get config => _config;

  HubConnectionState _connectionState = HubConnectionState.disconnected;
  HubConnectionState get connectionState => _connectionState;

  String? _lastError;
  String? get lastError => _lastError;

  int _commandsHandled = 0;
  int get commandsHandled => _commandsHandled;

  int _unsupportedCommands = 0;
  int get unsupportedCommands => _unsupportedCommands;

  String _lastActionMessage = 'No actions yet';
  String get lastActionMessage => _lastActionMessage;

  String _lastEventMessage = 'No server events yet';
  String get lastEventMessage => _lastEventMessage;

  String _dialedApartment = '';
  String get dialedApartment => _dialedApartment;

  IntercomCallState _callState = IntercomCallState.idle;
  IntercomCallState get callState => _callState;

  bool _doorUnlocked = false;
  bool get isDoorUnlocked => _doorUnlocked;

  Timer? _doorUnlockTimer;
  Timer? _callTimer;
  Timer? _ringSignalTimer;

  int _callSecondsRemaining = 0;
  int get callSecondsRemaining => _callSecondsRemaining;

  bool get isPreviewInitialized => _webRtcManager.isInitialized;
  RTCVideoRenderer? get localPreviewRenderer => _webRtcManager.localRenderer;

  bool get canStartCall =>
      _dialedApartment.isNotEmpty && _callState == IntercomCallState.idle;

  String get deviceLabel {
    final serial = _config.serial.trim();
    if (serial.isEmpty) {
      return 'UNKNOWN';
    }
    return serial.toUpperCase();
  }

  bool get isConnected =>
      _connectionState == HubConnectionState.connected ||
      _connectionState == HubConnectionState.authenticated;

  Future<String> toggleConnection() {
    if (isConnected || _connectionState == HubConnectionState.connecting) {
      return disconnect();
    }
    return connect();
  }

  Future<void> load() async {
    final loaded = await _configStore.load();
    final defaults = HubConfig.defaults();
    _config = loaded.withRequiredFallbacks(defaults);

    if (_config.toJson().toString() != loaded.toJson().toString()) {
      await _configStore.save(_config);
    }

    _handleInfo('Emulator controller initialized');
    _markAction('Configuration loaded');
    notifyListeners();
  }

  Future<void> saveConfig(HubConfig config) async {
    _config = config;
    await _configStore.save(config);
    _handleInfo('Configuration saved');
    _markAction('Settings saved');
    notifyListeners();
  }

  Future<String> connect() async {
    if (!_config.isValid) {
      final missing = _config.missingRequiredFields;
      _lastError =
          'Configuration is incomplete. Missing: ${missing.join(', ')}';
      if (missing.length == 1 && missing.first == 'hubKey') {
        _lastError = 'Configuration is incomplete. Missing: hubKey. Start with --dart-define-from-file=.secrets.local.json';
      }
      _markAction('Connect failed: $_lastError');
      _handleError(_lastError!);
      notifyListeners();
      return _lastActionMessage;
    }

    _lastError = null;
    _handleInfo(
      'Connect parameters',
      details:
          'baseUrl=${_config.baseUrl.trim()} family=${_config.family.trim().toLowerCase()} serial=${_config.serial.trim()} hubKey=${_maskKey(_config.hubKey)} intervalSec=${_config.statusIntervalSec}',
    );
    if (_config.family.trim().toLowerCase() == 'igch') {
      _handleWarning(
        'IGCH identity in use',
        details: 'If family+serial match a real staging hub, this emulator can replace its websocket session.',
      );
    }
    _markAction('Connect requested');
    notifyListeners();

    try {
      await _client.connect(_config);
      _markAction('Connect request sent');
    } catch (error) {
      _lastError = '$error';
      _markAction('Connect failed: $error');
      notifyListeners();
    }
    return _lastActionMessage;
  }

  Future<String> disconnect() async {
    await _client.disconnect();
    _stopCallLifecycle(resetState: true);
    _connectionState = HubConnectionState.disconnected;
    _markAction('Disconnected');
    notifyListeners();
    return _lastActionMessage;
  }

  void appendDialCharacter(String character) {
    if (_callState != IntercomCallState.idle) {
      return;
    }
    if (character.isEmpty) {
      return;
    }
    if (int.tryParse(character) == null) {
      return;
    }
    if (_dialedApartment.length >= 12) {
      _markAction('Apartment number max length reached');
      notifyListeners();
      return;
    }
    _dialedApartment = '$_dialedApartment$character';
    _markAction('Dialed apartment: $_dialedApartment');
    notifyListeners();
  }

  void removeLastDialCharacter() {
    if (_callState != IntercomCallState.idle) {
      return;
    }
    if (_dialedApartment.isEmpty) {
      return;
    }
    _dialedApartment = _dialedApartment.substring(
      0,
      _dialedApartment.length - 1,
    );
    _markAction(
      _dialedApartment.isEmpty
          ? 'Apartment number cleared'
          : 'Dialed apartment: $_dialedApartment',
    );
    notifyListeners();
  }

  Future<String> startCall() async {
    if (!canStartCall) {
      final reason = _dialedApartment.isEmpty
          ? 'apartment number is empty'
          : 'another call is already in progress';
      _markAction('Call not started: $reason');
      notifyListeners();
      return _lastActionMessage;
    }

    await initializeLocalMedia();
    if (!isPreviewInitialized) {
      _markAction('Call not started: camera/microphone permission required');
      notifyListeners();
      return _lastActionMessage;
    }

    _callState = IntercomCallState.calling;
    _startCallLifecycle();

    final sent = _client.sendEvent(
      eventType: 'intercom_call_start',
      body: <String, dynamic>{
        'apartment': _dialedApartment,
        'device_serial': _config.serial.trim(),
      },
    );

    final message = sent
        ? 'Call started for apartment $_dialedApartment'
        : 'Call prepared for apartment $_dialedApartment (offline websocket)';
    _markAction(message);
    notifyListeners();
    return _lastActionMessage;
  }

  String sendStatusNow() {
    final ok = _client.sendStatus();
    final msg = ok ? 'Status sent' : 'Status not sent: no active websocket';
    _markAction(msg);
    return msg;
  }

  String requestPull() {
    final ok = _client.requestPull();
    final msg = ok ? 'Pull requested' : 'Pull not sent: no active websocket';
    _markAction(msg);
    return msg;
  }

  Future<void> initializeLocalMedia() async {
    try {
      await _webRtcManager.initializePreview();
      _markAction('Local media initialized');
      _handleInfo('Local media initialized (camera/microphone)');
    } catch (error) {
      _markAction('Local media initialization failed');
      _handleWarning('Local media initialization failed', details: '$error');
    }
  }

  void clearLogs() {
    _logger.clear();
  }

  Future<void> _onCommand(HubCommand command) async {
    _commandsHandled += 1;
    _logger.info(
      'Command received',
      details: '${command.type} id=${command.id}',
    );

    await _applyRuntimeState(command);

    final result = await _commandEmulator.execute(command);
    if (result.status == 'unsupported') {
      _unsupportedCommands += 1;
      _logger.warning(
        'Command unsupported by emulator',
        details: '${command.type} id=${command.id}',
      );
    }

    _client.sendCommandResults(<Map<String, dynamic>>[result.toJson()]);
    _markAction('Command result sent for ${command.id} (${result.status})');
    notifyListeners();
  }

  void _onConnectionStateChanged(HubConnectionState state, {String? error}) {
    _connectionState = state;
    if (state == HubConnectionState.disconnected ||
        state == HubConnectionState.failed) {
      _stopCallLifecycle(resetState: true);
    }
    _markAction('Connection state: ${_stateToText(state)}');
    if (error != null && error.isNotEmpty) {
      _lastError = error;
    }
    notifyListeners();
  }

  void _handleInfo(String message, {String? details}) {
    _lastEventMessage = details == null || details.isEmpty
        ? message
        : '$message | $details';
    _logger.info(message, details: details);
    notifyListeners();
  }

  void _handleWarning(String message, {String? details}) {
    _lastEventMessage = details == null || details.isEmpty
        ? 'WARN: $message'
        : 'WARN: $message | $details';
    _logger.warning(message, details: details);
    notifyListeners();
  }

  void _handleError(String message, {String? details}) {
    _lastEventMessage = details == null || details.isEmpty
        ? 'ERROR: $message'
        : 'ERROR: $message | $details';
    _logger.error(message, details: details);
    notifyListeners();
  }

  void _markAction(String message) {
    _lastActionMessage = '${DateTime.now().toIso8601String()} | $message';
    _logger.info('Action', details: message);
  }

  Future<void> _applyRuntimeState(HubCommand command) async {
    final type = command.type.trim().toLowerCase();

    if (type == 'door_open' || type == 'unlock') {
      _pulseDoorUnlock();
      _markAction('Door unlock command received');
      return;
    }

    if (type == 'call_answered' ||
        type == 'call_accept' ||
        type == 'audio_start' ||
        type == 'voice_start') {
      _callState = IntercomCallState.connected;
      _stopCallLifecycle(resetState: false);
      _markAction('Two-way audio started by remote side');
      await SystemSound.play(SystemSoundType.click);
      return;
    }

    if (type == 'call_declined' ||
        type == 'call_end' ||
        type == 'hangup' ||
        type == 'audio_stop' ||
        type == 'voice_stop') {
      _stopCallLifecycle(resetState: true);
      _markAction('Call ended by remote side');
      return;
    }

    if (type == 'monitor_start' || type == 'view_start') {
      await initializeLocalMedia();
      _markAction('Remote monitor session started');
      return;
    }
  }

  void _pulseDoorUnlock() {
    _doorUnlockTimer?.cancel();
    _doorUnlocked = true;
    notifyListeners();
    SystemSound.play(SystemSoundType.alert);
    _doorUnlockTimer = Timer(const Duration(seconds: 3), () {
      _doorUnlocked = false;
      notifyListeners();
    });
  }

  void _startCallLifecycle() {
    _callTimer?.cancel();
    _ringSignalTimer?.cancel();

    _callSecondsRemaining = _outgoingCallDurationSec;
    _playRingingTick();

    _ringSignalTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_callState == IntercomCallState.calling) {
        _playRingingTick();
      }
    });

    _callTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_callState != IntercomCallState.calling) {
        timer.cancel();
        return;
      }

      if (_callSecondsRemaining <= 1) {
        timer.cancel();
        _ringSignalTimer?.cancel();
        final apartment = _dialedApartment;
        _callSecondsRemaining = 0;
        _callState = IntercomCallState.idle;
        _client.sendEvent(
          eventType: 'intercom_call_timeout',
          body: <String, dynamic>{
            'apartment': apartment,
            'device_serial': _config.serial.trim(),
          },
        );
        _clearDialedApartment();
        _markAction('Call timeout (${_outgoingCallDurationSec}s)');
        notifyListeners();
        return;
      }

      _callSecondsRemaining -= 1;
      notifyListeners();
    });
  }

  void _stopCallLifecycle({required bool resetState}) {
    _callTimer?.cancel();
    _callTimer = null;
    _ringSignalTimer?.cancel();
    _ringSignalTimer = null;

    _callSecondsRemaining = 0;
    if (resetState) {
      _callState = IntercomCallState.idle;
      _clearDialedApartment();
    }
  }

  void _clearDialedApartment() {
    _dialedApartment = '';
  }

  void _playRingingTick() {
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.selectionClick();
  }

  String _stateToText(HubConnectionState state) {
    return switch (state) {
      HubConnectionState.disconnected => 'disconnected',
      HubConnectionState.connecting => 'connecting',
      HubConnectionState.connected => 'connected',
      HubConnectionState.authenticated => 'authenticated',
      HubConnectionState.closing => 'closing',
      HubConnectionState.failed => 'failed',
    };
  }

  String _maskKey(String value) {
    final key = value.trim();
    if (key.isEmpty) {
      return '<empty>';
    }
    if (key.length <= 6) {
      return '***';
    }
    return '${key.substring(0, 2)}***${key.substring(key.length - 2)}';
  }

  @override
  void dispose() {
    _doorUnlockTimer?.cancel();
    _callTimer?.cancel();
    _ringSignalTimer?.cancel();
    _client.disconnect();
    _webRtcManager.dispose();
    _logger.dispose();
    super.dispose();
  }
}
