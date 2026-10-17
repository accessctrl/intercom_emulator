import '../models/hub_command.dart';

class DoorCommandHandler {
  Future<Map<String, dynamic>> execute(HubCommand command) async {
    final commandType = command.type.trim().toLowerCase();
    if (commandType == 'door_open' || commandType == 'unlock') {
      return <String, dynamic>{'status': 'ok', 'response_hex': '9000'};
    }

    return <String, dynamic>{
      'status': 'unsupported',
      'error': 'Unsupported door command type: $commandType',
    };
  }
}
