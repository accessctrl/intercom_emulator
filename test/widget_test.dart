import 'package:flutter_test/flutter_test.dart';
import 'package:intercom_emulator/src/state/emulator_controller.dart';
import 'package:intercom_emulator/src/ui/home_screen.dart';
import 'package:flutter/material.dart';

void main() {
  testWidgets('renders emulator bottom navigation icons', (
    WidgetTester tester,
  ) async {
    final controller = EmulatorController();

    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(controller: controller)),
    );

    expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
    expect(find.byIcon(Icons.article_outlined), findsOneWidget);
  });
}
