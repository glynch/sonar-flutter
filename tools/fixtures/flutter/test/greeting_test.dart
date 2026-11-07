import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sonar_flutter_integration_fixture/greeting.dart';

void main() {
  testWidgets('shows the greeting', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Greeting()));

    expect(find.text('Hello Bangkok'), findsOneWidget);
  });
}
