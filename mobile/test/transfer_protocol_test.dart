import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:se9_mobile/transfer/ft_protocol.dart';
import 'package:se9_mobile/main.dart';
import 'package:se9_mobile/transfer/transfer_repository.dart';
import 'package:se9_mobile/transfer/rtc_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('device capability matches the cloud device_list contract', () {
    expect(
        BoundDevice.fromJson({
          'deviceId': 'nas',
          'capabilities': {
            'fileTransferTransports': ['webrtc', 'legacy'],
            'fileTransferProtocolVersions': [1]
          }
        }).supportsRtc,
        isTrue);
    expect(BoundDevice.fromJson({'deviceId': 'old-nas'}).supportsRtc, isFalse);
  });
  test('wire frame preserves offsets above 4 GiB and rejects malformed headers',
      () {
    final payload = Uint8List.fromList([1, 2, 3]);
    final frame = TransferFrame(
        '00112233445566778899aabbccddeeff', 3, 9, 1 << 33, payload);
    final encoded = frame.encode(),
        decoded = TransferFrame.decode(frame.encode());
    expect(decoded.offset, 1 << 33);
    expect(decoded.epoch, 3);
    expect(decoded.sequence, 9);
    expect(decoded.payload, payload);
    for (final index in [4, 5, 6, 44]) {
      final malformed = Uint8List.fromList(encoded);
      malformed[index] = 255;
      expect(() => TransferFrame.decode(malformed),
          throwsA(isA<TransferException>()));
    }
    expect(
        () => TransferFrame(frame.id, 1, 0, ftBlockBytes - 1, payload).encode(),
        throwsA(isA<TransferException>()));
  });
  test('public HTTP signaling is refused even with local exception enabled',
      () {
    final cloud = TransferCloud(
        baseUrl: 'http://203.0.113.7',
        headers: () => {},
        call: (a, b, c, d) async => {},
        allowInsecureLocal: true);
    expect(() => cloud.uri('/api/v2/rtc/sessions'),
        throwsA(isA<TransferException>()));
    final local = TransferCloud(
        baseUrl: 'http://127.0.0.1:8080/se9',
        headers: () => {},
        call: (a, b, c, d) async => {},
        allowInsecureLocal: true);
    expect(
        local
            .uri('/api/v2/rtc/signaling/app', {'rtcSessionId': 'example'}, true)
            .toString(),
        'ws://127.0.0.1:8080/se9/api/v2/rtc/signaling/app?rtcSessionId=example');
  });
  test('restart restores only account tasks and rechecks local download blocks',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final directory =
        await Directory.systemTemp.createTemp('se9-repository-test-');
    addTearDown(() => directory.delete(recursive: true));
    final repo = TransferRepository(directory, const FlutterSecureStorage());
    final task = FileTransferTask(
        id: transferId(),
        userId: 'account-a',
        deviceId: 'nas',
        direction: 'download',
        path: 'photo.jpg',
        localPath: '',
        size: ftBlockBytes + 3);
    final actual = FileTransferTask(
        id: task.id,
        userId: task.userId,
        deviceId: task.deviceId,
        direction: task.direction,
        path: task.path,
        localPath: repo.pathFor(task.id, 'download'),
        size: task.size,
        state: 'transferring',
        blocks: {
          0: await transferHash(Uint8List(ftBlockBytes)),
          1: await transferHash([1, 2, 3])
        });
    await File(actual.localPath)
        .writeAsBytes([...Uint8List(ftBlockBytes), 9, 9, 9], flush: true);
    await repo.save(actual);
    await repo.saveToken(actual, 'recovery-secret');
    expect(await repo.load('account-b'), isEmpty);
    final recovered = (await repo.load('account-a')).single;
    expect(recovered.state, 'paused');
    expect(await repo.token(recovered), 'recovery-secret');
    await repo.validateDownload(recovered);
    expect(recovered.blocks.keys, [0]);
    expect(recovered.durableBytes, ftBlockBytes);
    await repo.removeToken(recovered);
    expect(() => repo.token(recovered), throwsA(isA<TransferException>()));
  });
}
