import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcManager {
  MediaStream? _localStream;

  bool get isInitialized => _localStream != null;

  Future<void> initializePreview() async {
    _localStream ??= await navigator.mediaDevices.getUserMedia(
      <String, dynamic>{'audio': true, 'video': true},
    );
  }

  Future<void> dispose() async {
    final stream = _localStream;
    _localStream = null;
    if (stream == null) {
      return;
    }
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }
}
