import '../models/hub_command.dart';
import 'door_command_handler.dart';

class CommandExecutionResult {
  const CommandExecutionResult({
    required this.commandId,
    required this.status,
    this.error,
    this.responseHex,
    this.msgType,
  });

  final String commandId;
  final String status;
  final String? error;
  final String? responseHex;
  final int? msgType;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'command_id': commandId,
      'status': status,
      if (error != null && error!.isNotEmpty) 'error': error,
      if (responseHex != null && responseHex!.isNotEmpty)
        'response_hex': responseHex,
      if (msgType != null) 'msg_type': msgType,
    };
  }
}

class CommandEmulator {
  CommandEmulator({DoorCommandHandler? doorHandler})
    : _doorHandler = doorHandler ?? DoorCommandHandler();

  final DoorCommandHandler _doorHandler;

  Future<CommandExecutionResult> execute(HubCommand command) async {
    final type = command.type.trim().toLowerCase();

    if (type == 'door_open' || type == 'unlock') {
      final doorResult = await _doorHandler.execute(command);
      return CommandExecutionResult(
        commandId: command.id,
        status: '${doorResult['status'] ?? 'error'}',
        error: doorResult['error'] as String?,
        responseHex: doorResult['response_hex'] as String?,
        msgType: _readMsgType(command),
      );
    }

    if (type == 'call_answered' ||
        type == 'call_accept' ||
        type == 'audio_start' ||
        type == 'voice_start' ||
        type == 'webrtc_signal' ||
        type == 'call_declined' ||
        type == 'call_end' ||
        type == 'hangup' ||
        type == 'audio_stop' ||
        type == 'voice_stop' ||
        type == 'monitor_start' ||
        type == 'view_start' ||
        type == 'monitor_stop' ||
        type == 'view_stop') {
      return CommandExecutionResult(
        commandId: command.id,
        status: 'ok',
        responseHex: '9000',
        msgType: _readMsgType(command),
      );
    }

    // Current backend command types are low-level controller tunnel packets.
    // They are acknowledged here but intentionally marked unsupported by this emulator.
    if (type == 'tunnel_packet' ||
        type == 'tunnel_job' ||
        type == 'tunnel_file_job' ||
        type == 'tunnel_config_read_job' ||
        type == 'tunnel_config_write_job') {
      return CommandExecutionResult(
        commandId: command.id,
        status: 'unsupported',
        error:
            'Command type $type requires binary controller protocol execution, not yet implemented in emulator.',
        msgType: _readMsgType(command),
      );
    }

    return CommandExecutionResult(
      commandId: command.id,
      status: 'unsupported',
      error: 'Unknown command type: $type',
      msgType: _readMsgType(command),
    );
  }

  int? _readMsgType(HubCommand command) {
    final raw = command.payload['h1_msg_type'];
    if (raw is int) {
      return raw;
    }
    return int.tryParse('$raw');
  }
}
