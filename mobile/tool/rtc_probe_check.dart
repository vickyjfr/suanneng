import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:cryptography/cryptography.dart';
import 'package:se9_mobile/transfer/ft_protocol.dart';

Future<void> verifyRtc(String cloud, Map<String, String> auth, String device,
    String binary) async {
  final environment = <String, String>{};
  if (Platform.environment['SE9_TEST_TURN'] == '1') {
    final bootstrap = await http.get(
        Uri.parse('$cloud/api/v2/rtc/ice?deviceId=$device'),
        headers: auth);
    final server = jsonDecode(bootstrap.body)['data']['iceServers'][0] as Map;
    final url = (server['urls'] as List).first as String;
    final split = url.indexOf(':');
    environment['SE9_TEST_ICE'] =
        '${url.substring(0, split)}:${Uri.encodeComponent(server['username'] as String)}:${Uri.encodeComponent(server['credential'] as String)}@${url.substring(split + 1)}';
    environment['SE9_TEST_RELAY'] = '1';
  }
  final probe = await Process.start(binary, [], environment: environment);
  final events = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final log = <Map<String, dynamic>>[];
  WebSocket? ws;
  Map<String, dynamic>? session;
  final pendingCandidates = <Map<String, dynamic>>[];
  void send(Map<String, dynamic> value) =>
      probe.stdin.writeln(jsonEncode(value));
  void signal(Map<String, dynamic> value) => ws!.add(jsonEncode({
        'version': 1,
        'type': 'ice.candidate',
        'rtcSessionId': session!['rtcSessionId'],
        'negotiationId': session['negotiationId'],
        'messageId': transferId(),
        'payload': {
          'candidate': value['candidate'],
          'sdpMid': value['sdpMid'],
          'sdpMLineIndex': 0
        }
      }));
  Future<Map<String, dynamic>> next(String kind) => events.stream
      .firstWhere((v) => v['kind'] == kind)
      .timeout(const Duration(seconds: 35));
  final descriptions = Completer<String>();
  final opened = <String>{};
  final remoteCandidates = <Map<String, dynamic>>[];
  bool remoteSet = false;
  final ready = Completer<void>();
  final subscription = probe.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    if (!line.startsWith('{')) {
      stderr.writeln(line);
      return;
    }
    final value = (jsonDecode(line) as Map).cast<String, dynamic>();
    log.add(value);
    if (value['kind'] == 'description' && !descriptions.isCompleted) {
      descriptions.complete(value['sdp'] as String);
    }
    if (value['kind'] == 'candidate') {
      if (ws == null) {
        pendingCandidates.add(value);
      } else {
        signal(value);
      }
    }
    if (value['kind'] == 'open') {
      opened.add(value['channel'] as String);
      if (opened.length == 2 && !ready.isCompleted) ready.complete();
    }
    events.add(value);
  });
  probe.stderr.transform(utf8.decoder).listen(stderr.write);
  Future<Map<String, dynamic>> call(String type, Map<String, dynamic> payload,
      [WireTask? task]) async {
    final id = transferId();
    final result = events.stream
        .firstWhere(
            (v) => v['kind'] == 'control' && v['message']['requestId'] == id)
        .timeout(const Duration(seconds: 35));
    send({
      'kind': 'control',
      'message': {
        'version': 1,
        'type': type,
        'rtcSessionId': session!['rtcSessionId'],
        'requestId': id,
        if (task != null) 'transferId': task.id,
        if (task != null) 'epoch': task.epoch,
        'payload': payload
      }
    });
    final value = (await result)['message'] as Map;
    if (value['type'] == 'ERROR') throw StateError('$value');
    return (value['payload'] as Map).cast<String, dynamic>();
  }

  Future<Map<String, dynamic>> cloudCall(String method, String path,
      [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('$cloud$path');
    final response = method == 'POST'
        ? await http.post(uri, headers: auth, body: jsonEncode(body))
        : await http.get(uri, headers: auth);
    if (response.statusCode >= 300) {
      throw StateError('${response.statusCode}: ${response.body}');
    }
    return (jsonDecode(response.body)['data'] as Map).cast<String, dynamic>();
  }

  try {
    final offer =
        await descriptions.future.timeout(const Duration(seconds: 15));
    session = await cloudCall('POST', '/api/v2/rtc/sessions', {
      'deviceId': device,
      'requestId': transferId(),
      'protocolVersions': [1],
      'offer': {'type': 'offer', 'sdp': offer},
      'allowLegacyRelay': true
    });
    ws = await WebSocket.connect(
        '${cloud.replaceFirst('http', 'ws')}/api/v2/rtc/signaling/app?rtcSessionId=${session['rtcSessionId']}',
        headers: auth);
    ws.listen((raw) async {
      final v = jsonDecode(raw as String) as Map;
      final type = v['type'];
      final p = v['payload'] as Map? ?? {};
      if (type == 'ping') ws?.add(jsonEncode({'type': 'pong'}));
      if (type == 'session.answer') {
        final answer = p['answer']['sdp'] as String;
        final text =
            'se9-rtc-v1|${session!['rtcSessionId']}|${session['negotiationId']}|${await transferHash(utf8.encode(offer))}|${await transferHash(utf8.encode(answer))}';
        if (!await Ed25519().verify(utf8.encode(text),
            signature: Signature(base64Decode(p['deviceSignature'] as String),
                publicKey: SimplePublicKey(
                    base64Decode(session['devicePublicKey'] as String),
                    type: KeyPairType.ed25519)))) {
          throw StateError('answer signature mismatch');
        }
        send({'kind': 'answer', 'sdp': answer});
        remoteSet = true;
        for (final c in remoteCandidates) {
          send(c);
        }
        remoteCandidates.clear();
      }
      if (type == 'ice.candidate') {
        if (Platform.environment['SE9_TEST_TURN'] == '1' &&
            !(p['candidate'] as String).contains(' typ relay')) {
          return;
        }
        final c = <String, dynamic>{
          'kind': 'candidate',
          'candidate': p['candidate'],
          'sdpMid': p['sdpMid']
        };
        if (remoteSet) {
          send(c);
        } else {
          remoteCandidates.add(c);
        }
      }
    });
    for (final candidate in pendingCandidates) {
      signal(candidate);
    }
    await ready.future.timeout(const Duration(seconds: 35));
    await call('BIND', {'grant': session['grant']});
    await call('HELLO', {});
    final pair = next('pair');
    send({'kind': 'pair'});
    final selected = await pair;
    stdout.writeln('RTC pair: $selected');
    if (Platform.environment['SE9_TEST_TURN'] == '1' &&
        !'${selected['local']} ${selected['remote']}'.contains(' typ relay')) {
      throw StateError('forced TURN did not select relay');
    }
    final bytes = Uint8List(ftBlockBytes * 2 + 73);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = i % 251;
    }
    final hash = await transferHash(bytes);
    var upload = WireTask(await call('START', {
      'direction': 'upload',
      'path': 'rtc/roundtrip.bin',
      'requestId': transferId(),
      'size': '${bytes.length}',
      'sha256': hash,
      'blockBytes': ftBlockBytes,
      'overwrite': false
    }));
    Future<void> block(WireTask task, int index) async {
      final part = Uint8List.sublistView(bytes, index * ftBlockBytes,
          ((index + 1) * ftBlockBytes).clamp(0, bytes.length));
      final sent = next('sent');
      send({
        'kind': 'block',
        'id': task.id,
        'epoch': '${task.epoch}',
        'index': '$index',
        'length': '${part.length}'
      });
      await sent;
      await call(
          'COMMIT_BLOCK',
          {
            'blockIndex': '$index',
            'length': '${part.length}',
            'sha256': await transferHash(part)
          },
          task);
    }

    await block(upload, 0);
    final status = await call(
        'STATUS', {'transferId': upload.id, 'resumeToken': upload.token});
    if (transferInt(status['durableBytes']) != ftBlockBytes) {
      throw StateError('durable ACK mismatch');
    }
    await call('PAUSE', {}, upload);
    upload = WireTask(
        await call('RESUME', {
          'transferId': upload.id,
          'resumeToken': upload.token,
          'sourceVersion': ''
        }),
        token: upload.token);
    if (upload.epoch != 2) throw StateError('resume epoch mismatch');
    send({'kind': 'reset'});
    await block(upload, 1);
    await block(upload, 2);
    await call('FINISH', {'size': '${bytes.length}', 'sha256': hash}, upload);
    final download = WireTask(await call('START', {
      'direction': 'download',
      'path': 'rtc/roundtrip.bin',
      'requestId': transferId(),
      'blockBytes': ftBlockBytes,
      'overwrite': false
    }));
    var sequence = 0;
    final received = BytesBuilder(copy: false);
    for (var index = 0; index < 3; index++) {
      final expected =
          (bytes.length - index * ftBlockBytes).clamp(0, ftBlockBytes);
      final collected = BytesBuilder(copy: false);
      final complete = Completer<void>();
      final sub = events.stream.where((v) => v['kind'] == 'binary').listen((v) {
        final frame = TransferFrame.decode(base64Decode(v['bytes'] as String));
        if (frame.id != download.id ||
            frame.epoch != download.epoch ||
            frame.sequence != sequence++ ||
            frame.offset != index * ftBlockBytes + collected.length) {
          throw StateError('download frame mismatch');
        }
        collected.add(frame.payload);
        if (collected.length == expected) complete.complete();
      });
      final metadata =
          await call('READ_BLOCK', {'blockIndex': '$index'}, download);
      await complete.future.timeout(const Duration(seconds: 35));
      await sub.cancel();
      final chunk = collected.takeBytes();
      if (await transferHash(chunk) != metadata['sha256']) {
        throw StateError('block digest mismatch');
      }
      received.add(chunk);
      await call('BLOCK_ACK',
          {'blockIndex': '$index', 'sha256': metadata['sha256']}, download);
    }
    if (await transferHash(received.takeBytes()) != hash) {
      throw StateError('roundtrip digest mismatch');
    }
    await call('FINISH', {'size': '${bytes.length}', 'sha256': hash}, download);
    stdout.writeln(
        'PASS: authenticated WebRTC, signed SDP, 2 MiB+73 upload/download, durable blocks, pause/resume epoch, SHA-256');
    final fallbackBytes = Uint8List.sublistView(bytes, 0, ftBlockBytes + 73);
    final fallbackHash = await transferHash(fallbackBytes);
    var fallback = WireTask(await call('START', {
      'direction': 'upload',
      'path': 'rtc/fallback.bin',
      'requestId': transferId(),
      'size': '${fallbackBytes.length}',
      'sha256': fallbackHash,
      'overwrite': false
    }));
    send({'kind': 'reset'});
    await block(fallback, 0);
    await call('PAUSE', {}, fallback);
    final relaySession = await cloudCall('POST', '/api/v2/sessions',
        {'deviceId': device, 'rtcSessionId': session['rtcSessionId']});
    final relay = await WebSocket.connect(
        '${cloud.replaceFirst('http', 'ws')}/api/v2/relay/app?sessionId=${relaySession['sessionId']}',
        headers: auth);
    final responses = StreamIterator<dynamic>(relay);
    Future<Map<String, dynamic>> relayCall(
        String method, String path, WireTask? task,
        [List<int>? body, String? hash]) async {
      final payload = body ?? <int>[];
      final header =
          '$method $path HTTP/1.1\r\nHost: se9\r\nContent-Length: ${payload.length}\r\nConnection: close\r\n${task == null ? '' : 'X-SE9-Resume-Token: ${task.token}\r\nX-SE9-Epoch: ${task.epoch}\r\n'}${hash == null ? '' : 'X-SE9-Block-SHA256: $hash\r\n'}\r\n';
      relay.add(Uint8List.fromList([...utf8.encode(header), ...payload]));
      if (!await responses.moveNext().timeout(const Duration(seconds: 30))) {
        throw StateError('relay closed');
      }
      final raw = responses.current as List<int>;
      int end = -1;
      for (var i = 0; i + 3 < raw.length; i++) {
        if (raw[i] == 13 &&
            raw[i + 1] == 10 &&
            raw[i + 2] == 13 &&
            raw[i + 3] == 10) {
          end = i;
          break;
        }
      }
      if (end < 0) throw StateError('relay HTTP missing');
      final response = jsonDecode(utf8.decode(raw.sublist(end + 4))) as Map;
      if (response['code'] != '0') throw StateError('$response');
      return (response['data'] as Map).cast<String, dynamic>();
    }

    try {
      fallback = WireTask(
          await relayCall('POST', '/api/v2/transfers/${fallback.id}/resume',
              fallback, utf8.encode('{}')),
          token: fallback.token);
      if (fallback.epoch != 2) throw StateError('fallback resume epoch');
      final last = Uint8List.sublistView(fallbackBytes, ftBlockBytes);
      await relayCall('PUT', '/api/v2/transfers/${fallback.id}/blocks/1',
          fallback, last, await transferHash(last));
      await relayCall(
          'POST',
          '/api/v2/transfers/${fallback.id}/complete',
          fallback,
          utf8.encode(jsonEncode(
              {'size': '${fallbackBytes.length}', 'sha256': fallbackHash})));
      stdout.writeln(
          'PASS: same task RTC -> signed relay.attach fallback, epoch advance, durable block reuse, complete');
    } finally {
      await responses.cancel();
      await relay.close();
    }
  } catch (error) {
    stderr.writeln(
        'RTC probe last events: ${log.where((v) => v['kind'] != 'binary').toList().reversed.take(12).toList()}');
    rethrow;
  } finally {
    await ws?.close();
    send({'kind': 'quit'});
    await probe.stdin.close();
    await probe.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      probe.kill(ProcessSignal.sigkill);
      return -1;
    });
    await subscription.cancel();
    await events.close();
  }
}
