import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcManager {
  MediaStream? _localStream;
  RTCVideoRenderer? _localRenderer;

  bool get isInitialized => _localStream != null;
  RTCVideoRenderer? get localRenderer => _localRenderer;

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
