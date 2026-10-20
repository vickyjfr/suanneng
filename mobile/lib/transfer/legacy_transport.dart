import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'ft_protocol.dart';
import 'rtc_session.dart';

class LegacyTransferWire extends TransferWire {
  LegacyTransferWire(this.session);
  final RtcTransferSession session;
  WebSocket? _socket;
  StreamIterator<dynamic>? _responses;
  DateTime? _connected;
  @override
  String get kind => '服务器转发';
  Future<void> _connect() async {
    if (_socket != null) {
      if (DateTime.now().difference(_connected!) >=
          const Duration(minutes: 3)) {
        throw const TransferException('CONNECTION_REFRESH');
      }
      return;
    }
    final created = await session.cloud.call('POST', '/api/v2/sessions',
        {'deviceId': session.deviceId, 'rtcSessionId': session.id}, 201);
    final uri = session.cloud.uri('/api/v2/relay/app',
        {'sessionId': created['sessionId'] as String}, true);
    _socket = await WebSocket.connect(uri.toString(),
            headers: session.cloud.headers())
        .timeout(const Duration(seconds: 15));
    _responses = StreamIterator<dynamic>(_socket!);
    _connected = DateTime.now();
  }

  Future<({int status, Map<String, String> headers, Uint8List body})> _request(
      String method, String path,
      {WireTask? task,
      Uint8List? bytes,
      Map<String, dynamic>? json,
      String? hash}) async {
    await _connect();
    final body = bytes ??
        Uint8List.fromList(utf8.encode(json == null ? '' : jsonEncode(json)));
    if (body.length > ftBlockBytes) {
      throw const TransferException('INVALID_BLOCK');
    }
    final headers = <String, String>{
      'Host': 'se9',
      'Content-Type': 'application/json',
      'Content-Length': '${body.length}',
      'Connection': 'keep-alive',
      if (task != null) 'X-SE9-Resume-Token': task.token,
      if (task != null) 'X-SE9-Epoch': '${task.epoch}',
      if (hash != null) 'X-SE9-Block-SHA256': hash
    };
    final request = utf8.encode(
        '$method $path HTTP/1.1\r\n${headers.entries.map((e) => '${e.key}: ${e.value}\r\n').join()}\r\n');
    _socket!.add(Uint8List.fromList([...request, ...body]));
    try {
      if (!await _responses!.moveNext().timeout(const Duration(seconds: 35))) {
        throw const TransferException('CHANNEL_CLOSED');
      }
      final raw = _responses!.current;
      if (raw is! List<int> || raw.length > 2 * ftBlockBytes + 8192) {
        throw const TransferException('INVALID_RESPONSE');
      }
      final message = Uint8List.fromList(raw);
      var end = -1;
      for (var i = 0; i + 3 < message.length && i < 8192; i++) {
        if (message[i] == 13 &&
            message[i + 1] == 10 &&
            message[i + 2] == 13 &&
            message[i + 3] == 10) {
          end = i;
          break;
        }
      }
      if (end < 0) {
        throw const TransferException('INVALID_RESPONSE');
      }
      final lines = latin1.decode(message.sublist(0, end)).split('\r\n');
      final responseHeaders = <String, String>{};
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0) {
          responseHeaders[line.substring(0, colon).toLowerCase()] =
              line.substring(colon + 1).trim();
        }
      }
      final payload = Uint8List.sublistView(message, end + 4);
      if (int.tryParse(responseHeaders['content-length'] ?? '') !=
          payload.length) {
        throw const TransferException('INVALID_RESPONSE');
      }
      return (
        status: int.parse(lines.first.split(' ')[1]),
        headers: responseHeaders,
        body: payload
      );
    } on TimeoutException {
      throw const TransferException('BLOCK_TIMEOUT');
    }
  }

  Map<String, dynamic> _envelope(int status, Uint8List body) {
    final value =
        (jsonDecode(utf8.decode(body)) as Map).cast<String, dynamic>();
    if (status < 200 || status >= 300 || value['code'] != '0') {
      throw TransferException(value['code'] as String? ?? 'TRANSFER_FAILED');
    }
    return (value['data'] as Map).cast<String, dynamic>();
  }

  @override
  Future<WireTask> start(Map<String, dynamic> input) async {
    final result = await _request('POST', '/api/v2/transfers', json: input);
    return WireTask(_envelope(result.status, result.body));
  }

  @override
  Future<WireTask> resume(WireTask task) async {
    final r = await _request('POST', '/api/v2/transfers/${task.id}/resume',
        task: task, json: {'sourceVersion': task.sourceVersion});
    return WireTask(_envelope(r.status, r.body), token: task.token);
  }

  @override
  Future<Map<String, dynamic>> status(WireTask task, {String? cursor}) async {
    final r = await _request('GET',
        '/api/v2/transfers/${task.id}${cursor == null ? '' : '?cursor=$cursor'}',
        task: task);
    return _envelope(r.status, r.body);
  }

  @override
  Future<void> putBlock(
      WireTask task, int index, Uint8List bytes, String hash) async {
    final r = await _request(
        'PUT', '/api/v2/transfers/${task.id}/blocks/$index',
        task: task, bytes: bytes, hash: hash);
    _envelope(r.status, r.body);
  }

  @override
  Future<Uint8List> getBlock(WireTask task, int index) async {
    final r = await _request(
        'GET', '/api/v2/transfers/${task.id}/blocks/$index',
        task: task);
    if (r.status != 200) {
      _envelope(r.status, r.body);
    }
    if (r.body.length > ftBlockBytes ||
        await transferHash(r.body) != r.headers['x-se9-block-sha256']) {
      throw const TransferException('HASH_MISMATCH');
    }
    return r.body;
  }

  @override
  Future<void> acknowledge(WireTask task, int index, String hash) async {
    final r = await _request(
        'POST', '/api/v2/transfers/${task.id}/blocks/$index/ack',
        task: task, json: {'sha256': hash});
    _envelope(r.status, r.body);
  }

  @override
  Future<void> complete(WireTask task) async {
    final r = await _request('POST', '/api/v2/transfers/${task.id}/complete',
        task: task, json: {'size': '${task.size}', 'sha256': task.hash});
    _envelope(r.status, r.body);
  }

  @override
  Future<void> cancel(WireTask task) async {
    final r =
        await _request('DELETE', '/api/v2/transfers/${task.id}', task: task);
    _envelope(r.status, r.body);
  }

  @override
  Future<void> pause(WireTask task) async {}
  @override
  Future<void> close() async {
    await _responses?.cancel();
    await _socket?.close();
    _responses = null;
    _socket = null;
  }
}
