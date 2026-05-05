import 'dart:io';

import 'package:bus_bunching_mobile/main.dart';
import 'package:bus_bunching_mobile/domain/config.dart';
import 'package:bus_bunching_mobile/domain/runner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide ComparisonResult;

void main() {
  testWidgets('analysis controls sit above tabs and metrics are collapsed', (
    tester,
  ) async {
    await tester.pumpWidget(const BusBunchingApp());
    final appContext = tester.element(find.byType(SimulatorHome));
    expect(Localizations.localeOf(appContext), const Locale('ja', 'JP'));
    expect(find.bySemanticsLabel('だんごバス3台'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight);
    expect(find.text('分析'), findsWidgets);
    expect(find.text('再生'), findsOneWidget);
    final panelRect = tester.getRect(find.byType(ControlPanel));
    final navigationRect = tester.getRect(find.byType(NavigationBar));
    expect(panelRect.bottom, lessThanOrEqualTo(navigationRect.top));
    expect(navigationRect.top - panelRect.bottom, lessThanOrEqualTo(8));
    expect(find.byTooltip('10分戻す'), findsOneWidget);
    expect(find.byTooltip('リセット'), findsNothing);
    expect(find.textContaining('seed '), findsNothing);
    expect(find.text('制御なし'), findsOneWidget);
    expect(find.text('保持'), findsNothing);
    expect(find.byTooltip('全指標を表示'), findsOneWidget);
    await tester.tap(find.byTooltip('全指標を表示'));
    await tester.pumpAndSettle();
    expect(find.text('保持'), findsWidgets);
    expect(find.byTooltip('全指標を隠す'), findsOneWidget);
    await tester.tap(find.byTooltip('全指標を隠す'));
    await tester.pumpAndSettle();
    expect(find.text('保持'), findsNothing);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(find.text('再生'), findsOneWidget);
    expect(find.text('スキップ制御'), findsWidgets);
  });

  testWidgets('settings auto-apply and random seed are available', (
    tester,
  ) async {
    await tester.pumpWidget(const BusBunchingApp());
    await tester.tap(find.text('設定').last);
    await tester.pumpAndSettle();
    expect(find.text('プリセット'), findsOneWidget);
    expect(find.text('入力設定を反映'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'ランダムシード'), '123456');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('123456'), findsOneWidget);
    await tester.tap(find.byTooltip('ランダムなシードに変更'));
    await tester.pumpAndSettle();
    expect(find.text('123456'), findsNothing);
  });

  testWidgets('seed average tab exposes run controls', (tester) async {
    await tester.pumpWidget(const BusBunchingApp());
    await tester.tap(find.text('シード平均').last);
    await tester.pumpAndSettle();
    expect(find.text('基準シード'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('シード平均を実行'), findsOneWidget);
  });

  testWidgets('major charts render for analysis and seed average results', (
    tester,
  ) async {
    await tester.pumpWidget(const BusBunchingApp());
    await tester.scrollUntilVisible(
      find.text('破線は上位5%または最大'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('破線は上位5%または最大'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('スキップ乗客の追加待ち'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('前車待ち遅延'), findsWidgets);

    final result = SeedAverageRunner.runSync(
      config: presets['urban']!.copyWith(durationMin: 1),
      baseSeed: 10,
      count: 1,
      includeHistory: true,
      engine: 'fast',
    );
    var seedSummaryMode = SummaryMetricDisplayMode.percent;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => SeedAveragePage(
            config: result.config,
            progress: null,
            result: result,
            status: '完了',
            running: false,
            summaryMetricMode: seedSummaryMode,
            onToggleSummaryMetricMode: () => setState(
              () => seedSummaryMode =
                  seedSummaryMode == SummaryMetricDisplayMode.percent
                  ? SummaryMetricDisplayMode.absolute
                  : SummaryMetricDisplayMode.percent,
            ),
            onRun: (_, _) async {},
            onCancel: () {},
          ),
        ),
      ),
    );
    expect(find.text('％'), findsOneWidget);
    expect(find.text('値'), findsOneWidget);
    await tester.tap(find.text('値'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('破線は上位5%または最大'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('破線は上位5%または最大'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('スキップ乗客の追加待ち'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('前車待ち遅延'), findsWidgets);
  });

  testWidgets('detail metrics are collapsed and expand on tap', (tester) async {
    await tester.pumpWidget(const BusBunchingApp());
    expect(find.text('発生乗客数'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('詳細指標'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('詳細指標'));
    await tester.pumpAndSettle();
    expect(find.text('指標'), findsWidgets);
    expect(find.text('制御なし'), findsWidgets);
    expect(find.text('スキップ'), findsWidgets);
    expect(find.text('スプリング'), findsWidgets);
    expect(find.byType(Table), findsOneWidget);
    expect(find.byType(DataTable), findsNothing);
    expect(find.text('発生乗客数'), findsOneWidget);
    expect(find.text('上位5%待ち'), findsOneWidget);
  });

  testWidgets('summary metrics toggle between percent and absolute values', (
    tester,
  ) async {
    final config = presets['urban']!;
    final metrics = {
      'avgWaitMin': 10.0,
      'adjustedAvgTotalMin': 10.0,
      'headwayRmseStops': 10.0,
      'maxHeadwayStops': 10.0,
      'deniedAvgExtraMin': 10.0,
      'totalBlockedDelayMin': 10.0,
    };
    final result = ComparisonResult(
      config: config,
      events: const [],
      results: {
        'plain': ModeResult(metrics: metrics, history: const []),
        'skip': ModeResult(
          metrics: {for (final key in metrics.keys) key: 9.0},
          history: const [],
        ),
        'spring': ModeResult(
          metrics: {for (final key in metrics.keys) key: 11.0},
          history: const [],
        ),
      },
    );
    var mode = SummaryMetricDisplayMode.percent;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: SummaryGrid(
              result: result,
              displayMode: mode,
              onToggleDisplayMode: () => setState(
                () => mode = mode == SummaryMetricDisplayMode.percent
                    ? SummaryMetricDisplayMode.absolute
                    : SummaryMetricDisplayMode.percent,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('％'), findsOneWidget);
    expect(find.text('値'), findsOneWidget);
    expect(find.textContaining('/'), findsNothing);
    expect(find.text('S +10%'), findsWidgets);
    expect(find.text('Sp -10%'), findsWidgets);
    await tester.tap(find.text('値'));
    await tester.pumpAndSettle();
    expect(find.text('S 9.0分'), findsWidgets);
    expect(find.text('Sp 11.0分'), findsWidgets);
    expect(find.text('S +10%'), findsNothing);
  });

  test('metric delta tones follow improvement thresholds', () {
    const definition = MetricDefinition('x', '試験', '分');
    expect(metricDeltaTone(definition, 100, 94), MetricDeltaTone.improved);
    expect(metricDeltaTone(definition, 100, 103), MetricDeltaTone.worsened);
    expect(metricDeltaTone(definition, 100, 97), MetricDeltaTone.neutral);
    const higherBetter = MetricDefinition(
      'x',
      '試験',
      '人',
      direction: MetricDirection.higherBetter,
    );
    expect(metricDeltaTone(higherBetter, 100, 106), MetricDeltaTone.improved);
    const minHeadway = MetricDefinition(
      'minHeadwayStops',
      '最小車間',
      '停',
      direction: MetricDirection.higherBetter,
    );
    expect(metricDeltaTone(minHeadway, 10, 12), MetricDeltaTone.improved);
    expect(metricDeltaTone(minHeadway, 10, 8), MetricDeltaTone.worsened);
  });

  test('bus visual state colors are state based', () {
    expect(busVisualStateColor(BusVisualState.normal), const Color(0xff2c6fbb));
    expect(
      busVisualStateColor(BusVisualState.blocked),
      const Color(0xffc83f3f),
    );
    expect(
      busVisualStateColor(BusVisualState.springHold),
      const Color(0xff7357c8),
    );
    expect(
      busVisualStateColor(BusVisualState.alightOnlySkip),
      const Color(0xff7357c8),
    );
    expect(
      busVisualStateColor(BusVisualState.alightOnlySkip),
      busVisualStateColor(BusVisualState.assistSkip),
    );
  });

  test('visible strings do not use simplified Chinese variants', () {
    const bannedCodePoints = [
      0x95F4,
      0x8F66,
      0x95E8,
      0x53D1,
      0x603B,
      0x8BBE,
      0x52A8,
      0x5B9E,
      0x5F00,
      0x89C6,
      0x89C2,
      0x8F6C,
      0x8F7D,
      0x6807,
      0x8F74,
      0x8FDF,
      0x7EBF,
      0x56FE,
      0x5BF9,
      0x5355,
      0x51FB,
      0x8BFB,
      0x8F93,
      0x65F6,
      0x663E,
      0x9690,
      0x9875,
      0x8FB9,
      0x8F86,
      0x4E2A,
      0x8BC4,
      0x6EE1,
      0x8FC7,
      0x5E94,
      0x68C0,
    ];
    final banned = bannedCodePoints.map(String.fromCharCode).toList();
    final files = [
      ...Directory('lib').listSync(recursive: true).whereType<File>(),
      ...Directory('test').listSync(recursive: true).whereType<File>(),
    ].where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final text = file.readAsStringSync();
      for (final char in banned) {
        expect(
          text.contains(char),
          isFalse,
          reason: '${file.path} contains $char',
        );
      }
    }
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
