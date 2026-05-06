import 'package:flutter/services.dart';

enum FileExportKind {
  config('config', '設定', 'settings', 'json'),
  comparisonResults('comparisonResults', '比較結果', 'results', 'json'),
  metricsCsv('metricsCsv', '指標表', 'metrics', 'csv'),
  seedAverageJson('seedAverageJson', 'シード平均結果', 'seed-average-results', 'json'),
  seedAverageCsv('seedAverageCsv', 'シード平均指標表', 'seed-average-metrics', 'csv');

  const FileExportKind(this.value, this.label, this.fileSuffix, this.extension);

  final String value;
  final String label;
  final String fileSuffix;
  final String extension;

  static FileExportKind? tryParse(Object? value) {
    for (final kind in values) {
      if (kind.value == value) return kind;
    }
    return null;
  }

  bool get canImportConfig => this == config;
  bool get canImportSeedAverage => this == seedAverageJson;
}

class StoredExport {
  const StoredExport({
    required this.id,
    required this.fileName,
    required this.mimeType,
    required this.kind,
    required this.savedAt,
  });

  final String id;
  final String fileName;
  final String mimeType;
  final FileExportKind kind;
  final DateTime savedAt;

  static StoredExport? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString();
    final fileName = raw['fileName']?.toString();
    final mimeType = raw['mimeType']?.toString();
    final kind = FileExportKind.tryParse(raw['kind']);
    final millis = raw['savedAtMillis'];
    final savedAtMillis = millis is num ? millis.toInt() : null;
    if (id == null ||
        fileName == null ||
        mimeType == null ||
        kind == null ||
        savedAtMillis == null) {
      return null;
    }
    return StoredExport(
      id: id,
      fileName: fileName,
      mimeType: mimeType,
      kind: kind,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAtMillis).toLocal(),
    );
  }
}

class FileBridge {
  static const _channel = MethodChannel('bus_bunching_mobile/files');

  static Future<StoredExport?> saveText({
    required FileExportKind kind,
    required String fileName,
    required String mimeType,
    required String content,
  }) async {
    final record = await _channel.invokeMethod<Object?>('saveText', {
      'kind': kind.value,
      'fileName': fileName,
      'mimeType': mimeType,
      'content': content,
    });
    return StoredExport.tryFromMap(record);
  }

  static Future<List<StoredExport>> listExports() async {
    try {
      final records = await _channel.invokeMethod<List<Object?>>('listExports');
      return records
              ?.map(StoredExport.tryFromMap)
              .whereType<StoredExport>()
              .toList() ??
          const [];
    } on MissingPluginException {
      return const [];
    }
  }

  static Future<String?> readExport(String recordId) =>
      _channel.invokeMethod<String>('readExport', {'recordId': recordId});

  static Future<void> forgetExport(String recordId) async {
    await _channel.invokeMethod<void>('forgetExport', {'recordId': recordId});
  }

  static Future<bool> deleteExport(String recordId) async {
    final deleted = await _channel.invokeMethod<bool>('deleteExport', {
      'recordId': recordId,
    });
    return deleted ?? false;
  }
}
