import 'package:flutter/material.dart';

import '../models/hub_config.dart';
import '../models/log_entry.dart';
import '../services/hub_ws_client.dart';
import '../state/emulator_controller.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final EmulatorController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _familyController;
  late final TextEditingController _serialController;
  late final TextEditingController _firmwareController;
  late final TextEditingController _statusIntervalController;

  @override
  void initState() {
    super.initState();
    final cfg = widget.controller.config;
    _baseUrlController = TextEditingController(text: cfg.baseUrl);
    _familyController = TextEditingController(text: cfg.family);
    _serialController = TextEditingController(text: cfg.serial);
    _firmwareController = TextEditingController(text: cfg.firmwareVersion);
    _statusIntervalController = TextEditingController(
      text: cfg.statusIntervalSec.toString(),
    );
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _familyController.dispose();
    _serialController.dispose();
    _firmwareController.dispose();
    _statusIntervalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Intercom Emulator'),
            actions: <Widget>[
              IconButton(
                tooltip: 'Initialize camera/microphone',
                onPressed: controller.initializeLocalMedia,
                icon: const Icon(Icons.videocam),
              ),
            ],
          ),
          body: DefaultTabController(
            length: 3,
            child: Column(
              children: <Widget>[
                const TabBar(
                  tabs: <Tab>[
                    Tab(text: 'Session'),
                    Tab(text: 'Settings'),
                    Tab(text: 'Logs'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      _buildSessionTab(controller),
                      _buildSettingsTab(controller),
                      _buildLogsTab(controller),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSessionTab(EmulatorController controller) {
    final state = controller.connectionState;
    final statusText = switch (state) {
      HubConnectionState.disconnected => 'Disconnected',
      HubConnectionState.connecting => 'Connecting',
      HubConnectionState.connected => 'Connected (awaiting auth)',
      HubConnectionState.authenticated => 'Authenticated',
      HubConnectionState.closing => 'Closing',
      HubConnectionState.failed => 'Failed',
    };

    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            FilledButton(
              onPressed: () async {
                final message = await controller.connect();
                if (!mounted) {
                  return;
                }
                _showSnack(message);
              },
              child: const Text('Connect'),
            ),
            OutlinedButton(
              onPressed: () async {
                final message = await controller.disconnect();
                if (!mounted) {
                  return;
                }
                _showSnack(message);
              },
              child: const Text('Disconnect'),
            ),
            OutlinedButton(
              onPressed: () {
                final message = controller.sendStatusNow();
                _showSnack(message);
              },
              child: const Text('Send Status'),
            ),
            OutlinedButton(
              onPressed: () {
                final message = controller.requestPull();
                _showSnack(message);
              },
              child: const Text('Pull Commands'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _sessionInfoCard(
          title: 'Last action',
          value: controller.lastActionMessage,
          icon: Icons.bolt,
        ),
        const SizedBox(height: 8),
        _sessionInfoCard(
          title: 'Last event',
          value: controller.lastEventMessage,
          icon: Icons.wifi_tethering,
        ),
        const SizedBox(height: 12),
        Text('State: $statusText'),
        const SizedBox(height: 8),
        Text('Commands handled: ${controller.commandsHandled}'),
        const SizedBox(height: 4),
        Text('Unsupported commands: ${controller.unsupportedCommands}'),
        if (controller.lastError != null &&
            controller.lastError!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            'Last error: ${controller.lastError}',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        const Text(
          'Current implementation intentionally reports tunnel_* commands as unsupported. '
          'This reflects the current backend gap for end-user intercom call/WebRTC runtime APIs.',
        ),
      ],
    );
  }

  Widget _buildSettingsTab(EmulatorController controller) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const <Widget>[
                Text(
                  'Required for Connect',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 6),
                Text('baseUrl, family, serial'),
                SizedBox(height: 6),
                Text('Example family: igch or igci'),
                Text('Example serial: igci000001'),
                Text(
                  'Hub key is loaded from .secrets.local.json via --dart-define-from-file',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _textField('Base URL', _baseUrlController),
        const SizedBox(height: 12),
        _textField('Family', _familyController),
        const SizedBox(height: 12),
        _textField('Serial', _serialController),
        const SizedBox(height: 12),
        _textField('Firmware version', _firmwareController),
        const SizedBox(height: 12),
        _textField(
          'Status interval (seconds)',
          _statusIntervalController,
          keyboardType: TextInputType.number,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async {
            final interval =
                int.tryParse(_statusIntervalController.text.trim()) ?? 20;
            final cfg = HubConfig(
              baseUrl: _baseUrlController.text.trim(),
              family: _familyController.text.trim(),
              serial: _serialController.text.trim(),
              hubKey: controller.config.hubKey,
              firmwareVersion: _firmwareController.text.trim().isEmpty
                  ? 'intercom-emulator/0.1.0'
                  : _firmwareController.text.trim(),
              healthStatus: 'ok',
              statusIntervalSec: interval,
            );
            await controller.saveConfig(cfg);
            if (!mounted) {
              return;
            }
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('Settings saved')));
          },
          child: const Text('Save Settings'),
        ),
      ],
    );
  }

  Widget _buildLogsTab(EmulatorController controller) {
    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: <Widget>[
              FilledButton.tonal(
                onPressed: controller.clearLogs,
                child: const Text('Clear logs'),
              ),
            ],
          ),
        ),
        Expanded(
          child: AnimatedBuilder(
            animation: controller.logger,
            builder: (context, _) {
              final logs = controller.logger.entries;
              if (logs.isEmpty) {
                return const Center(child: Text('No logs yet'));
              }

              return ListView.builder(
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  final entry = logs[index];
                  return ListTile(
                    dense: true,
                    title: Text(entry.message),
                    subtitle: Text(
                      '${entry.timestamp.toIso8601String()}\n${entry.details ?? ''}',
                    ),
                    trailing: Text(_levelText(entry.level)),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _textField(
    String label,
    TextEditingController controller, {
    bool obscureText = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
      ),
    );
  }

  Widget _sessionInfoCard({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(value),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _levelText(LogLevel level) {
    return switch (level) {
      LogLevel.debug => 'DEBUG',
      LogLevel.info => 'INFO',
      LogLevel.warning => 'WARN',
      LogLevel.error => 'ERROR',
    };
  }
}
