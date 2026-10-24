import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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
  int _selectedTabIndex = 0;

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

    // Auto-connect once UI is mounted so emulator is ready immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (!widget.controller.isConnected &&
          widget.controller.connectionState != HubConnectionState.connecting) {
        widget.controller.connect();
      }
    });
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
            title: const Text('IGC Intercom'),
            actions: <Widget>[
              TextButton.icon(
                onPressed: () async {
                  await controller.toggleConnection();
                },
                icon: Icon(
                  Icons.wifi,
                  color: controller.isConnected
                      ? Colors.green.shade700
                      : Theme.of(context).colorScheme.onSurface,
                ),
                label: Text(
                  controller.isConnected ? 'Disconnect' : 'Connect',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            bottom: true,
            child: IndexedStack(
              index: _selectedTabIndex,
              children: <Widget>[
                _buildSessionTab(controller),
                _buildSettingsTab(controller),
                _buildLogsTab(controller),
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _bottomTabButton(
                    index: 0,
                    icon: Icons.grid_view_rounded,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _bottomTabButton(index: 1, icon: Icons.tune_rounded),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _bottomTabButton(
                    index: 2,
                    icon: Icons.article_outlined,
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
    final apartmentText = controller.dialedApartment.isEmpty
        ? '-'
        : controller.dialedApartment;

    final keypad = <String>[
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      'del',
      '0',
      'call',
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        const keypadColumns = 3;
        const keypadRows = 4;
        const keypadSpacing = 6.0;
        const keypadAspect = 2.8;
        // Keep vertical math aligned with real paddings to avoid bottom overflow.
        const contentVerticalPadding = 14.0; // 10 top + 4 bottom
        const contentVerticalGaps = 22.0; // 8 + 8 + 6
        const infoRowHeight = 44.0;

        final contentWidth = (constraints.maxWidth - 24).clamp(
          0.0,
          double.infinity,
        );
        final buttonWidth =
            (contentWidth - (keypadColumns - 1) * keypadSpacing) /
            keypadColumns;
        final buttonHeight = buttonWidth / keypadAspect;
        final keypadHeight =
            (buttonHeight * keypadRows) + (keypadRows - 1) * keypadSpacing;

        final innerHeight = (constraints.maxHeight - contentVerticalPadding)
            .clamp(0.0, double.infinity)
            .toDouble();
        final previewHeight =
            (innerHeight - (keypadHeight + infoRowHeight + contentVerticalGaps))
                .clamp(96.0, innerHeight)
                .toDouble();

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Column(
            children: <Widget>[
              SizedBox(
                height: previewHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerLowest,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: _buildCameraPreview(controller),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Text(
                        apartmentText,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: controller.isDoorUnlocked
                          ? Colors.green.shade50
                          : Colors.red.shade50,
                      border: Border.all(
                        color: controller.isDoorUnlocked
                            ? Colors.green.shade300
                            : Colors.red.shade300,
                      ),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          controller.isDoorUnlocked
                              ? Icons.lock_open
                              : Icons.lock,
                          size: 16,
                          color: controller.isDoorUnlocked
                              ? Colors.green.shade700
                              : Colors.red.shade700,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          controller.isDoorUnlocked ? 'Open' : 'Locked',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: keypadHeight,
                child: GridView.builder(
                  itemCount: keypad.length,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                    childAspectRatio: 2.8,
                  ),
                  itemBuilder: (context, index) {
                    final key = keypad[index];
                    return _dialButton(
                      key,
                      enabled: key == 'call'
                          ? (controller.canStartCall ||
                                controller.canCancelCall)
                          : true,
                      callIsActive: controller.canCancelCall,
                      onTap: () {
                        if (key == 'del') {
                          controller.clearDialedApartment();
                        } else if (key == 'call') {
                          final action = controller.canCancelCall
                              ? controller.cancelCurrentCall()
                              : controller.startCall();
                          action.ignore();
                        } else {
                          controller.appendDialCharacter(key);
                        }
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }

  Widget _bottomTabButton({required int index, required IconData icon}) {
    final selected = _selectedTabIndex == index;
    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        backgroundColor: selected
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).colorScheme.surfaceContainerHigh,
        foregroundColor: selected
            ? Theme.of(context).colorScheme.onPrimaryContainer
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onPressed: () {
        setState(() {
          _selectedTabIndex = index;
        });
      },
      child: Icon(icon, size: 20),
    );
  }

  Widget _dialButton(
    String key, {
    required VoidCallback onTap,
    bool enabled = true,
    bool callIsActive = false,
  }) {
    final isDelete = key == 'del';
    final isCall = key == 'call';
    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: isCall
            ? (callIsActive ? Colors.red.shade100 : Colors.green.shade100)
            : null,
        foregroundColor: isCall
            ? (callIsActive ? Colors.red.shade900 : Colors.green.shade900)
            : null,
      ),
      onPressed: enabled ? onTap : null,
      child: isDelete
          ? const Icon(Icons.clear_all, size: 18)
          : isCall
          ? Icon(callIsActive ? Icons.call_end : Icons.call, size: 18)
          : Text(
              key,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
    );
  }

  Widget _buildCameraPreview(EmulatorController controller) {
    final renderer = controller.localPreviewRenderer;
    final shouldShowVideo =
        controller.isPreviewInitialized &&
        renderer != null &&
        controller.callState != IntercomCallState.idle;

    if (shouldShowVideo) {
      return RTCVideoView(
        renderer,
        mirror: true,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Icon(
          Icons.photo_camera_outlined,
          size: 26,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 4),
        Text('Camera preview', style: Theme.of(context).textTheme.bodyMedium),
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

  String _levelText(LogLevel level) {
    return switch (level) {
      LogLevel.debug => 'DEBUG',
      LogLevel.info => 'INFO',
      LogLevel.warning => 'WARN',
      LogLevel.error => 'ERROR',
    };
  }

  String _callStateText(EmulatorController controller) {
    return switch (controller.callState) {
      IntercomCallState.idle => 'Idle',
      IntercomCallState.calling =>
        'Calling ${controller.callSecondsRemaining}s',
      IntercomCallState.connected => 'Audio connected',
    };
  }
}
