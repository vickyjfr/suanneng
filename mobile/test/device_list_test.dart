import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se9_mobile/main.dart';

class DeviceApi extends Se9Api {
  DeviceApi() : super('');
  final reads = <String>[];
  final uploads = <String>[];
  final downloads = <String>[];
  bool failList = false;
  Completer<List<Map<String, dynamic>>>? pendingRead;
  @override
  Future<bool> restoreSession() async {
    cloudToken = 'test';
    return true;
  }

  @override
  Future<List<BoundDevice>> deviceList() async {
    if (failList) throw Exception('server unavailable');
    return const [
      BoundDevice(deviceId: 'home', name: 'Home NAS', status: 'online'),
      BoundDevice(deviceId: 'office', name: 'Office NAS', status: 'online'),
      BoundDevice(deviceId: 'off', name: 'Offline NAS', status: 'offline'),
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> remoteList(
      String deviceId, String path) async {
    reads.add('$deviceId:$path');
    if (pendingRead != null) return pendingRead!.future;
    return [
      {'name': 'photos', 'path': 'photos', 'directory': true},
      {
        'name': '$deviceId.png',
        'path': '$deviceId.png',
        'size': 3,
        'directory': false
      },
    ];
  }

  @override
  Future<void> remoteUpload(String deviceId, PlatformFile file, String path,
      void Function(double) progress) async {
    uploads.add('$deviceId:$path:${file.name}');
    progress(1);
  }

  @override
  Future<List<int>> remoteDownload(String deviceId, String path,
      {int? start, int? end}) async {
    downloads.add('$deviceId:$path');
    return [1, 2, 3];
  }

  @override
  Future<void> logout() async {
    cloudToken = null;
  }
}

class TestPicker extends FilePicker {
  String? savedName;
  Uint8List? savedBytes;
  bool cancelSave = false;
  @override
  Future<FilePickerResult?> pickFiles(
          {String? dialogTitle,
          String? initialDirectory,
          FileType type = FileType.any,
          List<String>? allowedExtensions,
          Function(FilePickerStatus)? onFileLoading,
          bool allowCompression = true,
          int compressionQuality = 30,
          bool allowMultiple = false,
          bool withData = false,
          bool withReadStream = false,
          bool lockParentWindow = false,
          bool readSequential = false}) async =>
      FilePickerResult([
        PlatformFile(
            name: 'new.png', size: 3, bytes: Uint8List.fromList([1, 2, 3]))
      ]);
  @override
  Future<String?> saveFile(
      {String? dialogTitle,
      String? fileName,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Uint8List? bytes,
      bool lockParentWindow = false}) async {
    savedName = fileName;
    savedBytes = bytes;
    return cancelSave ? null : '/saved/$fileName';
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('device_list uses account bearer token and loads every page', () async {
    SharedPreferences.setMockInitialValues({
      'se9.cloud.session': jsonEncode({
        'accessToken': 'account-token',
        'refreshToken': 'refresh',
        'expiresAt': DateTime.now().millisecondsSinceEpoch + 3600000,
        'lastRefreshAt': DateTime.now().millisecondsSinceEpoch,
      })
    });
    final pages = <int>[];
    final api = Se9Api('', cloudUrl: 'http://cloud/se9',
        client: MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/se9/api/v2/device_list');
      expect(request.headers['authorization'], 'Bearer account-token');
      final page = int.parse(request.url.queryParameters['page']!);
      pages.add(page);
      final count = page == 1 ? 100 : 1;
      return http.Response(
          jsonEncode({
            'code': '0',
            'data': {
              'items': List.generate(
                  count,
                  (i) => {
                        'deviceId': '$page-$i',
                        'name': 'NAS',
                        'status': 'offline'
                      }),
              'total': 101
            }
          }),
          200);
    }));
    await api.restoreSession();
    expect((await api.deviceList()).length, 101);
    expect(pages, [1, 2]);
  });

  testWidgets(
      'account devices work without LAN discovery; switching resets directory and download uses selection',
      (tester) async {
    final api = DeviceApi();
    final picker = TestPicker();
    FilePicker.platform = picker;
    await tester.pumpWidget(MaterialApp(home: FilePage(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('我的设备'), findsOneWidget);
    expect(find.text('Home NAS'), findsOneWidget);
    await tester.tap(find.text('文件 / 下载').first);
    await tester.pumpAndSettle();
    expect(api.reads.last, 'home:');
    await tester.tap(find.text('photos'));
    await tester.pumpAndSettle();
    expect(api.reads.last, 'home:photos');
    await tester.tap(find.text('文件 / 下载').at(1));
    await tester.pumpAndSettle();
    expect(api.reads.last, 'office:');
    expect(find.text('home.png'), findsNothing);
    await tester.tap(find.byTooltip('下载'));
    await tester.pumpAndSettle();
    expect(api.downloads, ['office:office.png']);
    expect(picker.savedName, 'office.png');
    expect(picker.savedBytes, [1, 2, 3]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('upload from device card targets that device and refreshes files',
      (tester) async {
    final api = DeviceApi();
    FilePicker.platform = TestPicker();
    await tester.pumpWidget(MaterialApp(home: FilePage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('上传').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择文件'));
    await tester.pumpAndSettle();
    expect(api.uploads, ['home::new.png']);
    expect(api.reads.last, 'home:');
    expect(find.text('home.png'), findsOneWidget);
    await tester.tap(find.byTooltip('上传文件'));
    await tester.pumpAndSettle();
    expect(api.uploads.length, 2);
    expect(api.uploads.last, 'home::new.png');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'offline device disables transfer actions and list failures can be retried',
      (tester) async {
    final api = DeviceApi()..failList = true;
    await tester.pumpWidget(MaterialApp(home: FilePage(api: api)));
    await tester.pumpAndSettle();
    expect(find.textContaining('设备列表加载失败'), findsOneWidget);
    api.failList = false;
    await tester.tap(find.byTooltip('刷新设备列表'));
    await tester.pumpAndSettle();
    final offlineButtons = find.descendant(
        of: find.widgetWithText(Card, 'Offline NAS'),
        matching: find.byType(TextButton));
    expect(offlineButtons, findsNWidgets(2));
    for (final element in offlineButtons.evaluate()) {
      expect((element.widget as TextButton).onPressed, isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'cancel download does not report saved and logout clears account files',
      (tester) async {
    final api = DeviceApi();
    FilePicker.platform = TestPicker()..cancelSave = true;
    await tester.pumpWidget(MaterialApp(home: FilePage(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件 / 下载').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('下载'));
    await tester.pumpAndSettle();
    expect(find.text('已取消保存'), findsOneWidget);
    await tester.tap(find.byTooltip('账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    expect(find.text('home.png'), findsNothing);
    expect(find.text('Home NAS'), findsNothing);
    expect(find.text('已退出登录'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
