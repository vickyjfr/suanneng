import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:se9_mobile/transfer/ft_protocol.dart';
import 'package:se9_mobile/transfer/rtc_session.dart';

void main() {
  testWidgets('unresponsive native peer creation times out with its stage',
      (tester) async {
    const channel = MethodChannel('FlutterWebRTC.Method');
    final nativeCalls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      nativeCalls.add(call.method);
      if (call.method == 'initialize') return null;
      if (call.method == 'createPeerConnection') {
        return Completer<dynamic>().future;
      }
      throw StateError('unexpected method ${call.method}');
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final stages = <String>[];
    final session = RtcTransferSession(
        TransferCloud(
            baseUrl: 'https://cloud.test',
            headers: () => {},
            call: (method, path, body, expected) async => {'iceServers': []}),
        'nas',
        onStage: stages.add);
    final result = expectLater(
        session.open(),
        throwsA(isA<TransferException>()
            .having((e) => e.code, 'code', 'RTC_SETUP_TIMEOUT')));
    await tester.pump();
    expect(nativeCalls, contains('createPeerConnection'));
    await tester.pump(const Duration(seconds: 16));
    await result;
    expect(stages.last, '创建 WebRTC 连接');
    await session.dispose();
  });
}
