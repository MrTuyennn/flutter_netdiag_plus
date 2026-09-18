import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_netdiag_plus_example/main.dart';

void main() {
  testWidgets('Hiện ô nhập host và panel đo', (WidgetTester tester) async {
    await tester.pumpWidget(const NetDiagApp());

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Đo lường mạng'), findsWidgets);
  });
}
