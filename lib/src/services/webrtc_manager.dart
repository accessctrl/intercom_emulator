import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcManager {
  MediaStream? _localStream;
  RTCVideoRenderer? _localRenderer;
  RTCPeerConnection? _peerConnection;

  bool get isInitialized => _localStream != null;
  RTCVideoRenderer? get localRenderer => _localRenderer;

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
      await _peerConnection!.addTrack(track, _localStream!);
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

  Future<Map<String, dynamic>> createOffer() async {
    final pc = _peerConnection;
    if (pc == null) {
      throw StateError('PeerConnection is not initialized');
    }

    final offer = await pc.createOffer(<String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
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

    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final answer = await pc.createAnswer(<String, dynamic>{
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    await pc.setLocalDescription(answer);
    return <String, dynamic>{'type': answer.type, 'sdp': answer.sdp};
  }

  Future<void> applyAnswer(String sdp) async {
    final pc = _peerConnection;
    if (pc == null) {
      throw StateError('PeerConnection is not initialized');
    }

    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
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

    await pc.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));
  }

  Future<void> endPeerConnection() async {
    final pc = _peerConnection;
    _peerConnection = null;
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
}
