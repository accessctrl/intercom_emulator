import 'package:flutter_test/flutter_test.dart';
import 'package:intercom_emulator/src/state/emulator_controller.dart';
import 'package:intercom_emulator/src/ui/home_screen.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('renders emulator tabs', (WidgetTester tester) async {
    final controller = EmulatorController();

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );

    expect(find.text('Session'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Logs'), findsOneWidget);
  });
}
