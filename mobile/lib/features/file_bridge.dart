import 'package:flutter/services.dart';

class FileBridge {
  static const _channel = MethodChannel('bus_bunching_mobile/files');

  static Future<bool> saveText({
    required String fileName,
    required String mimeType,
    required String content,
  }) async {
    final saved = await _channel.invokeMethod<bool>('saveText', {
      'fileName': fileName,
      'mimeType': mimeType,
      'content': content,
    });
    return saved ?? false;
  }

  static Future<String?> openText() =>
      _channel.invokeMethod<String>('openText');
}
