import 'package:flutter/material.dart';

import 'src/state/emulator_controller.dart';
import 'src/ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final controller = EmulatorController();
  await controller.load();

  runApp(IntercomEmulatorApp(controller: controller));
}

class IntercomEmulatorApp extends StatelessWidget {
  const IntercomEmulatorApp({super.key, required this.controller});

  final EmulatorController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Intercom Emulator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E4A6D)),
        useMaterial3: true,
      ),
      home: HomeScreen(controller: controller),
    );
  }
}
