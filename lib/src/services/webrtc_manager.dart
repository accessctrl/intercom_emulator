import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcManager {
  MediaStream? _localStream;
  RTCVideoRenderer? _localRenderer;
  RTCPeerConnection? _peerConnection;
  Future<void>? _ensurePeerFuture;
  final List<RTCIceCandidate> _pendingRemoteIce = <RTCIceCandidate>[];

  bool get isInitialized => _localStream != null;
  RTCVideoRenderer? get localRenderer => _localRenderer;
  MediaStreamTrack? get localVideoTrack {
    final stream = _localStream;
    if (stream == null) {
      return null;
    }
    final tracks = stream.getVideoTracks();
    if (tracks.isEmpty) {
      return null;
    }
    return tracks.first;
  }

  Future<void> ensurePeerConnection({
    required List<Map<String, dynamic>> iceServers,
    required Future<void> Function(Map<String, dynamic> candidate) onCandidate,
    required void Function(RTCPeerConnectionState state) onConnectionState,
    required void Function(RTCIceConnectionState state) onIceConnectionState,
  }) async {
    await initializePreview();

    if (_peerConnection != null) {
      return;
    }

    final inFlight = _ensurePeerFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final createFuture = _createPeerConnection(
      iceServers: iceServers,
      onCandidate: onCandidate,
      onConnectionState: onConnectionState,
      onIceConnectionState: onIceConnectionState,
    );
    _ensurePeerFuture = createFuture;
    try {
      await createFuture;
    } finally {
      if (identical(_ensurePeerFuture, createFuture)) {
        _ensurePeerFuture = null;
      }
    }
  }

  Future<void> _createPeerConnection({
    required List<Map<String, dynamic>> iceServers,
    required Future<void> Function(Map<String, dynamic> candidate) onCandidate,
    required void Function(RTCPeerConnectionState state) onConnectionState,
    required void Function(RTCIceConnectionState state) onIceConnectionState,
  }) async {
    if (_peerConnection != null) {
      return;
    }

    _peerConnection = await createPeerConnection(
      <String, dynamic>{
        'sdpSemantics': 'unified-plan',
        'iceServers': iceServers,
      },
      <String, dynamic>{
        'mandatory': <String, dynamic>{},
        'optional': <Map<String, dynamic>>[
          <String, dynamic>{'DtlsSrtpKeyAgreement': true},
        ],
      },
    );

    for (final track in _localStream!.getTracks()) {
      await _addTrackIfMissing(_peerConnection!, track, _localStream!);
    }

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      final value = candidate.candidate;
      if (value == null || value.trim().isEmpty) {
        return;
      }
      onCandidate(<String, dynamic>{
        'candidate': value,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    _peerConnection!.onConnectionState = onConnectionState;
    _peerConnection!.onIceConnectionState = onIceConnectionState;
  }

  Future<void> _addTrackIfMissing(
    RTCPeerConnection pc,
    MediaStreamTrack track,
    MediaStream stream,
  ) async {
    final senders = await pc.getSenders();
    final alreadyAdded = senders.any((sender) => sender.track?.id == track.id);
    if (alreadyAdded) {
      return;
    }

    try {
      await pc.addTrack(track, stream);
    } catch (error) {
      final message = '$error';
      if (message.contains('Sender already exists')) {
        return;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createOffer() async {
    final pc = _peerConnection;
    if (pc == null) {
      throw StateError('PeerConnection is not initialized');
    }

    final offer = await pc.createOffer(<String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
      'voiceActivityDetection': true,
    });
    await pc.setLocalDescription(offer);
    return <String, dynamic>{'type': offer.type, 'sdp': offer.sdp};
  }

  Future<Map<String, dynamic>> createAnswerForOffer(String sdp) async {
    final pc = _peerConnection;
    if (pc == null) {
      throw StateError('PeerConnection is not initialized');
    }

    final applied = await _applyRemoteDescriptionWithFallback(
      type: 'offer',
      sdp: sdp,
    );
    if (!applied) {
      throw StateError('Unable to apply remote offer');
    }

    final answer = await pc.createAnswer(<String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await pc.setLocalDescription(answer);
    await _flushPendingRemoteIce();
    return <String, dynamic>{'type': answer.type, 'sdp': answer.sdp};
  }

  Future<void> applyAnswer(String sdp) async {
    final pc = _peerConnection;
    if (pc == null) {
      throw StateError('PeerConnection is not initialized');
    }

    final applied = await _applyRemoteDescriptionWithFallback(
      type: 'answer',
      sdp: sdp,
    );
    if (!applied) {
      throw StateError('Unable to apply remote answer');
    }
    await _flushPendingRemoteIce();
  }

  Future<void> addRemoteCandidate({
    required String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    final pc = _peerConnection;
    if (pc == null) {
      throw StateError('PeerConnection is not initialized');
    }

    final next = RTCIceCandidate(candidate, sdpMid, sdpMLineIndex);
    if (!await _hasRemoteDescription()) {
      _pendingRemoteIce.add(next);
      return;
    }

    await pc.addCandidate(next);
  }

  Future<void> endPeerConnection() async {
    final pc = _peerConnection;
    _peerConnection = null;
    _pendingRemoteIce.clear();
    if (pc == null) {
      return;
    }

    try {
      await pc.close();
    } catch (_) {
      // no-op
    }
    await pc.dispose();
  }

  Future<void> initializePreview() async {
    if (_localRenderer == null) {
      _localRenderer = RTCVideoRenderer();
      await _localRenderer!.initialize();
    }

    _localStream ??= await navigator.mediaDevices.getUserMedia(
      <String, dynamic>{'audio': true, 'video': true},
    );

    _localRenderer!.srcObject = _localStream;
  }

  Future<void> dispose() async {
    await endPeerConnection();

    final stream = _localStream;
    _localStream = null;
    final renderer = _localRenderer;
    _localRenderer = null;

    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
    }

    if (stream == null) {
      return;
    }
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  Future<bool> _hasRemoteDescription() async {
    final pc = _peerConnection;
    if (pc == null) return false;
    try {
      final remote = await pc.getRemoteDescription();
      return remote != null && (remote.sdp ?? '').trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _flushPendingRemoteIce() async {
    final pc = _peerConnection;
    if (pc == null || _pendingRemoteIce.isEmpty) {
      return;
    }

    final toApply = List<RTCIceCandidate>.from(_pendingRemoteIce);
    _pendingRemoteIce.clear();
    for (final item in toApply) {
      await pc.addCandidate(item);
    }
  }

  Future<bool> _applyRemoteDescriptionWithFallback({
    required String type,
    required String sdp,
  }) async {
    final pc = _peerConnection;
    if (pc == null) {
      return false;
    }

    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
      return true;
    } catch (_) {
      // Retry with normalized SDP for compatibility with strict parsers.
    }

    final normalizedSdp = _normalizeRemoteSdp(sdp);
    if (normalizedSdp == sdp) {
      return false;
    }

    try {
      await pc.setRemoteDescription(RTCSessionDescription(normalizedSdp, type));
      return true;
    } catch (_) {
      return false;
    }
  }

  String _normalizeRemoteSdp(String sdp) {
    final noNulls = sdp.replaceAll('\u0000', '');
    final normalizedNewlines = noNulls
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    final filteredLines = normalizedNewlines
        .split('\n')
        .map((line) => line.trimRight())
        .where((line) => line.isNotEmpty)
        .map(_normalizeSdpLine)
        .where((line) => line.isNotEmpty)
        .where(
          (line) =>
              !line.startsWith('a=ssrc:') && !line.startsWith('a=ssrc-group:'),
        )
        .toList(growable: false);

    return '${filteredLines.join('\r\n')}\r\n';
  }

  String _normalizeSdpLine(String line) {
    if (line.startsWith('m=video ')) {
      final parts = line.split(' ');
      if (parts.length > 3) {
        final header = parts.sublist(0, 3);
        final payloads = parts
            .sublist(3)
            .where((pt) => pt != '107' && pt != '45')
            .toList(growable: false);
        return <String>[...header, ...payloads].join(' ');
      }
    }

    if (line.startsWith('a=rtpmap:107 ulpfec/90000') ||
        line.startsWith('a=rtpmap:45 flexfec-03/90000') ||
        line.startsWith('a=rtcp-fb:45 ') ||
        line.startsWith('a=fmtp:45 ')) {
      return '';
    }

    return line;
  }
}
