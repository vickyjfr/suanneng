import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'transfer/ft_protocol.dart';
import 'transfer/rtc_session.dart';
import 'transfer/transfer_manager.dart';
import 'transfer/transfer_repository.dart';
import 'transfer/file_export.dart';

void main() => runApp(const Se9App());

class Se9App extends StatelessWidget {
  const Se9App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'SE9 Files',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const FilePage(),
      );
}

class Se9Api {
  Se9Api(this.baseUrl, {String? cloudUrl, http.Client? client})
      : cloudBaseUrl = cloudUrl ??
            const String.fromEnvironment('SE9_CLOUD_API',
                defaultValue: 'http://123.56.147.51/se9'),
        _client = client ?? http.Client();
  final Set<String> _rtcDevices = {};
  TransferManager? _transfers;
  Future<TransferManager>? _transferFlight;
  void Function(FileTransferTask)? onTransferChanged;
  bool supportsRtc(String id) => _rtcDevices.contains(id);
  List<FileTransferTask> get transferTasks => _transfers?.tasks ?? [];
  void pauseTransfer() => _transfers?.requestPause();
  Future<TransferManager> transferManager() {
    if (_transfers != null) return Future.value(_transfers!);
    return _transferFlight ??=
        _openTransfers().whenComplete(() => _transferFlight = null);
  }

  Future<TransferManager> _openTransfers() async {
    final generation = _sessionGeneration;
    final account = await accountInfo();
    final repository = await TransferRepository.open();
    final manager = TransferManager(
        cloud: TransferCloud(
            baseUrl: cloudBaseUrl,
            headers: () => _cloudHeaders,
            allowInsecureLocal:
                const bool.fromEnvironment('SE9_RTC_ALLOW_INSECURE_LOCAL'),
            call: (method, path, body, expected) async {
              if (generation != _sessionGeneration) {
                throw const TransferException('RTC_AUTH_FAILED');
              }
              final response = await _cloudRequest(method, path, body: body);
              final envelope =
                  (jsonDecode(response.body) as Map).cast<String, dynamic>();
              if (response.statusCode != expected) {
                throw TransferException(
                    envelope['code']?.toString() ?? 'CLOUD_ERROR',
                    envelope['message']?.toString() ?? '');
              }
              return (envelope['data'] as Map).cast<String, dynamic>();
            }),
        userId: account['userId']!,
        repository: repository,
        onUpdate: (task) => onTransferChanged?.call(task));
    await manager.initialize();
    if (generation != _sessionGeneration) {
      throw const TransferException('RTC_AUTH_FAILED');
    }
    return _transfers = manager;
  }

  Future<FileTransferTask> downloadTask(
          String deviceId, String path, void Function(double) progress) async =>
      (await transferManager()).download(deviceId, path, progress);
  String baseUrl;
  final String cloudBaseUrl;
  final http.Client _client;
  Future<void>? _refreshFlight;
  int _sessionGeneration = 0;
  String? token;
  String? cloudToken;
  SharedPreferences? _preferences;
  static const _cloudTokenKey = 'se9.cloud.accessToken';
  static const _cloudRefreshKey = 'se9.cloud.refreshToken';
  static const _cloudExpiryKey = 'se9.cloud.expiresAt';
  static const _cloudRefreshAtKey = 'se9.cloud.lastRefreshAt';
  static const _localTokenKey = 'se9.local.accessToken';
  static const _localRefreshKey = 'se9.local.refreshToken';
  static const _localExpiryKey = 'se9.local.expiresAt';
  static const _deviceUrlKey = 'se9.device.baseUrl';

  Future<void> login(String username, String password) async {
    token = null;
    if (baseUrl.isNotEmpty) {
      try {
        final response = await http.post(
            Uri.parse('$baseUrl/api/v2/auth/login'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}));
        final data = _data(response, 200, '本地设备登录失败');
        token = data['accessToken'] as String;
        await _saveLocalSession(data);
      } catch (_) {}
    }
    final cloudResponse = await _client.post(
        Uri.parse('$cloudBaseUrl/api/v2/auth/login'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}));
    final cloudData = _data(cloudResponse, 200, '云端登录失败');
    cloudToken = cloudData['accessToken'] as String;
    await _saveCloudSession(cloudData);
  }

  Future<bool> restoreSession() async {
    _preferences = await SharedPreferences.getInstance();
    baseUrl = _preferences!.getString(_deviceUrlKey) ?? baseUrl;
    token = _preferences!.getString(_localTokenKey);
    final saved = _preferences!.getString('se9.cloud.session');
    if (saved != null) {
      final data = (jsonDecode(saved) as Map).cast<String, dynamic>();
      cloudToken = data['accessToken'] as String?;
    } else {
      cloudToken = _preferences!.getString(_cloudTokenKey);
    }
    if (cloudToken == null) return false;
    try {
      await refreshIfNeeded();
    } on SocketException {
      debugPrint('[SE9-AUTH] offline; saved session retained');
    } on http.ClientException {
      debugPrint('[SE9-AUTH] network unavailable; saved session retained');
    } on TimeoutException {
      debugPrint('[SE9-AUTH] refresh timed out; saved session retained');
    } catch (_) {
      if (cloudToken == null) return false;
      debugPrint('[SE9-AUTH] server unavailable; saved session retained');
    }
    return cloudToken != null;
  }

  Future<void> refreshCloudToken() {
    final pending = _refreshFlight;
    if (pending != null) return pending;
    final future = _refreshCloudToken();
    _refreshFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshFlight, future)) _refreshFlight = null;
    });
  }

  Future<void> _refreshCloudToken() async {
    final generation = _sessionGeneration;
    _preferences ??= await SharedPreferences.getInstance();
    final saved = _preferences!.getString('se9.cloud.session');
    final session = saved == null ? null : (jsonDecode(saved) as Map);
    final refreshToken = session?['refreshToken'] as String? ??
        _preferences!.getString(_cloudRefreshKey);
    if (refreshToken == null) {
      await clearSession();
      throw Exception('登录状态已失效，请重新登录');
    }
    final response = await _client
        .post(Uri.parse('$cloudBaseUrl/api/v2/auth/refresh'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'refreshToken': refreshToken}))
        .timeout(const Duration(seconds: 15));
    if (generation != _sessionGeneration) throw Exception('登录会话已变更');
    if (response.statusCode == 401) {
      await clearSession();
      throw Exception('登录凭证已过期，请重新登录');
    }
    final data = _data(response, 200, '暂时无法刷新登录状态，请稍后重试');
    await _saveCloudSession(data, keepRefreshToken: refreshToken);
    cloudToken = data['accessToken'] as String;
    debugPrint('[SE9-AUTH] access token refreshed; session saved');
  }

  Future<http.Response> _cloudRequest(String method, String path,
      {Map<String, dynamic>? body}) async {
    await refreshIfNeeded();
    Future<http.Response> send() {
      final uri = Uri.parse('$cloudBaseUrl$path');
      final headers = {'content-type': 'application/json', ..._cloudHeaders};
      return (method == 'GET'
              ? _client.get(uri, headers: headers)
              : method == 'DELETE'
                  ? _client.delete(uri, headers: headers)
                  : _client.post(uri,
                      headers: headers, body: jsonEncode(body ?? {})))
          .timeout(const Duration(seconds: 15));
    }

    final response = await send();
    if (response.statusCode != 401) return response;
    await refreshCloudToken();
    return send();
  }

  Future<void> ensureLocalSession() async {
    _preferences ??= await SharedPreferences.getInstance();
    final expiry = _preferences!.getInt(_localExpiryKey) ?? 0;
    if (token != null &&
        expiry <=
            DateTime.now().millisecondsSinceEpoch +
                const Duration(minutes: 5).inMilliseconds) {
      await refreshLocalToken();
    }
  }

  Future<void> refreshLocalToken() async {
    _preferences ??= await SharedPreferences.getInstance();
    final refreshToken = _preferences!.getString(_localRefreshKey);
    if (refreshToken == null || baseUrl.isEmpty) {
      throw Exception('local refresh token missing');
    }
    final response = await http.post(Uri.parse('$baseUrl/api/v2/auth/refresh'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'refreshToken': refreshToken}));
    final data = _data(response, 200, '设备登录状态已失效');
    token = data['accessToken'] as String;
    await _saveLocalSession(data, keepRefreshToken: refreshToken);
  }

  Future<void> refreshIfNeeded() async {
    if (cloudToken == null) return;
    _preferences ??= await SharedPreferences.getInstance();
    final saved = _preferences!.getString('se9.cloud.session');
    final session = saved == null ? null : (jsonDecode(saved) as Map);
    final expiry = session?['expiresAt'] as int? ??
        _preferences!.getInt(_cloudExpiryKey) ??
        0;
    final lastRefresh = session?['lastRefreshAt'] as int? ??
        _preferences!.getInt(_cloudRefreshAtKey) ??
        0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (expiry <= now + const Duration(minutes: 5).inMilliseconds ||
        now - lastRefresh >= const Duration(days: 2).inMilliseconds) {
      await refreshCloudToken();
    }
  }

  Future<void> _saveCloudSession(Map<String, dynamic> data,
      {String? keepRefreshToken}) async {
    _preferences ??= await SharedPreferences.getInstance();
    final refresh = data['refreshToken'] as String? ?? keepRefreshToken;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiresIn = (data['expiresIn'] as num?)?.toInt() ?? 3600;
    await _preferences!.setString(
        'se9.cloud.session',
        jsonEncode({
          'accessToken': data['accessToken'],
          'refreshToken': refresh,
          'expiresAt': now + expiresIn * 1000,
          'lastRefreshAt': now,
        }));
  }

  Future<void> _saveLocalSession(Map<String, dynamic> data,
      {String? keepRefreshToken}) async {
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences!
        .setString(_localTokenKey, data['accessToken'] as String);
    final refresh = data['refreshToken'] as String? ?? keepRefreshToken;
    if (refresh != null) {
      await _preferences!.setString(_localRefreshKey, refresh);
    }
    final expiresIn = (data['expiresIn'] as num?)?.toInt() ?? 3600;
    await _preferences!.setInt(_localExpiryKey,
        DateTime.now().millisecondsSinceEpoch + expiresIn * 1000);
  }

  Future<void> clearSession() async {
    _sessionGeneration++;
    _transfers?.requestPause();
    _transfers = null;
    _rtcDevices.clear();
    _preferences ??= await SharedPreferences.getInstance();
    await _preferences!.remove('se9.cloud.session');
    await _preferences!.remove(_cloudTokenKey);
    await _preferences!.remove(_cloudRefreshKey);
    await _preferences!.remove(_cloudExpiryKey);
    await _preferences!.remove(_cloudRefreshAtKey);
    await _preferences!.remove(_localTokenKey);
    await _preferences!.remove(_localRefreshKey);
    await _preferences!.remove(_localExpiryKey);
    token = null;
    cloudToken = null;
  }

  Future<void> registerCloud(
      String account, String password, String nickname) async {
    final response = await _client.post(
        Uri.parse('$cloudBaseUrl/api/v2/auth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(
            {'account': account, 'password': password, 'nickname': nickname}));
    final data = _data(response, 201, '注册失败');
    cloudToken = data['accessToken'] as String;
    await _saveCloudSession(data);
  }

  Future<Map<String, String>> accountInfo() async {
    final response = await _cloudRequest('GET', '/api/v2/auth/me');
    final data = _data(response, 200, '读取账号信息失败');
    return (data['user'] as Map).cast<String, String>();
  }

  Future<List<BoundDevice>> deviceList() async {
    final devices = <BoundDevice>[];
    var page = 1;
    while (true) {
      final response = await _cloudRequest(
          'GET', '/api/v2/device_list?page=$page&pageSize=100');
      final data = _data(response, 200, '读取设备列表失败');
      final items = (data['items'] as List)
          .map((item) =>
              BoundDevice.fromJson((item as Map).cast<String, dynamic>()))
          .toList();
      devices.addAll(items);
      if (items.isEmpty || devices.length >= (data['total'] as num).toInt()) {
        _rtcDevices
          ..clear()
          ..addAll(devices.where((d) => d.supportsRtc).map((d) => d.deviceId));
        return devices;
      }
      page++;
    }
  }

  Future<void> changePassword(
      String currentPassword, String newPassword) async {
    final response = await _cloudRequest('POST', '/api/v2/auth/password/change',
        body: {'currentPassword': currentPassword, 'newPassword': newPassword});
    _data(response, 200, '修改密码失败');
  }

  Future<void> resetPassword(
      String account, String resetCode, String newPassword) async {
    final response = await http.post(
        Uri.parse('$cloudBaseUrl/api/v2/auth/password/reset'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'account': account,
          'resetCode': resetCode,
          'newPassword': newPassword
        }));
    _data(response, 200, '重置密码失败');
  }

  Future<void> logout() async {
    try {
      if (cloudToken != null) {
        await _cloudRequest('POST', '/api/v2/auth/logout');
      }
    } finally {
      await clearSession();
    }
  }

  Future<List<Map<String, dynamic>>> list(String path) async {
    await ensureLocalSession();
    final response = await http.get(
        Uri.parse(
            '$baseUrl/api/v2/files?path=${Uri.encodeQueryComponent(path)}'),
        headers: _headers);
    final data = _data(response, 200, '读取目录失败');
    return (data['items'] as List).cast<Map<String, dynamic>>();
  }

  Future<List<int>> download(String path) async {
    await ensureLocalSession();
    final response = await http.get(
        Uri.parse('$baseUrl/api/v2/files/${Uri.encodeComponent(path)}'),
        headers: _headers);
    if (response.statusCode != 200) throw Exception('下载失败');
    return response.bodyBytes;
  }

  Future<void> delete(String path) async {
    await ensureLocalSession();
    final response = await http.delete(
        Uri.parse('$baseUrl/api/v2/files/${Uri.encodeComponent(path)}'),
        headers: _headers);
    _data(response, 200, '删除失败');
  }

  Future<void> rename(String path, String destination) async {
    await ensureLocalSession();
    final response = await http.patch(
        Uri.parse('$baseUrl/api/v2/files/${Uri.encodeComponent(path)}'),
        headers: {..._headers, 'content-type': 'application/json'},
        body: jsonEncode({'path': destination}));
    _data(response, 200, '重命名失败');
  }

  Future<void> upload(
      PlatformFile file, String path, void Function(double) progress) async {
    await ensureLocalSession();
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    const chunkSize = 8 * 1024 * 1024;
    final destination = path.isEmpty ? file.name : '$path/${file.name}';
    final create = await http.post(Uri.parse('$baseUrl/api/v2/upload/sessions'),
        headers: {..._headers, 'content-type': 'application/json'},
        body: jsonEncode({
          'path': destination,
          'size': bytes.length,
          'chunkSize': chunkSize
        }));
    final createData = _data(create, 201, '创建上传任务失败');
    final uploadId = createData['uploadId'];
    final total = (bytes.length / chunkSize).ceil();
    for (var i = 0; i < total; i++) {
      final start = i * chunkSize;
      final end =
          (start + chunkSize > bytes.length) ? bytes.length : start + chunkSize;
      final response = await http.put(
          Uri.parse('$baseUrl/api/v2/upload/$uploadId/chunks/$i'),
          headers: _headers,
          body: bytes.sublist(start, end));
      _data(response, 200, '上传分片失败');
      progress((i + 1) / total);
    }
    final complete = await http.post(
        Uri.parse('$baseUrl/api/v2/upload/$uploadId/complete'),
        headers: _headers);
    _data(complete, 200, '合并文件失败');
  }

  Future<void> confirmClaim(String deviceId, String claimString,
      {String? claimRequestId}) async {
    final response =
        await _cloudRequest('POST', '/api/v2/devices/claim/confirm', body: {
      'deviceId': deviceId,
      'claimRequestId': claimRequestId,
      'claimString': claimString
    });
    _data(response, 200, '设备绑定失败');
  }

  Future<String> createSession(String deviceId) async {
    final response = await _cloudRequest('POST', '/api/v2/sessions',
        body: {'deviceId': deviceId});
    final data = _data(response, 201, '创建远程会话失败');
    return data['sessionId'] as String;
  }

  Future<List<Map<String, dynamic>>> remoteList(
      String deviceId, String path) async {
    final response = await _remoteRequest(deviceId, 'GET',
        '/api/v2/files?path=${Uri.encodeQueryComponent(path)}');
    final envelope = _remoteEnvelope(response, 200, '远程目录读取失败');
    return (envelope['items'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> remoteUpload(String deviceId, PlatformFile file, String path,
      void Function(double) progress) async {
    if (supportsRtc(deviceId)) {
      await (await transferManager()).upload(deviceId, file, path, progress);
      return;
    }
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    const chunkSize = 8 * 1024 * 1024;
    final destination = path.isEmpty ? file.name : '$path/${file.name}';
    final create = _remoteEnvelope(
        await _remoteRequest(
            deviceId,
            'POST',
            '/api/v2/upload/sessions',
            utf8.encode(jsonEncode({
              'path': destination,
              'size': bytes.length,
              'chunkSize': chunkSize
            }))),
        201,
        '创建远程上传任务失败');
    final uploadId = create['uploadId'] as String;
    final total = (bytes.length / chunkSize).ceil();
    for (var i = 0; i < total; i++) {
      final start = i * chunkSize;
      final end =
          (start + chunkSize > bytes.length) ? bytes.length : start + chunkSize;
      _remoteEnvelope(
          await _remoteRequest(deviceId, 'PUT',
              '/api/v2/upload/$uploadId/chunks/$i', bytes.sublist(start, end)),
          200,
          '上传远程分片失败');
      progress((i + 1) / total);
    }
    _remoteEnvelope(
        await _remoteRequest(
            deviceId, 'POST', '/api/v2/upload/$uploadId/complete'),
        200,
        '合并远程文件失败');
  }

  Future<List<int>> remoteDownload(String deviceId, String path,
      {int? start, int? end}) async {
    if (supportsRtc(deviceId) && start == null && end == null) {
      final task = await downloadTask(deviceId, path, (_) {});
      if (task.size > 16 * 1024 * 1024) {
        throw const TransferException('PREVIEW_TOO_LARGE', '请使用下载功能保存大文件');
      }
      return File(task.localPath).readAsBytes();
    }
    final range = start == null
        ? <String, String>{}
        : {'Range': 'bytes=$start-${end ?? ''}'};
    final response = await _remoteRequest(deviceId, 'GET',
        '/api/v2/files/${Uri.encodeComponent(path)}', null, range);
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw Exception('远程下载失败');
    }
    return response.bodyBytes;
  }

  Future<void> remoteDownloadToFile(
      String deviceId, String path, File destination) async {
    if (supportsRtc(deviceId)) {
      final task = await downloadTask(deviceId, path, (_) {});
      await File(task.localPath).openRead().pipe(destination.openWrite());
      return;
    }
    final existing =
        await destination.exists() ? await destination.length() : 0;
    final bytes = await remoteDownload(deviceId, path,
        start: existing == 0 ? null : existing);
    final sink = destination.openWrite(
        mode: existing == 0 ? FileMode.write : FileMode.append);
    sink.add(bytes);
    await sink.close();
  }

  Future<http.Response> _remoteRequest(
      String deviceId, String method, String target,
      [List<int>? body, Map<String, String> extraHeaders = const {}]) async {
    final sessionId = await createSession(deviceId);
    final base = Uri.parse(cloudBaseUrl);
    final prefix =
        base.path == '/' ? '' : base.path.replaceFirst(RegExp(r'/$'), '');
    final uri = base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '$prefix/api/v2/relay/app',
        queryParameters: {'sessionId': sessionId});
    final socket =
        await WebSocket.connect(uri.toString(), headers: _cloudHeaders);
    try {
      final payload = body ?? const <int>[];
      final headers = extraHeaders.entries
          .map((entry) => '${entry.key}: ${entry.value}\r\n')
          .join();
      final request = utf8.encode(
          '$method $target HTTP/1.1\r\nHost: se9\r\n${headers}Content-Length: ${payload.length}\r\nConnection: close\r\n\r\n');
      socket.add(Uint8List.fromList([...request, ...payload]));
      return await _receiveRemoteResponse(socket);
    } finally {
      await socket.close();
    }
  }

  Map<String, dynamic> _remoteEnvelope(
      http.Response response, int expectedStatus, String message) {
    if (response.statusCode != expectedStatus) throw Exception(message);
    final envelope = jsonDecode(response.body) as Map<String, dynamic>;
    if (envelope['code'] != '0') {
      throw Exception(envelope['message'] ?? message);
    }
    return (envelope['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  }

  Future<http.Response> _receiveRemoteResponse(WebSocket socket) async {
    final bytes = BytesBuilder();
    await for (final event in socket) {
      if (event is List<int>) bytes.add(event);
      final data = bytes.toBytes();
      final headerEnd = _headerEnd(data);
      if (headerEnd < 0) continue;
      final header = utf8.decode(data.sublist(0, headerEnd));
      final match = RegExp(r'Content-Length:\s*(\d+)', caseSensitive: false)
          .firstMatch(header);
      final contentLength = int.tryParse(match?.group(1) ?? '') ?? 0;
      if (data.length >= headerEnd + 4 + contentLength) {
        final statusParts = header.split(' ');
        final status =
            int.tryParse(statusParts.length > 1 ? statusParts[1] : '') ?? 502;
        return http.Response.bytes(
            data.sublist(headerEnd + 4, headerEnd + 4 + contentLength), status);
      }
    }
    throw Exception('远程连接已关闭');
  }

  int _headerEnd(List<int> data) {
    for (var i = 0; i + 3 < data.length; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  Map<String, dynamic> _data(
      http.Response response, int expectedStatus, String message) {
    if (response.statusCode != expectedStatus) throw Exception(message);
    final envelope = jsonDecode(response.body) as Map<String, dynamic>;
    if (envelope['code'] != '0') {
      throw Exception(envelope['message'] ?? message);
    }
    return (envelope['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
  }

  Map<String, String> get _headers =>
      {'authorization': 'Bearer ${token ?? ''}'};
  Map<String, String> get _cloudHeaders =>
      {'authorization': 'Bearer ${cloudToken ?? ''}'};
  Map<String, String> get headers => _headers;
  void check(http.Response response, int expectedStatus, String message) =>
      _data(response, expectedStatus, message);
  Future<http.Response> remoteRequest(
          String deviceId, String method, String target,
          [List<int>? body, Map<String, String> extraHeaders = const {}]) =>
      _remoteRequest(deviceId, method, target, body, extraHeaders);
}

class DiscoveredDevice {
  DiscoveredDevice(
      {required this.deviceId,
      required this.name,
      required this.address,
      required this.port,
      required this.apiBase,
      required this.claimStatus,
      required this.publicKey,
      required this.signature});
  final String deviceId;
  final String name;
  final InternetAddress address;
  final int port;
  final String apiBase;
  final String claimStatus;
  final String publicKey;
  final String signature;

  factory DiscoveredDevice.fromPacket(
      Datagram datagram, Map<String, dynamic> packet) {
    final body = (packet['body'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    return DiscoveredDevice(
      deviceId: packet['deviceId'] as String? ?? '',
      name: body['name'] as String? ?? 'SE9',
      address: datagram.address,
      port: (body['httpsPort'] as num?)?.toInt() ?? 8443,
      apiBase: body['apiBase'] as String? ?? '/api/v2',
      claimStatus: body['claimStatus'] as String? ?? 'unknown',
      publicKey: body['publicKey'] as String? ?? '',
      signature: packet['signature'] as String? ?? '',
    );
  }
}

class UdpDiscovery {
  final _ed25519 = Ed25519();
  final String configuredDeviceIp = const String.fromEnvironment(
      'SE9_DEVICE_IP',
      defaultValue: '201.31.10.106');
  void _log(String message) => debugPrint('[SE9-UDP] $message');

  Future<List<InternetAddress>> _broadcastTargets() async {
    final targets = <String>{};
    if (configuredDeviceIp.isNotEmpty) targets.add(configuredDeviceIp);
    try {
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      for (final network in interfaces) {
        for (final address in network.addresses) {
          final raw = address.rawAddress;
          if (raw.length == 4 && raw.any((value) => value != 0)) {
            targets.add('${raw[0]}.${raw[1]}.${raw[2]}.255');
          }
          _log('interface=${network.name} address=${address.address}');
        }
      }
    } catch (error) {
      _log('network interface enumeration failed: $error');
    }
    if (targets.isEmpty) {
      _log(
          'no non-loopback IPv4 interface found; UDP discovery cannot broadcast');
    }
    return targets.map(InternetAddress.new).toList();
  }

  Future<List<DiscoveredDevice>> discover(
      {Duration timeout = const Duration(seconds: 2)}) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    _log(
        'socket bound localPort=${socket.port}, broadcastEnabled=${socket.broadcastEnabled}');
    final requestId = '${DateTime.now().microsecondsSinceEpoch}';
    final nonce = '${DateTime.now().millisecondsSinceEpoch}-${socket.port}';
    final requestTimestamp = DateTime.now().millisecondsSinceEpoch;
    final request = jsonEncode({
      'version': 1,
      'type': 'discover_request',
      'requestId': requestId,
      'timestamp': requestTimestamp,
      'nonce': nonce,
      'body': {}
    });
    final payload = utf8.encode(request);
    final targets = await _broadcastTargets();
    for (final target in targets) {
      try {
        final sent = socket.send(payload, target, 37020);
        _log(
            'discover_request sent=$sent requestId=$requestId target=${target.address}:37020');
      } catch (error) {
        _log(
            'discover_request send failed target=${target.address}:37020 error=$error');
      }
    }
    final devices = <String, DiscoveredDevice>{};
    final packets = <String, Map<String, dynamic>>{};
    final completer = Completer<void>();
    late final StreamSubscription<RawSocketEvent> subscription;
    subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      try {
        final packet = (jsonDecode(utf8.decode(datagram.data)) as Map)
            .cast<String, dynamic>();
        _log(
            'packet received bytes=${datagram.data.length} from=${datagram.address.address}:${datagram.port} type=${packet['type']} requestId=${packet['requestId']}');
        if (packet['type'] != 'discover_response' ||
            packet['requestId'] != requestId) {
          return;
        }
        final device = DiscoveredDevice.fromPacket(datagram, packet);
        if (device.deviceId.isNotEmpty) {
          devices[device.deviceId] = device;
          packets[device.deviceId] = packet;
        }
      } catch (error) {
        _log('packet parse failed: $error');
      }
    });
    Timer(timeout, () {
      if (!completer.isCompleted) {
        _log('discover timeout after ${timeout.inMilliseconds}ms');
        completer.complete();
      }
    });
    await completer.future;
    await subscription.cancel();
    socket.close();
    final verified = <DiscoveredDevice>[];
    for (final device in devices.values) {
      final packet = packets[device.deviceId];
      if (packet != null) {
        final valid = await _verifyDiscovery(
            device, packet, requestId, requestTimestamp, nonce);
        _log('discovery signature device=${device.deviceId} valid=$valid');
        if (valid) verified.add(device);
      }
    }
    _log('discover completed devices=${verified.length}');
    return verified;
  }

  Future<bool> _verifyDiscovery(
      DiscoveredDevice device,
      Map<String, dynamic> packet,
      String requestId,
      int requestTimestamp,
      String nonce) async {
    try {
      final body = (packet['body'] as Map).cast<String, dynamic>();
      final canonicalBody = jsonEncode({
        'name': body['name'],
        'httpsPort': body['httpsPort'],
        'apiBase': body['apiBase'],
        'claimStatus': body['claimStatus'],
        'publicKey': body['publicKey'],
        'publicKeyFingerprint': body['publicKeyFingerprint'],
        'capabilities': body['capabilities']
      });
      final transcript = utf8.encode(
          '1|discover_response|$requestId|$requestTimestamp|$nonce|$canonicalBody');
      final publicKey = SimplePublicKey(base64Decode(device.publicKey),
          type: KeyPairType.ed25519);
      final signature =
          Signature(base64Decode(device.signature), publicKey: publicKey);
      return await _ed25519.verify(transcript, signature: signature);
    } catch (error) {
      _log('discovery signature verification failed: $error');
      return false;
    }
  }

  Future<PairingClaim?> pair(DiscoveredDevice device) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final eventStream = socket.asBroadcastStream();
    final keyPair = await X25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final requestId = '${DateTime.now().microsecondsSinceEpoch}';
    final nonce = '${DateTime.now().millisecondsSinceEpoch}-${socket.port}';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final handshake = jsonEncode({
      'version': 1,
      'type': 'handshake_request',
      'requestId': requestId,
      'timestamp': timestamp,
      'nonce': nonce,
      'appEphemeralPublicKey': base64Encode(publicKey.bytes),
      'body': {}
    });
    final responseFuture =
        _receive(socket, requestId, 'handshake_response', eventStream);
    final handshakeSent =
        socket.send(utf8.encode(handshake), device.address, 37020);
    _log(
        'handshake_request sent=$handshakeSent device=${device.deviceId} address=${device.address.address}:37020 requestId=$requestId');
    final response = await responseFuture;
    if (response == null) {
      _log('handshake_response timeout device=${device.deviceId}');
      socket.close();
      return null;
    }
    final responseBody = (response['body'] as Map).cast<String, dynamic>();
    final handshakeValid = await _verifyHandshake(
        device, response, responseBody, requestId, timestamp, nonce);
    _log(
        'handshake_response signature device=${device.deviceId} valid=$handshakeValid');
    if (!handshakeValid) {
      socket.close();
      return null;
    }
    final remote = SimplePublicKey(
        base64Decode(responseBody['deviceEphemeralPublicKey'] as String),
        type: KeyPairType.x25519);
    final shared = await X25519()
        .sharedSecretKey(keyPair: keyPair, remotePublicKey: remote);
    final sessionId = responseBody['lanSessionId'] as String;
    final pairingRequestId = '$requestId-pair';
    final pairing = jsonEncode({
      'version': 1,
      'type': 'pairing_request',
      'requestId': pairingRequestId,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'nonce': nonce,
      'lanSessionId': sessionId,
      'body': {}
    });
    final resultFuture = _receive(socket, pairingRequestId, 'pairing_result',
        eventStream, const Duration(seconds: 15));
    final pairingSent =
        socket.send(utf8.encode(pairing), device.address, 37020);
    _log(
        'pairing_request sent=$pairingSent device=${device.deviceId} requestId=$pairingRequestId');
    final result = await resultFuture;
    socket.close();
    if (result == null) {
      _log('pairing_result timeout device=${device.deviceId}');
      return null;
    }
    _log('pairing_result received device=${device.deviceId} encrypted=true');
    final body = (result['body'] as Map).cast<String, dynamic>();
    final cipher = AesGcm.with256bits();
    final plaintext = await cipher.decrypt(
        SecretBox(base64Decode(body['ciphertext'] as String),
            nonce: base64Decode(body['nonce'] as String),
            mac: Mac(base64Decode(body['tag'] as String))),
        secretKey: shared);
    final decoded =
        (jsonDecode(utf8.decode(plaintext)) as Map).cast<String, dynamic>();
    final expiresAt = (decoded['expiresAt'] as num?)?.toInt() ?? 0;
    if (decoded['deviceId'] != device.deviceId ||
        decoded['requestId'] != pairingRequestId ||
        expiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000) {
      _log('pairing_result validation failed device=${device.deviceId}');
      return null;
    }
    final claimString = decoded['claimString'] as String?;
    final decodedRequestId = decoded['requestId'] as String?;
    if (claimString == null || decodedRequestId == null) return null;
    return PairingClaim(claimString, decodedRequestId);
  }

  Future<bool> _verifyHandshake(
      DiscoveredDevice device,
      Map<String, dynamic> packet,
      Map<String, dynamic> body,
      String requestId,
      int requestTimestamp,
      String nonce) async {
    try {
      final canonicalBody = jsonEncode({
        'deviceEphemeralPublicKey': body['deviceEphemeralPublicKey'],
        'lanSessionId': body['lanSessionId'],
        'expiresAt': body['expiresAt'],
        'apiBase': body['apiBase']
      });
      final transcript = utf8.encode(
          '1|handshake_response|$requestId|$requestTimestamp|$nonce|$canonicalBody');
      final publicKey = SimplePublicKey(base64Decode(device.publicKey),
          type: KeyPairType.ed25519);
      final signature = Signature(base64Decode(packet['signature'] as String),
          publicKey: publicKey);
      return await _ed25519.verify(transcript, signature: signature);
    } catch (error) {
      _log('handshake signature verification failed: $error');
      return false;
    }
  }

  Future<Map<String, dynamic>?> _receive(
      RawDatagramSocket socket, String requestId, String type,
      [Stream<RawSocketEvent>? eventStream,
      Duration timeout = const Duration(seconds: 10)]) async {
    final completer = Completer<Map<String, dynamic>?>();
    late final StreamSubscription<RawSocketEvent> subscription;
    subscription = (eventStream ?? socket).listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      try {
        final packet = (jsonDecode(utf8.decode(datagram.data)) as Map)
            .cast<String, dynamic>();
        _log(
            'awaiting type=$type received type=${packet['type']} requestId=${packet['requestId']}');
        if (packet['type'] == type &&
            packet['requestId'] == requestId &&
            !completer.isCompleted) {
          completer.complete(packet);
        }
      } catch (error) {
        _log('response parse failed type=$type error=$error');
      }
    });
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _log('response timeout type=$type requestId=$requestId');
        completer.complete(null);
      }
    });
    final result = await completer.future;
    timer.cancel();
    await subscription.cancel();
    return result;
  }
}

class PairingClaim {
  const PairingClaim(this.claimString, this.requestId);
  final String claimString;
  final String requestId;
}

class BoundDevice {
  const BoundDevice(
      {required this.deviceId,
      required this.name,
      required this.status,
      this.lastSeen,
      this.supportsRtc = false});
  factory BoundDevice.fromJson(Map<String, dynamic> json) => BoundDevice(
        deviceId: json['deviceId'] as String,
        name: json['name'] as String? ?? 'SE9 NAS',
        status: json['status'] as String? ?? 'offline',
        lastSeen: DateTime.tryParse(json['lastSeen'] as String? ?? ''),
        supportsRtc:
            ((json['capabilities'] as Map?)?['transports'] as List? ?? [])
                .contains('webrtc'),
      );
  final String deviceId;
  final String name;
  final String status;
  final DateTime? lastSeen;
  final bool supportsRtc;
  bool get online => status == 'online';
}

class FilePage extends StatefulWidget {
  const FilePage({super.key, this.api});
  final Se9Api? api;
  @override
  State<FilePage> createState() => _FilePageState();
}

class _FilePageState extends State<FilePage> with WidgetsBindingObserver {
  late final api = widget.api ??
      Se9Api(const String.fromEnvironment('SE9_API', defaultValue: ''));
  final pathController = TextEditingController(text: '');
  List<Map<String, dynamic>> files = [];
  double? progress;
  String message = '未登录';
  FileTransferTask? currentTransfer;
  final discovery = UdpDiscovery();
  List<DiscoveredDevice> devices = [];
  bool discovering = false;
  BoundDevice? activeRemoteDevice;
  List<BoundDevice> boundDevices = [];
  bool loadingDevices = false;
  bool loadingFiles = false;
  bool downloading = false;
  String? deviceListError;
  int deviceListRequest = 0;
  int fileRequest = 0;
  bool get busy => progress != null || loadingFiles || downloading;
  bool get canUseFiles =>
      !busy && (activeRemoteDevice?.online ?? (api.token != null));
  String searchQuery = '';
  Timer? sessionTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    api.onTransferChanged = (task) {
      if (mounted) setState(() => currentTransfer = task);
    };
    restoreLoginState();
    sessionTimer = Timer.periodic(const Duration(minutes: 10), (_) async {
      try {
        await api.refreshIfNeeded();
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    sessionTimer?.cancel();
    api.onTransferChanged = null;
    api.pauseTransfer();
    pathController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) api.pauseTransfer();
    if (state == AppLifecycleState.resumed) restoreLoginState();
  }

  Future<void> restoreLoginState() async {
    try {
      final restored = await api.restoreSession();
      if (!mounted || !restored) return;
      setState(() => message = '已恢复登录状态');
      await loadBoundDevices();
    } catch (_) {}
  }

  Future<void> loadBoundDevices() async {
    if (api.cloudToken == null) return;
    final request = ++deviceListRequest;
    setState(() {
      loadingDevices = true;
      deviceListError = null;
    });
    try {
      final result = await api.deviceList();
      if (result.any((d) => d.supportsRtc)) await api.transferManager();
      if (!mounted || request != deviceListRequest) return;
      setState(() {
        boundDevices = result;
        if (activeRemoteDevice != null) {
          final matches =
              result.where((d) => d.deviceId == activeRemoteDevice!.deviceId);
          activeRemoteDevice = matches.isEmpty ? null : matches.first;
          if (activeRemoteDevice == null || !activeRemoteDevice!.online) {
            fileRequest++;
            loadingFiles = false;
            files = [];
          }
        }
      });
    } catch (e) {
      if (mounted && request == deviceListRequest) {
        setState(() => deviceListError = '$e');
      }
    } finally {
      if (mounted && request == deviceListRequest) {
        setState(() => loadingDevices = false);
      }
    }
  }

  void selectRemoteDevice(BoundDevice device) {
    if (activeRemoteDevice?.deviceId != device.deviceId) {
      fileRequest++;
      pathController.clear();
      files = [];
      searchQuery = '';
    }
    activeRemoteDevice = device;
  }

  Future<void> logout() async {
    deviceListRequest++;
    fileRequest++;
    setState(() {
      boundDevices = [];
      activeRemoteDevice = null;
      files = [];
      pathController.clear();
      loadingDevices = false;
      loadingFiles = false;
      deviceListError = null;
    });
    try {
      await api.logout();
    } catch (_) {}
    if (mounted) setState(() => message = '已退出登录');
  }

  Future<bool> configureDeviceUrl() async {
    final controller = TextEditingController(
        text: api.baseUrl.isEmpty ? 'http://192.168.1.50:8443' : api.baseUrl);
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('连接设备'),
                content: TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                        labelText: '设备地址',
                        hintText: 'http://192.168.1.50:8443')),
                actions: [
                  IconButton(
                      tooltip: '传输任务',
                      onPressed:
                          api.cloudToken == null ? null : showTransferTasks,
                      icon: const Icon(Icons.swap_vert)),
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, controller.text.trim()),
                      child: const Text('连接'))
                ]));
    if (value == null || value.isEmpty) return false;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      if (mounted) setState(() => message = '设备地址格式错误');
      return false;
    }
    api.baseUrl = value.replaceFirst(RegExp(r'/$'), '');
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('se9.device.baseUrl', api.baseUrl);
    return true;
  }

  Future<void> discoverDevices() async {
    setState(() => discovering = true);
    try {
      final result = await discovery.discover();
      if (mounted) {
        setState(() {
          devices = result;
          message = result.isEmpty ? '未发现设备' : '发现 ${result.length} 台设备';
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = '设备发现失败: $e');
    } finally {
      if (mounted) setState(() => discovering = false);
    }
  }

  Future<void> pairDevice(DiscoveredDevice device) async {
    try {
      api.baseUrl = 'http://${device.address.address}:${device.port}';
      final claim = await discovery.pair(device);
      if (claim == null) {
        if (mounted) setState(() => message = '绑定交换失败');
        return;
      }
      await api.confirmClaim(device.deviceId, claim.claimString,
          claimRequestId: claim.requestId);
      if (!mounted) return;
      setState(() => message = '设备绑定成功');
      await loadBoundDevices();
    } catch (e) {
      if (mounted) setState(() => message = '绑定交换失败: $e');
    }
  }

  Future<Map<String, String>?> promptCredentials(
      {bool registration = false}) async {
    final account = TextEditingController();
    final password = TextEditingController();
    final confirm = TextEditingController();
    final nickname = TextEditingController();
    return showDialog<Map<String, String>>(
        context: context,
        builder: (context) => AlertDialog(
                title: Text(registration ? '注册账号' : '登录'),
                content: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: account,
                      decoration: const InputDecoration(labelText: '账号')),
                  if (registration)
                    TextField(
                        controller: nickname,
                        decoration: const InputDecoration(labelText: '昵称')),
                  TextField(
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '密码')),
                  if (registration)
                    TextField(
                        controller: confirm,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '确认密码'))
                ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () {
                        if (account.text.trim().isEmpty ||
                            password.text.length < 8 ||
                            (registration && password.text != confirm.text)) {
                          return;
                        }
                        Navigator.pop(context, {
                          'account': account.text.trim(),
                          'password': password.text,
                          'nickname': nickname.text.trim()
                        });
                      },
                      child: Text(registration ? '注册' : '登录'))
                ]));
  }

  Future<void> remoteList(BoundDevice device) async {
    if (busy) return;
    if (!device.online) {
      setState(() => message = '设备离线，请启动 NAS 后刷新设备列表');
      return;
    }
    setState(() => selectRemoteDevice(device));
    await refresh();
  }

  Future<void> createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('新建文件夹'),
                content: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: '文件夹名称')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, controller.text.trim()),
                      child: const Text('创建'))
                ]));
    if (name == null || name.isEmpty) return;
    final folderPath =
        pathController.text.isEmpty ? name : '${pathController.text}/$name';
    try {
      if (activeRemoteDevice == null) {
        final response = await http.post(
            Uri.parse('${api.baseUrl}/api/v2/folders'),
            headers: {...api.headers, 'content-type': 'application/json'},
            body: jsonEncode({'path': folderPath}));
        api.check(response, 201, '创建文件夹失败');
      } else {
        final response = await api.remoteRequest(
            activeRemoteDevice!.deviceId,
            'POST',
            '/api/v2/folders',
            utf8.encode(jsonEncode({'path': folderPath})));
        if (response.statusCode != 201) throw Exception('创建文件夹失败');
      }
      await refresh();
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> downloadFile(Map<String, dynamic> file) async {
    if (busy) return;
    setState(() => downloading = true);
    final path = file['path'] as String? ?? '';
    final name = file['name'] as String? ?? 'download.bin';
    try {
      String? saved;
      final device = activeRemoteDevice;
      if (device != null && api.supportsRtc(device.deviceId)) {
        final task = await api.downloadTask(device.deviceId, path, (value) {
          if (mounted) setState(() => progress = value);
        });
        saved = await TransferFileExport.save(File(task.localPath), name);
      } else {
        final bytes = device == null
            ? await api.download(path)
            : await api.remoteDownload(device.deviceId, path);
        saved = await FilePicker.platform
            .saveFile(fileName: name, bytes: Uint8List.fromList(bytes));
      }
      if (mounted) {
        setState(() => message = saved == null ? '已取消保存' : '已保存 $name');
      }
    } catch (e) {
      if (mounted) setState(() => message = '下载失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          downloading = false;
          progress = null;
        });
      }
    }
  }

  Future<void> previewFile(Map<String, dynamic> file) async {
    final name = file['name'] as String? ?? '';
    final lower = name.toLowerCase();
    if (!(lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif'))) {
      setState(() => message = '当前仅支持图片预览');
      return;
    }
    try {
      final path = file['path'] as String;
      final bytes = activeRemoteDevice == null
          ? await api.download(path)
          : await api.remoteDownload(activeRemoteDevice!.deviceId, path);
      if (!mounted) return;
      showDialog(
          context: context,
          builder: (_) => Dialog(
              child: InteractiveViewer(
                  child: Image.memory(Uint8List.fromList(bytes),
                      fit: BoxFit.contain))));
    } catch (e) {
      if (mounted) setState(() => message = '预览失败: $e');
    }
  }

  Future<void> deleteFile(Map<String, dynamic> file) async {
    final path = file['path'] as String? ?? '';
    try {
      if (activeRemoteDevice == null) {
        await api.delete(path);
      } else {
        final response = await api.remoteRequest(activeRemoteDevice!.deviceId,
            'DELETE', '/api/v2/files/${Uri.encodeComponent(path)}');
        if (response.statusCode != 200) throw Exception('删除失败');
      }
      await refresh();
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> renameFile(Map<String, dynamic> file) async {
    final oldPath = file['path'] as String? ?? '';
    final controller = TextEditingController(text: oldPath);
    final destination = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('重命名/移动'),
                content: TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: '目标路径')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () =>
                          Navigator.pop(context, controller.text.trim()),
                      child: const Text('保存'))
                ]));
    if (destination == null || destination.isEmpty || destination == oldPath) {
      return;
    }
    try {
      if (activeRemoteDevice == null) {
        await api.rename(oldPath, destination);
      } else {
        final response = await api.remoteRequest(
            activeRemoteDevice!.deviceId,
            'PATCH',
            '/api/v2/files/${Uri.encodeComponent(oldPath)}',
            utf8.encode(jsonEncode({'path': destination})));
        if (response.statusCode != 200) throw Exception('重命名失败');
      }
      await refresh();
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> pickAndRemoteUpload(BoundDevice device) async {
    if (busy || !device.online) return;
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text('上传到 ${device.name}')),
        ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('从相册选择图片'),
            onTap: () => Navigator.pop(context, 'images')),
        ListTile(
            leading: const Icon(Icons.video_library),
            title: const Text('从相册选择视频'),
            onTap: () => Navigator.pop(context, 'video')),
        ListTile(
            leading: const Icon(Icons.insert_drive_file),
            title: const Text('选择文件'),
            onTap: () => Navigator.pop(context, 'files')),
      ])),
    );
    if (source == null || !mounted) return;
    setState(() => selectRemoteDevice(device));
    if (source != 'files') {
      await pickFromGallery(source: source, remoteDevice: device);
      return;
    }
    final result = await FilePicker.platform
        .pickFiles(withData: false, allowMultiple: true);
    if (result == null || !mounted) return;
    await uploadPickedFiles(result.files, device);
  }

  Future<void> login() async {
    if (api.cloudToken != null) {
      await accountInfo();
      return;
    }
    final credentials = await promptCredentials();
    if (credentials == null) return;
    try {
      await api.login(credentials['account']!, credentials['password']!);
      if (!mounted) return;
      setState(() => message = '登录成功，请从我的设备中选择设备');
      await loadBoundDevices();
    } catch (e) {
      setState(() => message = '登录失败：$e');
    }
  }

  Future<void> register() async {
    final credentials = await promptCredentials(registration: true);
    if (credentials == null) return;
    try {
      await api.registerCloud(credentials['account']!, credentials['password']!,
          credentials['nickname'] ?? '');
      if (!mounted) return;
      setState(() => message = '注册成功，请发现并绑定设备');
      await loadBoundDevices();
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> accountActions() async {
    if (api.cloudToken == null) {
      if (!mounted) return;
      await showModalBottomSheet<void>(
          context: context,
          builder: (context) => SafeArea(
                  child: Wrap(children: [
                ListTile(
                    leading: const Icon(Icons.person_add),
                    title: const Text('注册账号'),
                    onTap: () {
                      Navigator.pop(context);
                      register();
                    }),
                ListTile(
                    leading: const Icon(Icons.lock_reset),
                    title: const Text('忘记密码'),
                    onTap: () {
                      Navigator.pop(context);
                      forgotPasswordDialog();
                    })
              ])));
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
                child: Wrap(children: [
              ListTile(
                  leading: const Icon(Icons.person),
                  title: const Text('账号信息'),
                  onTap: () {
                    Navigator.pop(context);
                    accountInfo();
                  }),
              ListTile(
                  leading: const Icon(Icons.password),
                  title: const Text('修改密码'),
                  onTap: () {
                    Navigator.pop(context);
                    changePasswordDialog();
                  }),
              ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('退出登录'),
                  onTap: busy
                      ? null
                      : () {
                          Navigator.pop(context);
                          logout();
                        })
            ])));
  }

  Future<void> accountInfo() async {
    try {
      final info = await api.accountInfo();
      if (!mounted) return;
      showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
                  title: const Text('账号信息'),
                  content: Text(
                      '账号：${info['account']}\n昵称：${info['nickname'] ?? ''}\n用户 ID：${info['userId']}'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭'))
                  ]));
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> changePasswordDialog() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('修改密码'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: current,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '当前密码')),
                  TextField(
                      controller: next,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '新密码')),
                  TextField(
                      controller: confirm,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '确认新密码'))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context,
                          next.text.length >= 8 && next.text == confirm.text),
                      child: const Text('保存'))
                ]));
    if (ok == true) {
      try {
        await api.changePassword(current.text, next.text);
        if (mounted) setState(() => message = '密码已修改');
      } catch (e) {
        if (mounted) setState(() => message = '$e');
      }
    }
  }

  Future<void> forgotPasswordDialog() async {
    final account = TextEditingController();
    final code = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
                title: const Text('忘记密码'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(
                      controller: account,
                      decoration: const InputDecoration(labelText: '账号')),
                  TextField(
                      controller: code,
                      decoration: const InputDecoration(labelText: 'Demo 重置码')),
                  TextField(
                      controller: next,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '新密码')),
                  TextField(
                      controller: confirm,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '确认新密码'))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context,
                          next.text.length >= 8 && next.text == confirm.text),
                      child: const Text('重置'))
                ]));
    if (ok == true) {
      try {
        await api.resetPassword(account.text.trim(), code.text, next.text);
        if (mounted) setState(() => message = '密码已重置，请重新登录');
      } catch (e) {
        if (mounted) setState(() => message = '$e');
      }
    }
  }

  Future<void> refresh() async {
    if (loadingFiles) return;
    final target = activeRemoteDevice;
    final path = pathController.text;
    if (target != null && !target.online) {
      setState(() => message = '设备离线，请启动 NAS 后刷新设备列表');
      return;
    }
    if (target == null && api.token == null) {
      setState(() => message = '请从我的设备中选择设备');
      return;
    }
    final request = ++fileRequest;
    setState(() => loadingFiles = true);
    try {
      final value = target == null
          ? await api.list(path)
          : await api.remoteList(target.deviceId, path);
      if (mounted && request == fileRequest) {
        setState(() {
          files = value;
          message = target == null ? '目录已刷新' : '已打开 ${target.name}';
        });
      }
    } catch (e) {
      if (mounted && request == fileRequest) {
        setState(() => message = '读取文件失败: $e');
      }
    } finally {
      if (mounted && request == fileRequest) {
        setState(() => loadingFiles = false);
      }
    }
  }

  Future<void> pickAndUpload() async {
    if (busy) return;
    final target = activeRemoteDevice;
    final result = await FilePicker.platform
        .pickFiles(withData: false, allowMultiple: true);
    if (result == null || !mounted) return;
    await uploadPickedFiles(result.files, target);
  }

  Future<void> uploadPickedFiles(
      List<PlatformFile> selected, BoundDevice? target) async {
    final targetPath = pathController.text;
    setState(() => progress = 0);
    try {
      for (final file in selected) {
        void update(double value) {
          if (mounted) setState(() => progress = value);
        }

        if (target == null) {
          await api.upload(file, targetPath, update);
        } else {
          await api.remoteUpload(target.deviceId, file, targetPath, update);
        }
      }
      if (!mounted) return;
      await refresh();
      if (mounted) {
        setState(
            () => message = target == null ? '文件上传完成' : '已上传到 ${target.name}');
      }
    } catch (e) {
      if (mounted) setState(() => message = '上传失败: $e');
    } finally {
      if (mounted) setState(() => progress = null);
    }
  }

  Future<void> uploadMedia(String name, List<int> bytes) async {
    final media = PlatformFile(
        name: name, size: bytes.length, bytes: Uint8List.fromList(bytes));
    if (activeRemoteDevice == null) {
      await api.upload(media, pathController.text,
          (value) => setState(() => progress = value));
    } else {
      await api.remoteUpload(activeRemoteDevice!.deviceId, media,
          pathController.text, (value) => setState(() => progress = value));
    }
  }

  Future<void> pickFromGallery(
      {String? source, BoundDevice? remoteDevice}) async {
    final targetDevice = remoteDevice ?? activeRemoteDevice;
    final targetPath = pathController.text;
    final action = source ??
        await showModalBottomSheet<String>(
            context: context,
            builder: (context) => SafeArea(
                    child: Wrap(children: [
                  ListTile(
                      leading: const Icon(Icons.photo_library),
                      title: const Text('选择图片'),
                      onTap: () => Navigator.pop(context, 'images')),
                  ListTile(
                      leading: const Icon(Icons.video_library),
                      title: const Text('选择视频'),
                      onTap: () => Navigator.pop(context, 'video'))
                ])));
    if (action == null || !mounted) return;
    final picker = ImagePicker();
    try {
      final List<XFile> media;
      if (action == 'images') {
        media = await picker.pickMultiImage();
      } else {
        final video = await picker.pickVideo(source: ImageSource.gallery);
        media = video == null ? [] : [video];
      }
      if (media.isEmpty || !mounted) return;
      setState(() => progress = 0);
      for (final item in media) {
        final file = PlatformFile(
            name: item.name, size: await item.length(), path: item.path);
        void updateProgress(double value) {
          if (mounted) setState(() => progress = value);
        }

        if (targetDevice == null) {
          await api.upload(file, targetPath, updateProgress);
        } else {
          await api.remoteUpload(
              targetDevice.deviceId, file, targetPath, updateProgress);
        }
      }
      await refresh();
      if (mounted) {
        setState(() => message =
            targetDevice == null ? '相册媒体上传完成' : '已上传到 ${targetDevice.name}');
      }
    } catch (e) {
      if (mounted) setState(() => message = '相册媒体上传失败: $e');
    } finally {
      if (mounted) setState(() => progress = null);
    }
  }

  Future<void> showTransferTasks() async {
    try {
      final manager = await api.transferManager();
      if (!mounted) return;
      await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (sheet) => StatefulBuilder(
              builder: (context, update) => SizedBox(
                  height: MediaQuery.sizeOf(context).height * .7,
                  child: ListView(children: [
                    const ListTile(title: Text('传输任务')),
                    for (final task in manager.tasks.reversed)
                      ListTile(
                          title: Text(task.name),
                          subtitle: Text(
                              '${task.state} · ${(task.progress * 100).toStringAsFixed(1)}% · ${task.transport}\n${task.error}'),
                          isThreeLine: task.error.isNotEmpty,
                          trailing: PopupMenuButton<String>(
                              onSelected: (action) async {
                                Navigator.pop(sheet);
                                try {
                                  if (action == 'pause') manager.requestPause();
                                  if (action == 'cancel') {
                                    await manager.cancelTask(task);
                                  }
                                  if (action == 'save') {
                                    await TransferFileExport.save(
                                        File(task.localPath), task.name);
                                  }
                                  if (action == 'resume') {
                                    if (mounted) setState(() => progress = 0);
                                    await manager.resumeTask(task, (value) {
                                      if (mounted) {
                                        setState(() => progress = value);
                                      }
                                    });
                                  }
                                } catch (error) {
                                  if (mounted) {
                                    setState(() => message = '$error');
                                  }
                                } finally {
                                  if (mounted && action == 'resume') {
                                    setState(() => progress = null);
                                  }
                                }
                              },
                              itemBuilder: (_) => [
                                    if (!task.terminal)
                                      const PopupMenuItem(
                                          value: 'pause', child: Text('暂停')),
                                    if (!task.terminal && !busy)
                                      const PopupMenuItem(
                                          value: 'resume', child: Text('继续传输')),
                                    if (!task.terminal)
                                      const PopupMenuItem(
                                          value: 'cancel', child: Text('取消任务')),
                                    if (task.state == 'completed' &&
                                        task.direction == 'download')
                                      const PopupMenuItem(
                                          value: 'save', child: Text('保存文件')),
                                  ])),
                  ]))));
    } catch (error) {
      if (mounted) setState(() => message = '$error');
    }
  }

  Widget buildBoundDevices() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
              child:
                  Text('我的设备', style: TextStyle(fontWeight: FontWeight.bold))),
          IconButton(
              tooltip: '刷新设备列表',
              onPressed: api.cloudToken == null || loadingDevices || busy
                  ? null
                  : loadBoundDevices,
              icon: const Icon(Icons.refresh)),
        ]),
        if (loadingDevices) const LinearProgressIndicator(),
        if (deviceListError != null) Text('设备列表加载失败：$deviceListError'),
        if (!loadingDevices && deviceListError == null && boundDevices.isEmpty)
          Text(
              api.cloudToken == null ? '登录后查看账号绑定的设备' : '暂无绑定设备，请点击右上角发现设备并绑定'),
        if (boundDevices.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.3),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: boundDevices.length,
              itemBuilder: (_, index) {
                final device = boundDevices[index];
                final selected =
                    activeRemoteDevice?.deviceId == device.deviceId;
                return Card(
                  color: selected
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(device.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            Text(
                                device.online
                                    ? '在线${selected ? ' · 当前设备' : ''}'
                                    : '离线',
                                style: TextStyle(
                                    color: device.online
                                        ? Colors.green.shade800
                                        : Colors.grey)),
                            Text(device.deviceId,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall),
                          ])),
                      TextButton(
                          onPressed: device.online && !busy
                              ? () => remoteList(device)
                              : null,
                          child: const Text('文件 / 下载')),
                      TextButton(
                          onPressed: device.online && !busy
                              ? () => pickAndRemoteUpload(device)
                              : null,
                          child: const Text('上传')),
                    ]),
                  ),
                );
              },
            ),
          ),
      ]);

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(activeRemoteDevice == null
                ? 'SE9 文件管理'
                : 'SE9 · ${activeRemoteDevice!.name}'),
            actions: [
              IconButton(
                  tooltip: '账号',
                  onPressed: busy ? null : accountActions,
                  icon: const Icon(Icons.account_circle)),
              IconButton(
                  tooltip: '连接本地设备',
                  onPressed: busy ? null : configureDeviceUrl,
                  icon: const Icon(Icons.settings)),
              IconButton(
                  tooltip: api.cloudToken == null ? '登录' : '已登录：账号信息',
                  onPressed: busy ? null : login,
                  icon: Icon(api.cloudToken == null
                      ? Icons.login
                      : Icons.verified_user)),
              IconButton(
                  tooltip: '发现并绑定设备',
                  onPressed: discovering || busy ? null : discoverDevices,
                  icon: const Icon(Icons.wifi_find)),
            ]),
        body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              buildBoundDevices(),
              if (currentTransfer != null && progress != null)
                Row(children: [
                  Expanded(
                      child: Text(
                          '${currentTransfer!.name} · ${currentTransfer!.transport} · ${currentTransfer!.state}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis)),
                  IconButton(
                      tooltip: '暂停传输',
                      onPressed: api.pauseTransfer,
                      icon: const Icon(Icons.pause)),
                ]),
              if (devices.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 112),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: devices.length,
                    itemBuilder: (_, i) {
                      final d = devices[i];
                      final bound = boundDevices
                          .any((device) => device.deviceId == d.deviceId);
                      return Card(
                          child: ListTile(
                        title: Text(d.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${d.address.address}:${d.port}'),
                        trailing: TextButton(
                            onPressed:
                                bound || busy ? null : () => pairDevice(d),
                            child: Text(bound ? '已绑定' : '绑定')),
                      ));
                    },
                  ),
                ),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: pathController,
                        enabled: !busy,
                        decoration:
                            const InputDecoration(labelText: '目录路径（留空为根目录）'),
                        onSubmitted: (_) => refresh())),
                IconButton(
                    tooltip: '刷新文件',
                    onPressed: canUseFiles ? refresh : null,
                    icon: const Icon(Icons.refresh)),
                IconButton(
                    tooltip: '新建文件夹',
                    onPressed: canUseFiles ? createFolder : null,
                    icon: const Icon(Icons.create_new_folder)),
              ]),
              Row(children: [
                Expanded(
                    child: TextField(
                        decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            labelText: '搜索当前目录'),
                        onChanged: (value) => setState(
                            () => searchQuery = value.trim().toLowerCase()))),
                IconButton(
                    tooltip: '上传相册图片或视频',
                    onPressed: canUseFiles ? pickFromGallery : null,
                    icon: const Icon(Icons.photo_library)),
                IconButton(
                    tooltip: '上传文件',
                    onPressed: canUseFiles ? pickAndUpload : null,
                    icon: const Icon(Icons.upload_file)),
              ]),
              if (progress != null) LinearProgressIndicator(value: progress),
              if (loadingFiles || downloading) const LinearProgressIndicator(),
              Align(alignment: Alignment.centerLeft, child: Text(message)),
              Expanded(child: Builder(builder: (_) {
                final visibleFiles = files
                    .where((file) =>
                        searchQuery.isEmpty ||
                        (file['name'] as String? ?? '')
                            .toLowerCase()
                            .contains(searchQuery))
                    .toList();
                if (visibleFiles.isEmpty && !loadingFiles) {
                  return Center(
                      child: Text(activeRemoteDevice == null
                          ? '选择设备后查看文件'
                          : '当前目录暂无文件'));
                }
                return ListView.builder(
                    itemCount: visibleFiles.length,
                    itemBuilder: (_, i) {
                      final f = visibleFiles[i];
                      final directory = f['directory'] == true;
                      return ListTile(
                        leading: Icon(
                            directory ? Icons.folder : Icons.insert_drive_file),
                        title: Text(f['name'] as String),
                        subtitle: Text(directory ? '目录' : '${f['size']} bytes'),
                        onTap: directory && canUseFiles
                            ? () {
                                pathController.text = f['path'] as String;
                                refresh();
                              }
                            : null,
                        trailing: directory
                            ? null
                            : Row(mainAxisSize: MainAxisSize.min, children: [
                                IconButton(
                                    tooltip: '下载',
                                    onPressed: canUseFiles
                                        ? () => downloadFile(f)
                                        : null,
                                    icon: const Icon(Icons.download)),
                                PopupMenuButton<String>(
                                    enabled: canUseFiles,
                                    onSelected: (action) {
                                      if (action == 'download') downloadFile(f);
                                      if (action == 'preview') previewFile(f);
                                      if (action == 'rename') renameFile(f);
                                      if (action == 'delete') deleteFile(f);
                                    },
                                    itemBuilder: (_) => [
                                          const PopupMenuItem(
                                              value: 'download',
                                              child: Text('下载')),
                                          const PopupMenuItem(
                                              value: 'preview',
                                              child: Text('预览')),
                                          const PopupMenuItem(
                                              value: 'rename',
                                              child: Text('重命名/移动')),
                                          const PopupMenuItem(
                                              value: 'delete',
                                              child: Text('删除')),
                                        ]),
                              ]),
                      );
                    });
              })),
            ])),
      );
}
