import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'ft_protocol.dart';
import 'rtc_session.dart';
import 'legacy_transport.dart';
import 'transfer_repository.dart';

class TransferManager {
  TransferManager(
      {required this.cloud,
      required this.userId,
      required this.repository,
      this.onUpdate,
      this.forceRelay = false,
      this.allowLegacyRelay = true});
  final TransferCloud cloud;
  final String userId;
  final TransferRepository repository;
  final bool forceRelay, allowLegacyRelay;
  final void Function(FileTransferTask task)? onUpdate;
  final List<FileTransferTask> tasks = [];
  FileTransferTask? _active;
  bool _pause = false, _cancel = false;
  Future<void> initialize() async {
    tasks.addAll(await repository.load(userId));
  }

  Future<void> _notify(FileTransferTask task) async {
    await repository.save(task);
    onUpdate?.call(task);
  }

  void requestPause() {
    _pause = true;
  }

  void requestCancel() {
    _cancel = true;
  }

  Future<FileTransferTask> upload(String deviceId, PlatformFile source,
      String directory, void Function(double) progress) async {
    if (_active != null) {
      throw const TransferException('TRANSFER_BUSY');
    }
    final id = transferId(),
        path = directory.isEmpty ? source.name : '$directory/${source.name}';
    final task = FileTransferTask(
        id: id,
        userId: userId,
        deviceId: deviceId,
        direction: 'upload',
        path: path,
        localPath: repository.pathFor(id, 'source'));
    _active = task;
    _pause = _cancel = false;
    tasks.add(task);
    try {
      task.phase = '复制所选文件';
      await _notify(task);
      final target = File(task.localPath);
      if (source.path != null) {
        await File(source.path!).openRead().pipe(target.openWrite());
      } else if (source.bytes != null) {
        final file = await target.open(mode: FileMode.write);
        try {
          await file.writeFrom(source.bytes!);
          await file.flush();
        } finally {
          await file.close();
        }
      } else {
        throw const TransferException('SOURCE_UNAVAILABLE');
      }
      task.size = await target.length();
      task.phase = '计算文件校验值';
      await _notify(task);
      task.hash = await repository.hashFile(target);
      await _notify(task);
      await _run(task, progress);
      return task;
    } catch (error) {
      if (task.state == 'preparing') {
        task.state = 'failed';
        task.error = '$error';
        await _notify(task);
      }
      rethrow;
    } finally {
      _active = null;
    }
  }

  Future<FileTransferTask> download(
      String deviceId, String path, void Function(double) progress) async {
    if (_active != null) {
      throw const TransferException('TRANSFER_BUSY');
    }
    final id = transferId();
    final task = FileTransferTask(
        id: id,
        userId: userId,
        deviceId: deviceId,
        direction: 'download',
        path: path,
        localPath: repository.pathFor(id, 'download'));
    tasks.add(task);
    _active = task;
    _pause = _cancel = false;
    try {
      await _notify(task);
      await _run(task, progress);
      return task;
    } finally {
      _active = null;
    }
  }

  Future<void> resumeTask(
      FileTransferTask task, void Function(double) progress) async {
    if (_active != null || task.userId != userId || task.terminal) {
      throw const TransferException('TRANSFER_BUSY');
    }
    _active = task;
    _pause = false;
    _cancel = task.state == 'cancel-pending';
    try {
      if (!_cancel &&
          task.direction == 'upload' &&
          (task.hash.isEmpty ||
              !await File(task.localPath).exists() ||
              await repository.hashFile(File(task.localPath)) != task.hash)) {
        throw const TransferException('SOURCE_CHANGED');
      }
      if (!_cancel && task.direction == 'download') {
        await repository.validateDownload(task);
      }
      await _run(task, progress);
    } finally {
      _active = null;
    }
  }

  Future<void> cancelTask(FileTransferTask task) async {
    if (_active?.id == task.id) {
      requestCancel();
      return;
    }
    if (task.terminal) {
      return;
    }
    if (task.remoteId.isEmpty) {
      task.state = 'cancelled';
      await _notify(task);
      return;
    }
    task.state = 'cancel-pending';
    await _notify(task);
    await resumeTask(task, (_) {});
  }

  Future<Set<int>> _committed(TransferWire wire, WireTask task) async {
    final result = <int>{};
    String? cursor;
    var pages = 0;
    do {
      final value = await wire.status(task, cursor: cursor);
      for (final range in value['committedRanges'] as List? ?? []) {
        final first = transferInt(range['firstBlock']),
            last = transferInt(range['lastBlock']);
        if (first < 0 ||
            last < first ||
            last >= (task.size + ftBlockBytes - 1) ~/ ftBlockBytes) {
          throw const TransferException('INVALID_RESPONSE');
        }
        for (var i = first; i <= last; i++) {
          result.add(i);
        }
      }
      cursor = value['cursor'] as String?;
      pages++;
      if (pages > 1024) {
        throw const TransferException('INVALID_RESPONSE');
      }
    } while (cursor != null);
    return result;
  }

  Future<void> _run(
      FileTransferTask task, void Function(double) progress) async {
    RtcTransferSession? session;
    TransferWire? wire;
    WireTask? remote;
    RandomAccessFile? local;
    var retries = 0;
    var preferLegacy = false;
    Future<void> disconnect() async {
      await wire?.close();
      wire = null;
      await session?.dispose();
      session = null;
    }

    Future<void> connect() async {
      session = RtcTransferSession(cloud, task.deviceId,
          forceRelay: forceRelay,
          allowLegacyRelay: allowLegacyRelay, onStage: (phase) {
        task.phase = phase;
        onUpdate?.call(task);
      });
      try {
        await session!.open();
        wire = RtcTransferWire(session!);
      } catch (error) {
        if (!allowLegacyRelay ||
            session!.info == null ||
            error is TransferException &&
                const {'RTC_AUTH_FAILED', 'RTC_TLS_REQUIRED'}
                    .contains(error.code)) {
          rethrow;
        }
        await session!.closePeer();
        session!.keepLeaseForFallback();
        wire = LegacyTransferWire(session!);
        preferLegacy = true;
      }
      if (preferLegacy && wire is! LegacyTransferWire) {
        await session!.closePeer();
        wire = LegacyTransferWire(session!);
        session!.keepLeaseForFallback();
      }
      task.transport = wire!.kind;
      await _notify(task);
      if (task.remoteId.isNotEmpty) {
        remote = await wire!.resume(task.wire(await repository.token(task)));
      } else {
        remote = await wire!.start({
          'direction': task.direction,
          'path': task.path,
          'requestId': task.id,
          if (task.direction == 'upload') 'size': '${task.size}',
          if (task.direction == 'upload') 'sha256': task.hash,
          'blockBytes': ftBlockBytes,
          'overwrite': false
        });
        task.remoteId = remote!.id;
        task.size = remote!.size;
        task.hash = remote!.hash;
        task.sourceVersion = remote!.sourceVersion;
        await repository.saveToken(task, remote!.token);
      }
      task.epoch = remote!.epoch;
      task.state = 'transferring';
      await _notify(task);
    }

    try {
      await connect();
      if (_cancel) {
        await wire!.cancel(remote!);
        task.state = 'cancelled';
        task.error = '';
        await _notify(task);
        await repository.removeToken(task);
        return;
      }
      if (task.direction == 'upload') {
        local = await File(task.localPath).open();
      } else {
        final file = File(task.localPath);
        if (!await file.exists()) {
          await file.create();
        }
        local = await file.open(mode: FileMode.writeOnlyAppend);
        await local.truncate(task.size);
      }
      while (true) {
        try {
          final committed = task.direction == 'upload'
              ? await _committed(wire!, remote!)
              : task.blocks.keys.toSet();
          task.durableBytes = committed.fold(
              0,
              (sum, index) =>
                  sum +
                  (task.size - index * ftBlockBytes).clamp(0, ftBlockBytes));
          final count = (task.size + ftBlockBytes - 1) ~/ ftBlockBytes;
          for (var index = 0; index < count; index++) {
            if (_pause || _cancel) {
              break;
            }
            if (committed.contains(index)) {
              continue;
            }
            final length =
                (task.size - index * ftBlockBytes).clamp(0, ftBlockBytes);
            if (task.direction == 'upload') {
              await local.setPosition(index * ftBlockBytes);
              final bytes = await local.read(length);
              if (bytes.length != length) {
                throw const TransferException('SOURCE_CHANGED');
              }
              await wire!
                  .putBlock(remote!, index, bytes, await transferHash(bytes));
            } else {
              final bytes = await wire!.getBlock(remote!, index);
              if (bytes.length != length) {
                throw const TransferException('INVALID_BLOCK');
              }
              final hash = await transferHash(bytes);
              await local.setPosition(index * ftBlockBytes);
              await local.writeFrom(bytes);
              await local.flush();
              task.blocks[index] = hash;
              await repository.save(task);
              await wire!.acknowledge(remote!, index, hash);
            }
            committed.add(index);
            task.durableBytes += length;
            if (wire is RtcTransferWire) await session!.updatePathType();
            task.transport = wire!.kind;
            await _notify(task);
            progress(task.progress);
          }
          if (_cancel) {
            await wire!.cancel(remote!);
            task.state = 'cancelled';
            task.error = '';
            await _notify(task);
            await repository.removeToken(task);
            return;
          }
          if (_pause) {
            await wire!.pause(remote!);
            task.state = 'paused';
            task.error = '';
            await _notify(task);
            throw const TransferException('TRANSFER_PAUSED', '任务已暂停');
          }
          task.state = 'verifying';
          await _notify(task);
          if (task.direction == 'download') {
            await local.flush();
            if (await repository.hashFile(File(task.localPath)) != task.hash) {
              throw const TransferException('HASH_MISMATCH');
            }
          }
          await wire!.complete(remote!);
          task.state = 'completed';
          task.durableBytes = task.size;
          task.error = '';
          await _notify(task);
          progress(1);
          return;
        } catch (error) {
          if (error is TransferException && error.recoverable ||
              error is SocketException ||
              error is IOException) {
            retries++;
            if (retries > 3) {
              rethrow;
            }
            task.state = 'recovering';
            task.error = '$error';
            await _notify(task);
            preferLegacy = allowLegacyRelay && retries >= 2;
            await disconnect();
            await Future<void>.delayed(Duration(seconds: retries));
            await connect();
            continue;
          }
          rethrow;
        }
      }
    } catch (error) {
      if (task.state != 'paused' && task.state != 'cancelled') {
        task.state = _cancel ? 'cancel-pending' : 'paused';
        task.error = '$error';
        await _notify(task);
      }
      rethrow;
    } finally {
      await local?.close();
      await disconnect();
    }
  }
}
