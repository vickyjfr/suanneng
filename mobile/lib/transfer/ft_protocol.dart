import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

const ftFrameBytes = 16384;
const ftHeaderBytes = 48;
const ftBlockBytes = 1048576;
String transferId() => List.generate(16, (_) => Random.secure().nextInt(256))
    .map((v) => v.toRadixString(16).padLeft(2, '0'))
    .join();
Future<String> transferHash(List<int> bytes) async =>
    (await Sha256().hash(bytes))
        .bytes
        .map((v) => v.toRadixString(16).padLeft(2, '0'))
        .join();
int transferInt(dynamic value) =>
    value is int ? value : int.parse(value as String);

class TransferException implements Exception {
  const TransferException(this.code, [this.detail = '']);
  final String code;
  final String detail;
  bool get recoverable => const {
        'CHANNEL_CLOSED',
        'BLOCK_TIMEOUT',
        'FILE_API_UNAVAILABLE',
        'RTC_DEVICE_UNAVAILABLE',
        'ICE_FAILED',
        'CONNECTION_REFRESH',
        'GRANT_EXPIRED'
      }.contains(code);
  @override
  String toString() => detail.isEmpty ? code : '$code: $detail';
}

class TransferFrame {
  const TransferFrame(
      this.id, this.epoch, this.sequence, this.offset, this.payload);
  final String id;
  final int epoch;
  final int sequence;
  final int offset;
  final Uint8List payload;
  Uint8List encode() {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        epoch < 1 ||
        epoch > 0xffffffff ||
        sequence < 0 ||
        sequence > 0xffffffff ||
        offset < 0 ||
        payload.isEmpty ||
        payload.length + ftHeaderBytes > ftFrameBytes ||
        offset % ftBlockBytes + payload.length > ftBlockBytes) {
      throw const TransferException('INVALID_FRAME');
    }
    final bytes = Uint8List(ftHeaderBytes + payload.length);
    bytes.setAll(0, [83, 57, 70, 84, 1, 1]);
    for (var i = 0; i < 16; i++) {
      bytes[8 + i] = int.parse(id.substring(i * 2, i * 2 + 2), radix: 16);
    }
    final view = ByteData.sublistView(bytes);
    view.setUint32(24, epoch);
    view.setUint32(28, sequence);
    view.setUint64(32, offset);
    view.setUint32(40, payload.length);
    bytes.setAll(ftHeaderBytes, payload);
    return bytes;
  }

  factory TransferFrame.decode(Uint8List bytes) {
    if (bytes.length <= ftHeaderBytes || bytes.length > ftFrameBytes) {
      throw const TransferException('INVALID_FRAME');
    }
    final v = ByteData.sublistView(bytes);
    if (v.getUint32(0) != 0x53394654 ||
        bytes[4] != 1 ||
        bytes[5] != 1 ||
        v.getUint16(6) != 0 ||
        v.getUint32(44) != 0 ||
        v.getUint32(40) != bytes.length - ftHeaderBytes) {
      throw const TransferException('INVALID_FRAME');
    }
    final id = bytes
        .sublist(8, 24)
        .map((n) => n.toRadixString(16).padLeft(2, '0'))
        .join();
    final epoch = v.getUint32(24), offset = v.getUint64(32);
    if (epoch == 0 ||
        offset % ftBlockBytes + bytes.length - ftHeaderBytes > ftBlockBytes) {
      throw const TransferException('INVALID_FRAME');
    }
    return TransferFrame(id, epoch, v.getUint32(28), offset,
        Uint8List.sublistView(bytes, ftHeaderBytes));
  }
}

class WireTask {
  WireTask(Map<String, dynamic> value, {String? token})
      : id = value['transferId'] as String,
        token = value['resumeToken'] as String? ?? token ?? '',
        epoch = transferInt(value['epoch']),
        size = transferInt(value['size']),
        hash = value['sha256'] as String,
        sourceVersion = value['sourceVersion'] as String? ?? '',
        direction = value['direction'] as String,
        state = value['state'] as String,
        view = value {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(this.token) ||
        epoch < 1 ||
        epoch > 0xffffffff ||
        size < 0 ||
        transferInt(value['blockBytes']) != ftBlockBytes) {
      throw const TransferException('PROTOCOL_MISMATCH');
    }
  }
  final String id, token, hash, sourceVersion, direction, state;
  final int epoch, size;
  final Map<String, dynamic> view;
}

abstract class TransferWire {
  String get kind;
  Future<WireTask> start(Map<String, dynamic> input);
  Future<WireTask> resume(WireTask task);
  Future<Map<String, dynamic>> status(WireTask task, {String? cursor});
  Future<void> putBlock(WireTask task, int index, Uint8List bytes, String hash);
  Future<Uint8List> getBlock(WireTask task, int index);
  Future<void> acknowledge(WireTask task, int index, String hash);
  Future<void> complete(WireTask task);
  Future<void> cancel(WireTask task);
  Future<void> pause(WireTask task);
  Future<void> close();
}
