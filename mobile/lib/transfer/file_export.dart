import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

class TransferFileExport {
  static const _channel = MethodChannel('se9/file_export');
  static Future<String?> save(File source, String name) async {
    if (Platform.isIOS || Platform.isAndroid) {
      return _channel
          .invokeMethod<String>('export', {'path': source.path, 'name': name});
    }
    final destination = await FilePicker.platform.saveFile(fileName: name);
    if (destination == null) {
      return null;
    }
    await source.openRead().pipe(File(destination).openWrite());
    return destination;
  }
}
