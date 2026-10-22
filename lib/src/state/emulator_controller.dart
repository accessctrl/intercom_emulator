import 'dart:async';
import 'dart:convert';

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
const List<Map<String, dynamic>> _defaultIceServers = [
  {
    'urls': ['stun:stun.l.google.com:19302'],
  },
];

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
  final Set<String> _snapshotEmittedCallIds = <String>{};

  int _callSecondsRemaining = 0;
  int get callSecondsRemaining => _callSecondsRemaining;

  String _activeCallId = '';
  List<Map<String, dynamic>> _activeIceServers = _defaultIceServers;

  bool get isPreviewInitialized => _webRtcManager.isInitialized;
  RTCVideoRenderer? get localPreviewRenderer => _webRtcManager.localRenderer;

  bool get canStartCall =>
      _dialedApartment.isNotEmpty && _callState == IntercomCallState.idle;
  bool get canCancelCall => _callState != IntercomCallState.idle;

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
    await _webRtcManager.endPeerConnection();
    _activeCallId = '';
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

  void clearDialedApartment() {
    if (_callState != IntercomCallState.idle) {
      return;
    }
    if (_dialedApartment.isEmpty) {
      return;
    }

    _clearDialedApartment();
    _markAction('Apartment number cleared');
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

    // Ensure a clean peer state for every new outgoing call.
    await _webRtcManager.endPeerConnection();
    _activeCallId = '';

    final callId =
      'call-${DateTime.now().millisecondsSinceEpoch}-${_config.serial.trim()}-$_dialedApartment';
    _activeCallId = callId;

    _callState = IntercomCallState.calling;
    _startCallLifecycle();

    final sent = _client.sendEvent(
      eventType: 'intercom_call_start',
      body: <String, dynamic>{
        'call_id': callId,
        'apartment': _dialedApartment,
        'device_serial': _config.serial.trim(),
      },
    );

    // Snapshot must be captured at dial/start time even if nobody answers.
    unawaited(_emitSnapshotAtCallStart(callId));

    final message = sent
        ? 'Call started for apartment $_dialedApartment'
        : 'Call prepared for apartment $_dialedApartment (offline websocket)';
    _markAction(message);
    notifyListeners();
    return _lastActionMessage;
  }

  Future<void> _emitSnapshotAtCallStart(String callId) async {
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty) {
      return;
    }

    await _emitSnapshotForCall(normalizedCallId);

    // Retry once to reduce race risk if backend session insert lags behind.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (_activeCallId.trim() != normalizedCallId) {
      return;
    }
    await _emitSnapshotForCall(normalizedCallId);
  }

  Future<String> cancelCurrentCall() async {
    if (_callState == IntercomCallState.idle) {
      return _lastActionMessage;
    }

    final callId = _activeCallId;
    if (callId.isNotEmpty) {
      _client.sendEvent(
        eventType: 'intercom_webrtc_signal',
        body: <String, dynamic>{
          'call_id': callId,
          'signal_type': 'hangup',
          'signal': const <String, dynamic>{'reason': 'cancel'},
          'device_id': _config.serial.trim(),
        },
      );
    }

    _client.sendEvent(
      eventType: 'intercom_call_end',
      body: <String, dynamic>{
        'call_id': callId,
        'reason': 'cancel',
        'device_serial': _config.serial.trim(),
      },
    );

    await _webRtcManager.endPeerConnection();
    _activeCallId = '';
    _stopCallLifecycle(resetState: true);
    _markAction('Call canceled by emulator user');
    notifyListeners();
    return _lastActionMessage;
  }

  Future<void> _ensurePeerForCall({
    required String callId,
    List<Map<String, dynamic>>? iceServers,
  }) async {
    if (callId.isNotEmpty &&
        _activeCallId.isNotEmpty &&
        _activeCallId != callId) {
      await _webRtcManager.endPeerConnection();
      _activeCallId = '';
    }

    if (callId.isNotEmpty) {
      _activeCallId = callId;
    }

    final nextIceServers = (iceServers != null && iceServers.isNotEmpty)
        ? iceServers
        : _activeIceServers;
    _activeIceServers = nextIceServers.isNotEmpty
        ? nextIceServers
        : _defaultIceServers;

    await _webRtcManager.ensurePeerConnection(
      iceServers: _activeIceServers,
      onCandidate: (candidate) async {
        if (_activeCallId.isEmpty) return;
        final sent = _client.sendEvent(
          eventType: 'intercom_webrtc_signal',
          body: <String, dynamic>{
            'call_id': _activeCallId,
            'signal_type': 'ice_candidate',
            'signal': candidate,
            'device_id': _config.serial.trim(),
          },
        );
        if (!sent) {
          _handleWarning(
            'ICE candidate send skipped',
            details: 'callId=$_activeCallId',
          );
        }
      },
      onConnectionState: (state) {
        _handleInfo(
          'Peer connection state',
          details: '$state callId=$_activeCallId',
        );
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _callState = IntercomCallState.connected;
          _stopCallLifecycle(resetState: false);
          _client.sendEvent(
            eventType: 'intercom_webrtc_signal',
            body: <String, dynamic>{
              'call_id': _activeCallId,
              'signal_type': 'media_ready',
              'signal': const <String, dynamic>{'state': 'connected'},
              'device_id': _config.serial.trim(),
            },
          );
          notifyListeners();
        }
      },
      onIceConnectionState: (state) {
        _handleInfo(
          'ICE connection state',
          details: '$state callId=$_activeCallId',
        );
      },
    );
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

    try {
      await _applyRuntimeState(command);
    } catch (error, stack) {
      _handleWarning(
        'Runtime state handler failed',
        details: 'command=${command.id} type=${command.type} error=$error',
      );
      _logger.warning('Runtime state stacktrace', details: stack.toString());
    }

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

    if (type == 'webrtc_signal') {
      await _handleWebrtcSignalCommand(command);
      return;
    }

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
      await _webRtcManager.endPeerConnection();
      _activeCallId = '';
      _markAction('Call ended by remote side');
      return;
    }

    if (type == 'monitor_start' || type == 'view_start') {
      await initializeLocalMedia();
      final payload = command.payload;
      final callId =
          '${payload['call_id'] ?? payload['callId'] ?? payload['request_id'] ?? ''}'
              .trim();
      if (callId.isNotEmpty) {
        await _emitSnapshotForCall(callId);
      }
      _markAction(
        callId.isEmpty
            ? 'Remote monitor session started'
            : 'Remote monitor session started callId=$callId',
      );
      return;
    }
  }

  Future<void> _emitSnapshotForCall(String callId) async {
    final serial = _config.serial.trim();
    final normalizedCallId = callId.trim();
    if (serial.isEmpty || normalizedCallId.isEmpty) {
      return;
    }

    if (_snapshotEmittedCallIds.contains(normalizedCallId)) {
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final seed = base64Url.encode(utf8.encode('$serial:$normalizedCallId:$nowMs'));
    final previewUrl =
        'https://snapshot.local/intercom/$serial/$normalizedCallId/preview.jpg?s=$seed';
    final fullUrl =
        'https://snapshot.local/intercom/$serial/$normalizedCallId/full.jpg?s=$seed';

    final sent = _client.sendEvent(
      eventType: 'intercom_snapshot',
      body: <String, dynamic>{
        'call_id': normalizedCallId,
        'preview_url': previewUrl,
        'full_url': fullUrl,
        'device_serial': serial,
      },
    );

    if (sent) {
      _snapshotEmittedCallIds.add(normalizedCallId);
      _handleInfo(
        'Snapshot event emitted',
        details: 'callId=$normalizedCallId serial=$serial',
      );
    } else {
      _handleWarning(
        'Snapshot event skipped',
        details: 'offline websocket callId=$normalizedCallId',
      );
    }
  }

  Future<void> _handleWebrtcSignalCommand(HubCommand command) async {
    final payload = command.payload;
    final callId =
        '${payload['call_id'] ?? payload['callId'] ?? payload['request_id'] ?? ''}'
            .trim();
    final signalType =
        '${payload['signal_type'] ?? payload['signalType'] ?? payload['type'] ?? ''}'
            .trim()
            .toLowerCase();
    final rawSignal = payload['signal'];
    final signal = rawSignal is Map
        ? Map<String, dynamic>.from(rawSignal)
        : <String, dynamic>{};
    final rawIceServers = signal['ice_servers'];
    final iceServers = rawIceServers is List
        ? rawIceServers
              .whereType<Map>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList(growable: false)
        : const <Map<String, dynamic>>[];

    if (callId.isEmpty || signalType.isEmpty) {
      _handleWarning(
        'Ignoring invalid webrtc_signal command',
        details: 'command=${command.id} callId=$callId signalType=$signalType',
      );
      return;
    }

    if (signalType == 'unlock') {
      _pulseDoorUnlock();
      _markAction('Door unlock signal received callId=$callId');
      return;
    }

    if (signalType == 'offer') {
      // Always reset peer before handling a new offer to avoid stale failed ICE.
      await _webRtcManager.endPeerConnection();
      _activeCallId = '';
    }

    await _ensurePeerForCall(callId: callId, iceServers: iceServers);

    if (signalType == 'app_accept') {
      // App side is the offerer for this flow. Avoid glare by waiting for offer.
      _markAction('App accepted call; waiting for WebRTC offer callId=$callId');
      return;
    }

    if (signalType == 'offer') {
      final sdp = '${signal['sdp'] ?? ''}'.trim();
      if (sdp.isEmpty) {
        _handleWarning('Ignoring offer without SDP', details: 'callId=$callId');
        return;
      }

      Map<String, dynamic> answer;
      try {
        answer = await _webRtcManager.createAnswerForOffer(sdp);
      } catch (error) {
        _handleWarning(
          'Failed to create answer for offer',
          details: 'callId=$callId error=$error',
        );
        return;
      }
      final sent = _client.sendEvent(
        eventType: 'intercom_webrtc_signal',
        body: <String, dynamic>{
          'call_id': callId,
          'signal_type': 'answer',
          'signal': answer,
          'device_id': _config.serial.trim(),
        },
      );

      _callState = IntercomCallState.connected;
      _stopCallLifecycle(resetState: false);
      _markAction(
        sent
            ? 'WebRTC answer sent callId=$callId'
            : 'WebRTC answer skipped (offline) callId=$callId',
      );
      notifyListeners();
      return;
    }

    if (signalType == 'answer') {
      final sdp = '${signal['sdp'] ?? ''}'.trim();
      if (sdp.isEmpty) {
        _handleWarning(
          'Ignoring answer without SDP',
          details: 'callId=$callId',
        );
        return;
      }

      try {
        await _webRtcManager.applyAnswer(sdp);
      } catch (error) {
        _handleWarning(
          'Failed to apply remote answer',
          details: 'callId=$callId error=$error',
        );
        return;
      }
      _callState = IntercomCallState.connected;
      _stopCallLifecycle(resetState: false);
      _markAction('WebRTC answer applied callId=$callId');
      notifyListeners();
      return;
    }

    if (signalType == 'ice_candidate') {
      final candidate = '${signal['candidate'] ?? ''}'.trim();
      if (candidate.isEmpty) {
        _handleWarning(
          'Ignoring empty ICE candidate',
          details: 'callId=$callId',
        );
        return;
      }
      final sdpMidRaw = signal['sdpMid'];
      final sdpMLineIndexRaw = signal['sdpMLineIndex'];
      final sdpMid = sdpMidRaw == null ? null : '$sdpMidRaw';
      final sdpMLineIndex = sdpMLineIndexRaw is int
          ? sdpMLineIndexRaw
          : int.tryParse('$sdpMLineIndexRaw');
      try {
        await _webRtcManager.addRemoteCandidate(
          candidate: candidate,
          sdpMid: sdpMid,
          sdpMLineIndex: sdpMLineIndex,
        );
      } catch (error) {
        _handleWarning(
          'Failed to apply ICE candidate',
          details: 'callId=$callId error=$error',
        );
      }
      return;
    }

    if (signalType == 'hangup' || signalType == 'ended') {
      await _webRtcManager.endPeerConnection();
      _activeCallId = '';
      _stopCallLifecycle(resetState: true);
      _markAction(
        'WebRTC call ended by signal: type=$signalType callId=$callId',
      );
      notifyListeners();
      return;
    }

    _markAction('WebRTC signal received: type=$signalType callId=$callId');
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

    _callTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
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
        await _webRtcManager.endPeerConnection();
        _activeCallId = '';
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
      _activeCallId = '';
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
