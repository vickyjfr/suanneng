import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se9_mobile/main.dart';
import 'package:se9_mobile/transfer/transfer_repository.dart';

class DeviceApi extends Se9Api {
  DeviceApi() : super('');
  final reads = <String>[];
  final uploads = <String>[];
  final downloads = <String>[];
  final bindings = <String>[];
  final uploadedFiles = <PlatformFile>[];
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
    uploadedFiles.add(file);
    progress(1);
  }

  @override
  Future<List<int>> remoteDownload(String deviceId, String path,
      {int? start, int? end}) async {
    downloads.add('$deviceId:$path');
    return [1, 2, 3];
  }

  @override
  Future<void> confirmClaim(String deviceId, String claimString,
      {String? claimRequestId}) async {
    bindings.add('$deviceId:$claimRequestId:$claimString');
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

class PendingVideoPicker extends ImagePicker {
  int requests = 0;
  Completer<XFile?> pending = Completer<XFile?>();

  @override
  Future<XFile?> pickVideo({
    required ImageSource source,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    Duration? maxDuration,
  }) {
    requests++;
    return pending.future;
  }
}

class TestDiscovery extends UdpDiscovery {
  int searches = 0, pairings = 0;
  final pendingClaim = Completer<PairingClaim?>();
  final device = DiscoveredDevice(
      deviceId: 'new-nas',
      name: 'New NAS',
      address: InternetAddress('192.168.1.8'),
      port: 8443,
      apiBase: '/api/v2',
      claimStatus: 'unbound',
      publicKey: '',
      signature: '');
  @override
  Future<List<DiscoveredDevice>> discover(
      {Duration timeout = const Duration(seconds: 2)}) async {
    searches++;
    return [device];
  }

  @override
  Future<PairingClaim?> pair(DiscoveredDevice device) {
    pairings++;
    return pendingClaim.future;
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
    await tester.scrollUntilVisible(find.text('home.png'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('home.png'), findsOneWidget);
    expect(find.text('传输通道：服务器转发'), findsOneWidget);
    await tester.ensureVisible(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '上传文件'));
    await tester.tap(
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == '上传文件'));
    await tester.pumpAndSettle();
    expect(api.uploads.length, 2);
    expect(api.uploads.last, 'home::new.png');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'pending video selection blocks duplicate and file requests, then uploads by path',
      (tester) async {
    final api = DeviceApi();
    final picker = PendingVideoPicker();
    FilePicker.platform = TestPicker();
    final video = XFile.fromData(Uint8List.fromList([1, 2, 3, 4]),
        name: 'clip.mov', path: '/picked/clip.mov');
    await tester
        .pumpWidget(MaterialApp(home: FilePage(api: api, imagePicker: picker)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件 / 下载').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('photos'));
    await tester.pumpAndSettle();
    final galleryCallback = tester
        .widget<IconButton>(find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == '上传相册图片或视频'))
        .onPressed!;
    final fileCallback = tester
        .widget<IconButton>(find
            .byWidgetPredicate((w) => w is IconButton && w.tooltip == '上传文件'))
        .onPressed!;
    galleryCallback();
    galleryCallback();
    await tester.pumpAndSettle();
    expect(find.text('选择视频'), findsOneWidget);
    await tester.tap(find.text('选择视频'));
    await tester.pumpAndSettle();
    expect(picker.requests, 1);
    galleryCallback();
    fileCallback();
    await tester.pumpAndSettle();
    expect(picker.requests, 1);
    expect(api.uploads, isEmpty);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '上传文件'))
            .onPressed,
        isNull);
    picker.pending.complete(video);
    await tester.pumpAndSettle();
    expect(api.uploads, ['home:photos:clip.mov']);
    expect(api.uploadedFiles.single.path, video.path);
    expect(api.uploadedFiles.single.bytes, isNull);
    expect(api.uploadedFiles.single.size, 4);
    expect(api.reads.last, 'home:photos');
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '上传相册图片或视频'))
            .onPressed,
        isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelled or failed video selection releases lock for retry',
      (tester) async {
    final api = DeviceApi();
    final picker = PendingVideoPicker();
    FilePicker.platform = TestPicker();
    await tester
        .pumpWidget(MaterialApp(home: FilePage(api: api, imagePicker: picker)));
    await tester.pumpAndSettle();
    Future<void> openVideo() async {
      await tester.tap(find.text('上传').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('从相册选择视频'));
      await tester.pumpAndSettle();
    }

    await openVideo();
    picker.pending.complete(null);
    await tester.pumpAndSettle();
    expect(api.uploads, isEmpty);
    picker.pending = Completer<XFile?>();
    await openVideo();
    picker.pending.completeError(PlatformException(
        code: 'multiple_request', message: 'Cancelled by a second request'));
    await tester.pumpAndSettle();
    expect(find.textContaining('选择文件失败:'), findsOneWidget);
    expect(find.textContaining('上传失败:'), findsNothing);
    picker.pending = Completer<XFile?>();
    await openVideo();
    expect(picker.requests, 3);
    picker.pending.complete(null);
    await tester.pumpAndSettle();
    expect(api.uploads, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Add isolates installation, discovery and binding from home',
      (tester) async {
    final api = DeviceApi();
    final discovery = TestDiscovery();
    await tester.pumpWidget(
        MaterialApp(home: FilePage(api: api, discovery: discovery)));
    await tester.pumpAndSettle();
    expect(find.text('搜索设备'), findsNothing);
    expect(find.text('安装 NAS 程序'), findsNothing);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('添加设备'), findsOneWidget);
    expect(find.text('安装 NAS 程序'), findsOneWidget);
    await tester.tap(find.text('搜索设备'));
    await tester.pumpAndSettle();
    expect(discovery.searches, 1);
    expect(find.text('New NAS'), findsOneWidget);
    await tester.ensureVisible(find.text('绑定'));
    await tester.tap(find.text('绑定'));
    await tester.pump();
    expect(discovery.pairings, 1);
    expect(find.text('绑定中…'), findsOneWidget);
    discovery.pendingClaim.complete(const PairingClaim('claim', 'request'));
    await tester.pumpAndSettle();
    expect(api.bindings, ['new-nas:request:claim']);
    expect(find.text('已绑定'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('我的设备'), findsOneWidget);
    expect(find.text('New NAS'), findsNothing);
    expect(find.text('绑定'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'home reports actual RTC, TURN and relay changes and retains completion',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = DeviceApi();
    await tester.pumpWidget(MaterialApp(home: FilePage(api: api)));
    await tester.pumpAndSettle();
    final task = FileTransferTask(
        id: 't',
        userId: 'u',
        deviceId: 'home',
        direction: 'upload',
        path: 'video.mov',
        localPath: '/video.mov',
        size: 100,
        state: 'transferring',
        transport: '直连');
    api.onTransferChanged!(task);
    await tester.pumpAndSettle();
    expect(find.text('传输通道：WebRTC · 直连'), findsOneWidget);
    task.transport = 'TURN 中继';
    api.onTransferChanged!(task);
    await tester.pumpAndSettle();
    expect(find.text('传输通道：WebRTC · TURN 中继'), findsOneWidget);
    task.transport = '服务器转发';
    api.onTransferChanged!(task);
    await tester.pumpAndSettle();
    expect(find.text('传输通道：服务器转发'), findsOneWidget);
    task.state = 'completed';
    task.durableBytes = 100;
    api.onTransferChanged!(task);
    await tester.pumpAndSettle();
    expect(find.text('上传 · video.mov · 已完成'), findsOneWidget);
    expect(find.text('100.0%'), findsOneWidget);
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
