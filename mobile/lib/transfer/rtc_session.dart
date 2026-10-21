import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart';
import 'ft_protocol.dart';

typedef TransferCloudCall = Future<Map<String, dynamic>> Function(
    String method, String path, Map<String, dynamic>? body, int expected);

class TransferCloud {
  const TransferCloud(
      {required this.baseUrl,
      required this.headers,
      required this.call,
      this.allowInsecureLocal = false});
  final String baseUrl;
  final Map<String, String> Function() headers;
  final TransferCloudCall call;
  final bool allowInsecureLocal;
  Uri uri(String path, [Map<String, String>? query, bool websocket = false]) {
    final base = Uri.parse(baseUrl);
    if (base.scheme != 'https' &&
        !(allowInsecureLocal &&
            const {'127.0.0.1', 'localhost', '::1'}.contains(base.host))) {
      throw const TransferException('RTC_TLS_REQUIRED', 'WebRTC 信令需要 HTTPS');
    }
    final prefix =
        base.path == '/' ? '' : base.path.replaceFirst(RegExp(r'/$'), '');
    return base.replace(
        scheme:
            websocket ? (base.scheme == 'https' ? 'wss' : 'ws') : base.scheme,
        path: '$prefix$path',
        queryParameters: query);
  }
}

class _IncomingBlock {
  _IncomingBlock(this.task, this.index);
  final WireTask task;
  final int index;
  final bytes = BytesBuilder(copy: false);
  final complete = Completer<Uint8List>();
}

class RtcTransferSession {
  RtcTransferSession(this.cloud, this.deviceId,
      {this.allowLegacyRelay = true, this.forceRelay = false, this.onStage});
  final TransferCloud cloud;
  final String deviceId;
  final bool allowLegacyRelay, forceRelay;
  final void Function(String)? onStage;
  RTCPeerConnection? peer;
  RTCDataChannel? control, data;
  WebSocket? signal;
  StreamSubscription<dynamic>? _signalSubscription;
  Timer? _renewTimer;
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _candidates = <RTCIceCandidate>[];
  final _remoteCandidates = <RTCIceCandidate>[];
  final _channelsOpen = Completer<void>();
  final _answered = Completer<void>();
  _IncomingBlock? _incoming;
  Map<String, dynamic>? info;
  String? failure;
  String pathType = 'WebRTC';
  String offerHash = '';
  bool _remoteSet = false,
      _peerClosed = false,
      _disposed = false,
      _renewing = false;
  int _txSequence = 0, _rxSequence = 0;
  DateTime created = DateTime.now();
  String get id => info?['rtcSessionId'] as String? ?? '';
  bool get needsReconnect =>
      failure != null ||
      DateTime.now().difference(created) >= const Duration(minutes: 50);

  Future<T> _step<T>(String stage, Future<T> Function() action) async {
    onStage?.call(stage);
    final watch = Stopwatch()..start();
    debugPrint('[SE9-RTC] device=$deviceId stage=$stage begin');
    try {
      final result = await action().timeout(const Duration(seconds: 15));
      debugPrint(
          '[SE9-RTC] stage=$stage done elapsedMs=${watch.elapsedMilliseconds}');
      return result;
    } on TimeoutException {
      debugPrint('[SE9-RTC] stage=$stage timed out');
      throw TransferException('RTC_SETUP_TIMEOUT', '$stage超时，请重试');
    } catch (error) {
      debugPrint('[SE9-RTC] stage=$stage failed type=${error.runtimeType}');
      rethrow;
    }
  }

  Future<void> open() async {
    cloud.uri('/api/v2/rtc/ice');
    onStage?.call('获取 ICE 配置');
    final ice = await cloud.call(
        'GET',
        '/api/v2/rtc/ice?deviceId=${Uri.encodeQueryComponent(deviceId)}',
        null,
        200);
    peer = await _step(
        '创建 WebRTC 连接',
        () => createPeerConnection({
              'iceServers': ice['iceServers'],
              'iceTransportPolicy': forceRelay ? 'relay' : 'all',
              'sdpSemantics': 'unified-plan'
            }));
    peer!.onIceCandidate = (candidate) {
      if (candidate.candidate?.isNotEmpty == true) {
        if (signal != null) {
          _sendCandidate(candidate);
        } else {
          _candidates.add(candidate);
        }
      }
    };
    peer!.onConnectionState = (state) {
      debugPrint('[SE9-RTC] connection=$state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _fail('CHANNEL_CLOSED');
      }
    };
    control = await _step(
        '创建控制通道',
        () => peer!.createDataChannel(
            'se9.control.v1', RTCDataChannelInit()..ordered = true));
    data = await _step(
        '创建文件通道',
        () => peer!.createDataChannel(
            'se9.file.v1', RTCDataChannelInit()..ordered = true));
    control!.onDataChannelState = (_) => _checkOpen();
    data!.onDataChannelState = (_) => _checkOpen();
    control!.onMessage = _onControl;
    data!.onMessage = _onData;
    final offer = await _step(
        '生成 offer',
        () => peer!.createOffer(
            {'offerToReceiveAudio': false, 'offerToReceiveVideo': false}));
    await _step('设置本地描述', () => peer!.setLocalDescription(offer));
    offerHash = await transferHash(utf8.encode(offer.sdp!));
    onStage?.call('创建云端 RTC 会话');
    info = await cloud.call(
        'POST',
        '/api/v2/rtc/sessions',
        {
          'deviceId': deviceId,
          'requestId': transferId(),
          'purpose': 'file-transfer',
          'protocolVersions': [1],
          'offer': {'type': 'offer', 'sdp': offer.sdp},
          'allowLegacyRelay': allowLegacyRelay
        },
        201);
    onStage?.call('连接信令服务');
    final url =
        cloud.uri('/api/v2/rtc/signaling/app', {'rtcSessionId': id}, true);
    signal = await WebSocket.connect(url.toString(), headers: cloud.headers())
        .timeout(const Duration(seconds: 15));
    _signalSubscription = signal!.listen(
        (event) {
          _signalChain = _signalChain
              .then((_) => _onSignal(event))
              .catchError((Object error) {
            _fail('RTC_AUTH_FAILED');
          });
        },
        onError: (Object error) => _fail('CHANNEL_CLOSED'),
        onDone: () {
          if (!_peerClosed) {
            _fail('CHANNEL_CLOSED');
          }
        });
    for (final candidate in _candidates) {
      _sendCandidate(candidate);
    }
    _candidates.clear();
    onStage?.call('等待设备应答和数据通道');
    debugPrint('[SE9-RTC] session=$id waiting for answer/channels');
    await Future.wait([_answered.future, _channelsOpen.future])
        .timeout(const Duration(seconds: 25));
    onStage?.call('验证传输授权');
    await command('BIND', {'grant': info!['grant']});
    created = DateTime.now();
    _renewTimer = Timer.periodic(const Duration(minutes: 4), (_) => renew());
    await updatePathType();
  }

  Future<void> _signalChain = Future<void>.value();
  void _sendCandidate(RTCIceCandidate candidate) {
    if (_disposed || _peerClosed || signal == null) {
      return;
    }
    signal!.add(jsonEncode({
      'version': 1,
      'type': 'ice.candidate',
      'rtcSessionId': id,
      'negotiationId': info!['negotiationId'],
      'messageId': transferId(),
      'payload': {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid ?? '0',
        'sdpMLineIndex': candidate.sdpMLineIndex ?? 0
      }
    }));
  }

  Future<void> _onSignal(dynamic raw) async {
    final message = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
    if (message['type'] == 'ping') {
      signal?.add(jsonEncode({'type': 'pong'}));
      return;
    }
    if (message['rtcSessionId'] != id ||
        message['negotiationId'] != info!['negotiationId']) {
      throw const TransferException('RTC_AUTH_FAILED');
    }
    final payload = (message['payload'] as Map? ?? {}).cast<String, dynamic>();
    if (message['type'] == 'session.answer') {
      final answer = (payload['answer'] as Map).cast<String, dynamic>();
      final answerHash =
          await transferHash(utf8.encode(answer['sdp'] as String));
      final transcript = utf8.encode(
          'se9-rtc-v1|$id|${info!['negotiationId']}|$offerHash|$answerHash');
      final valid = await Ed25519().verify(transcript,
          signature: Signature(
              base64Decode(payload['deviceSignature'] as String),
              publicKey: SimplePublicKey(
                  base64Decode(info!['devicePublicKey'] as String),
                  type: KeyPairType.ed25519)));
      if (!valid || answer['type'] != 'answer') {
        throw const TransferException('RTC_AUTH_FAILED');
      }
      await peer!.setRemoteDescription(
          RTCSessionDescription(answer['sdp'] as String, 'answer'));
      _remoteSet = true;
      for (final candidate in _remoteCandidates) {
        await peer!.addCandidate(candidate);
      }
      _remoteCandidates.clear();
      if (!_answered.isCompleted) {
        _answered.complete();
      }
    } else if (message['type'] == 'ice.candidate') {
      final candidate = RTCIceCandidate(payload['candidate'] as String?,
          payload['sdpMid'] as String?, payload['sdpMLineIndex'] as int?);
      if (candidate.candidate?.isNotEmpty == true) {
        if (_remoteSet) {
          await peer!.addCandidate(candidate);
        } else if (_remoteCandidates.length < 128) {
          _remoteCandidates.add(candidate);
        } else {
          throw const TransferException('PROTOCOL_MISMATCH');
        }
      }
    } else if (message['type'] == 'session.error' ||
        message['type'] == 'session.close') {
      _fail('CHANNEL_CLOSED');
    }
  }

  void _checkOpen() {
    if (control?.state == RTCDataChannelState.RTCDataChannelOpen &&
        data?.state == RTCDataChannelState.RTCDataChannelOpen &&
        !_channelsOpen.isCompleted) {
      _channelsOpen.complete();
    }
  }

  void _onControl(RTCDataChannelMessage message) {
    try {
      if (message.isBinary || utf8.encode(message.text).length > ftFrameBytes) {
        throw const TransferException('INVALID_CONTROL');
      }
      final value = (jsonDecode(message.text) as Map).cast<String, dynamic>();
      if (value['version'] != 1 || value['rtcSessionId'] != id) {
        throw const TransferException('INVALID_CONTROL');
      }
      final pending = _pending.remove(value['requestId']);
      if (pending == null) {
        return;
      }
      final payload = (value['payload'] as Map? ?? {}).cast<String, dynamic>();
      if (value['type'] == 'ERROR') {
        pending.completeError(
            TransferException(payload['code'] as String? ?? 'TRANSFER_FAILED'));
      } else {
        pending.complete(payload);
      }
    } catch (_) {
      _fail('PROTOCOL_MISMATCH');
    }
  }

  void _onData(RTCDataChannelMessage message) {
    try {
      final incoming = _incoming;
      if (!message.isBinary || incoming == null) {
        throw const TransferException('INVALID_FRAME');
      }
      final frame = TransferFrame.decode(message.binary);
      final expected = incoming.index * ftBlockBytes + incoming.bytes.length;
      final length = (incoming.task.size - incoming.index * ftBlockBytes)
          .clamp(0, ftBlockBytes);
      if (frame.id != incoming.task.id ||
          frame.epoch != incoming.task.epoch ||
          frame.sequence != _rxSequence ||
          frame.offset != expected ||
          incoming.bytes.length + frame.payload.length > length) {
        throw const TransferException('INVALID_FRAME');
      }
      _rxSequence++;
      incoming.bytes.add(frame.payload);
      if (incoming.bytes.length == length && !incoming.complete.isCompleted) {
        incoming.complete.complete(incoming.bytes.takeBytes());
      }
    } catch (_) {
      _fail('PROTOCOL_MISMATCH');
    }
  }

  void _fail(String code) {
    if (_disposed || _peerClosed) {
      return;
    }
    failure = code;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(TransferException(code));
      }
    }
    _pending.clear();
    final incoming = _incoming;
    if (incoming != null && !incoming.complete.isCompleted) {
      incoming.complete.completeError(TransferException(code));
    }
  }

  Future<Map<String, dynamic>> command(
      String type, Map<String, dynamic> payload,
      {WireTask? task}) async {
    if (failure != null ||
        _peerClosed ||
        control?.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw TransferException(failure ?? 'CHANNEL_CLOSED');
    }
    final requestId = transferId(),
        completer = Completer<Map<String, dynamic>>();
    final message = jsonEncode({
      'version': 1,
      'type': type,
      'requestId': requestId,
      'rtcSessionId': id,
      if (task != null) 'transferId': task.id,
      if (task != null) 'epoch': task.epoch,
      'payload': payload
    });
    if (utf8.encode(message).length > ftFrameBytes) {
      throw const TransferException('INVALID_CONTROL');
    }
    _pending[requestId] = completer;
    try {
      await control!.send(RTCDataChannelMessage(message));
      return await completer.future.timeout(const Duration(seconds: 35));
    } on TimeoutException {
      throw const TransferException('BLOCK_TIMEOUT');
    } finally {
      _pending.remove(requestId);
    }
  }

  Future<void> sendBlock(
      WireTask task, int index, Uint8List block, String hash) async {
    if (needsReconnect) {
      throw const TransferException('CONNECTION_REFRESH');
    }
    var offset = 0;
    while (offset < block.length) {
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (await data!.getBufferedAmount() > 1024 * 1024) {
        if (DateTime.now().isAfter(deadline) || failure != null) {
          throw const TransferException('CHANNEL_CLOSED');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final length =
          (block.length - offset).clamp(0, ftFrameBytes - ftHeaderBytes);
      final frame = TransferFrame(
          task.id,
          task.epoch,
          _txSequence++,
          index * ftBlockBytes + offset,
          Uint8List.sublistView(block, offset, offset + length));
      await data!.send(RTCDataChannelMessage.fromBinary(frame.encode()));
      offset += length;
    }
    await command('COMMIT_BLOCK',
        {'blockIndex': '$index', 'length': '${block.length}', 'sha256': hash},
        task: task);
  }

  Future<Uint8List> readBlock(WireTask task, int index) async {
    if (needsReconnect) {
      throw const TransferException('CONNECTION_REFRESH');
    }
    final incoming = _IncomingBlock(task, index);
    _incoming = incoming;
    try {
      final result = await Future.wait<dynamic>([
        command('READ_BLOCK', {'blockIndex': '$index'}, task: task),
        incoming.complete.future.timeout(const Duration(seconds: 35))
      ]);
      final metadata = result[0] as Map<String, dynamic>,
          bytes = result[1] as Uint8List;
      if (transferInt(metadata['blockIndex']) != index ||
          transferInt(metadata['length']) != bytes.length ||
          await transferHash(bytes) != metadata['sha256']) {
        throw const TransferException('HASH_MISMATCH');
      }
      return bytes;
    } on TimeoutException {
      throw const TransferException('BLOCK_TIMEOUT');
    } finally {
      _incoming = null;
    }
  }

  void resetSequences() {
    _txSequence = _rxSequence = 0;
  }

  Future<void> renew() async {
    if (_renewing || _disposed || info == null) {
      return;
    }
    _renewing = true;
    try {
      final updated =
          await cloud.call('POST', '/api/v2/rtc/sessions/$id/renew', {}, 200);
      info = updated;
      if (!_peerClosed && failure == null) {
        await command('BIND', {'grant': info!['grant']});
      }
    } catch (_) {
      if (!_peerClosed) {
        _fail('GRANT_EXPIRED');
      }
    } finally {
      _renewing = false;
    }
  }

  void keepLeaseForFallback() {
    _renewTimer ??= Timer.periodic(const Duration(minutes: 4), (_) => renew());
  }

  Future<void> updatePathType() async {
    try {
      final reports = await peer!.getStats();
      final candidates = <String, String>{};
      final pairs = <String, Map<dynamic, dynamic>>{};
      String? selected;
      for (final report in reports) {
        if (report.type == 'local-candidate' ||
            report.type == 'remote-candidate') {
          candidates[report.id] =
              report.values['candidateType']?.toString() ?? '';
        }
        if (report.type == 'candidate-pair') {
          pairs[report.id] = report.values;
          if (report.values['selected'] == true ||
              (report.values['nominated'] == true &&
                  report.values['state'] == 'succeeded')) {
            selected = report.id;
          }
        }
        if (report.type == 'transport') {
          selected =
              report.values['selectedCandidatePairId']?.toString() ?? selected;
        }
      }
      final pair = pairs[selected];
      if (pair != null) {
        pathType = candidates[pair['localCandidateId']] == 'relay' ||
                candidates[pair['remoteCandidateId']] == 'relay'
            ? 'TURN 中继'
            : '直连';
      }
    } catch (_) {
      pathType = 'WebRTC';
    }
  }

  Future<void> closePeer() async {
    _peerClosed = true;
    _failPending();
    await _signalSubscription?.cancel();
    await signal?.close();
    signal = null;
    await control?.close();
    await data?.close();
    await peer?.close();
    await peer?.dispose();
    peer = null;
  }

  void _failPending() {
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(const TransferException('CHANNEL_CLOSED'));
      }
    }
    _pending.clear();
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _renewTimer?.cancel();
    await closePeer();
    if (info != null) {
      try {
        await cloud.call('DELETE', '/api/v2/rtc/sessions/$id', null, 200);
      } catch (_) {}
    }
  }
}

class RtcTransferWire extends TransferWire {
  RtcTransferWire(this.session);
  final RtcTransferSession session;
  @override
  String get kind => session.pathType;
  @override
  Future<WireTask> start(Map<String, dynamic> input) async {
    final data = await session.command('START', input);
    session.resetSequences();
    return WireTask(data);
  }

  @override
  Future<WireTask> resume(WireTask task) async {
    final data = await session.command('RESUME', {
      'transferId': task.id,
      'resumeToken': task.token,
      'sourceVersion': task.sourceVersion
    });
    session.resetSequences();
    return WireTask(data, token: task.token);
  }

  @override
  Future<Map<String, dynamic>> status(WireTask task, {String? cursor}) =>
      session.command('STATUS', {
        'transferId': task.id,
        'resumeToken': task.token,
        if (cursor != null) 'cursor': cursor
      });
  @override
  Future<void> putBlock(
          WireTask task, int index, Uint8List bytes, String hash) =>
      session.sendBlock(task, index, bytes, hash);
  @override
  Future<Uint8List> getBlock(WireTask task, int index) =>
      session.readBlock(task, index);
  @override
  Future<void> acknowledge(WireTask task, int index, String hash) async {
    await session.command('BLOCK_ACK', {'blockIndex': '$index', 'sha256': hash},
        task: task);
  }

  @override
  Future<void> complete(WireTask task) async {
    await session.command(
        'FINISH', {'size': '${task.size}', 'sha256': task.hash},
        task: task);
  }

  @override
  Future<void> cancel(WireTask task) async {
    await session.command('CANCEL', {}, task: task);
  }

  @override
  Future<void> pause(WireTask task) async {
    await session.command('PAUSE', {}, task: task);
  }

  @override
  Future<void> close() async {}
}
