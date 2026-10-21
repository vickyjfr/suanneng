import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'ft_protocol.dart';

class FileTransferTask {
  FileTransferTask(
      {required this.id,
      required this.userId,
      required this.deviceId,
      required this.direction,
      required this.path,
      required this.localPath,
      this.size = 0,
      this.hash = '',
      this.state = 'preparing',
      this.phase = '',
      this.transport = '',
      this.error = '',
      this.remoteId = '',
      this.sourceVersion = '',
      this.epoch = 1,
      this.durableBytes = 0,
      Map<int, String>? blocks})
      : blocks = blocks ?? {};
  final String id, userId, deviceId, direction, path, localPath;
  int size, epoch, durableBytes;
  String hash, state, phase, transport, error, remoteId, sourceVersion;
  final Map<int, String> blocks;
  bool get terminal =>
      const {'completed', 'cancelled', 'failed'}.contains(state);
  double get progress => size == 0
      ? (state == 'completed' ? 1 : 0)
      : (durableBytes / size).clamp(0, 1);
  String get name => path.split('/').last;
  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'deviceId': deviceId,
        'direction': direction,
        'path': path,
        'localPath': localPath,
        'size': '$size',
        'sha256': hash,
        'state': state,
        'phase': phase,
        'transport': transport,
        'error': error,
        'remoteId': remoteId,
        'sourceVersion': sourceVersion,
        'epoch': epoch,
        'durableBytes': '$durableBytes',
        'blocks': blocks.map((key, value) => MapEntry('$key', value))
      };
  factory FileTransferTask.fromJson(Map<String, dynamic> j) => FileTransferTask(
      id: j['id'] as String,
      userId: j['userId'] as String,
      deviceId: j['deviceId'] as String,
      direction: j['direction'] as String,
      path: j['path'] as String,
      localPath: j['localPath'] as String,
      size: transferInt(j['size']),
      hash: j['sha256'] as String,
      state: j['state'] as String,
      phase: j['phase'] as String? ?? '',
      transport: j['transport'] as String? ?? '',
      error: j['error'] as String? ?? '',
      remoteId: j['remoteId'] as String? ?? '',
      sourceVersion: j['sourceVersion'] as String? ?? '',
      epoch: transferInt(j['epoch']),
      durableBytes: transferInt(j['durableBytes']),
      blocks: (j['blocks'] as Map? ?? {}).map(
          (key, value) => MapEntry(int.parse(key as String), value as String)));
  WireTask wire(String token) => WireTask({
        'transferId': remoteId,
        'resumeToken': token,
        'epoch': '$epoch',
        'size': '$size',
        'sha256': hash,
        'sourceVersion': sourceVersion,
        'direction': direction,
        'state': state,
        'phase': phase,
        'blockBytes': '$ftBlockBytes'
      });
}

class TransferRepository {
  TransferRepository(this.root, this.secure);
  final Directory root;
  final FlutterSecureStorage secure;
  static Future<TransferRepository> open() async {
    final app = await getApplicationSupportDirectory();
    final root = Directory('${app.path}/se9-transfers');
    await root.create(recursive: true);
    return TransferRepository(root, const FlutterSecureStorage());
  }

  String pathFor(String id, String suffix) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
      throw const TransferException('INVALID_TRANSFER');
    }
    return '${root.path}/$id.$suffix';
  }

  Future<void> save(FileTransferTask task) async {
    final temporary = File(pathFor(task.id, 'json.tmp'));
    final file = await temporary.open(mode: FileMode.write);
    try {
      await file.writeString(jsonEncode(task.toJson()));
      await file.flush();
    } finally {
      await file.close();
    }
    await temporary.rename(pathFor(task.id, 'json'));
  }

  Future<List<FileTransferTask>> load(String userId) async {
    final tasks = <FileTransferTask>[];
    await for (final entity in root.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) {
        continue;
      }
      try {
        final task = FileTransferTask.fromJson(
            (jsonDecode(await entity.readAsString()) as Map)
                .cast<String, dynamic>());
        if (task.userId != userId ||
            File(task.localPath).absolute.path !=
                File(pathFor(task.id,
                        task.direction == 'upload' ? 'source' : 'download'))
                    .absolute
                    .path) {
          continue;
        }
        if (const {'transferring', 'preparing', 'verifying'}
            .contains(task.state)) {
          task.state = 'paused';
        }
        tasks.add(task);
      } catch (_) {}
    }
    return tasks;
  }

  Future<void> saveToken(FileTransferTask task, String token) =>
      secure.write(key: 'se9.ft.${task.userId}.${task.id}', value: token);
  Future<String> token(FileTransferTask task) async {
    final value = await secure.read(key: 'se9.ft.${task.userId}.${task.id}');
    if (value == null) {
      throw const TransferException('RESUME_CREDENTIAL_MISSING');
    }
    return value;
  }

  Future<void> removeToken(FileTransferTask task) =>
      secure.delete(key: 'se9.ft.${task.userId}.${task.id}');
  Future<String> hashFile(File file) async {
    final state = Sha256().newHashSink();
    await for (final bytes in file.openRead()) {
      state.add(bytes);
    }
    state.close();
    return (await state.hash())
        .bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> validateDownload(FileTransferTask task) async {
    final source = File(task.localPath);
    if (!await source.exists()) {
      task.blocks.clear();
      task.durableBytes = 0;
      await save(task);
      return;
    }
    final file = await source.open();
    try {
      for (final index in task.blocks.keys.toList()) {
        final length =
            (task.size - index * ftBlockBytes).clamp(0, ftBlockBytes);
        await file.setPosition(index * ftBlockBytes);
        final bytes = await file.read(length);
        if (bytes.length != length ||
            await transferHash(bytes) != task.blocks[index]) {
          task.blocks.remove(index);
        }
      }
    } finally {
      await file.close();
    }
    task.durableBytes = task.blocks.keys.fold(
        0,
        (sum, index) =>
            sum + (task.size - index * ftBlockBytes).clamp(0, ftBlockBytes));
    await save(task);
  }
}
