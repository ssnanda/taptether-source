import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:taptether/scan_report.dart';

void main() {
  test('diagnostics are bounded and do not upload', () {
    final report = ScanReport(maxLines: 3);
    report.add('host one');
    report.add('host two');
    report.add('host three');
    report.add('host four');
    expect(report.length, 3);
    expect(report.output, isNot(contains('host one')));
    expect(report.output, contains('host four'));
    report.clear();
    expect(report.isEmpty, isTrue);
  });

  testWidgets('scan report is expandable and copy option is available',
      (tester) async {
    final report = ScanReport();
    report.add('192.168.21.242: TCP 48321 no connection');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ScanReportPanel(title: 'Full Scan Output', report: report),
        ),
      ),
    ));
    expect(find.text('Full Scan Output'), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-full-output')), findsOneWidget);
    await tester.tap(find.text('Full Scan Output'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('copy-scan-output')), findsOneWidget);
    expect(find.textContaining('192.168.21.242'), findsOneWidget);
  });
}
