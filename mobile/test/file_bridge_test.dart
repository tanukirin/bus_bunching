import 'package:bus_bunching_mobile/features/file_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('bus_bunching_mobile/files');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'listExports returns empty when the platform bridge is absent',
    () async {
      final records = await FileBridge.listExports();
      expect(records, isEmpty);
    },
  );

  test('saveText sends kind and maps the returned history record', () async {
    MethodCall? captured;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          captured = call;
          return {
            'id': 'record-1',
            'kind': 'config',
            'fileName': 'bus-bunching-config.json',
            'mimeType': 'application/json',
            'savedAtMillis': 1777606200000,
          };
        });

    final record = await FileBridge.saveText(
      kind: FileExportKind.config,
      fileName: 'bus-bunching-config.json',
      mimeType: 'application/json',
      content: '{"type":"bus-bunching-config"}',
    );

    expect(captured?.method, 'saveText');
    expect(captured?.arguments, isA<Map>());
    final args = captured!.arguments as Map;
    expect(args['kind'], 'config');
    expect(args['fileName'], 'bus-bunching-config.json');
    expect(args['mimeType'], 'application/json');
    expect(args['content'], contains('bus-bunching-config'));
    expect(record?.id, 'record-1');
    expect(record?.kind, FileExportKind.config);
    expect(record?.savedAt.millisecondsSinceEpoch, 1777606200000);
  });

  test('list, read, forget, and delete map method channel payloads', () async {
    String? forgottenId;
    String? deletedId;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'listExports':
              return [
                {
                  'id': 'record-2',
                  'kind': 'metricsCsv',
                  'fileName': 'bus-bunching-metrics.csv',
                  'mimeType': 'text/csv',
                  'savedAtMillis': 1777606260000,
                },
              ];
            case 'readExport':
              expect((call.arguments as Map)['recordId'], 'record-2');
              return 'metric,plain';
            case 'forgetExport':
              forgottenId = (call.arguments as Map)['recordId'] as String?;
              return null;
            case 'deleteExport':
              deletedId = (call.arguments as Map)['recordId'] as String?;
              return true;
          }
          fail('unexpected method ${call.method}');
        });

    final records = await FileBridge.listExports();
    expect(records, hasLength(1));
    expect(records.single.kind, FileExportKind.metricsCsv);
    expect(records.single.fileName, 'bus-bunching-metrics.csv');

    final text = await FileBridge.readExport('record-2');
    expect(text, 'metric,plain');

    await FileBridge.forgetExport('record-2');
    expect(forgottenId, 'record-2');

    final deleted = await FileBridge.deleteExport('record-2');
    expect(deleted, isTrue);
    expect(deletedId, 'record-2');
  });
}
