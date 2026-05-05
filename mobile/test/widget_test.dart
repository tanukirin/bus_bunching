import 'package:bus_bunching_mobile/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('analysis shell renders core controls', (tester) async {
    await tester.pumpWidget(const BusBunchingApp());
    expect(find.text('バス団子シミュレーター'), findsOneWidget);
    expect(find.text('分析'), findsWidgets);
    expect(find.text('再生'), findsOneWidget);
    expect(find.text('制御なし'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.text('スキップ制御'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.text('スプリング法'), findsOneWidget);
  });

  testWidgets('settings can be opened and applied', (tester) async {
    await tester.pumpWidget(const BusBunchingApp());
    await tester.tap(find.text('設定').last);
    await tester.pumpAndSettle();
    expect(find.text('プリセット'), findsOneWidget);
    expect(find.text('入力設定を反映'), findsOneWidget);
    await tester.tap(find.text('入力設定を反映'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('seed average tab exposes run controls', (tester) async {
    await tester.pumpWidget(const BusBunchingApp());
    await tester.tap(find.text('シード平均').last);
    await tester.pumpAndSettle();
    expect(find.text('基準シード'), findsOneWidget);
    expect(find.text('シード平均を実行'), findsOneWidget);
  });

  testWidgets('import export tab exposes JSON copy and import actions', (
    tester,
  ) async {
    await tester.pumpWidget(const BusBunchingApp());
    await tester.tap(find.text('入出力').last);
    await tester.pumpAndSettle();
    expect(find.text('設定JSONコピー'), findsOneWidget);
    expect(find.text('結果JSONコピー'), findsOneWidget);
    expect(find.text('JSON貼り付け'), findsOneWidget);
    expect(find.text('設定として読込'), findsOneWidget);
  });
}
