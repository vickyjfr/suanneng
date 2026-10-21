import 'dart:async';
import 'rtc_probe_check.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

class LoopbackCertificateOverride extends HttpOverrides {
  LoopbackCertificateOverride(this.expectedDer);
  final String expectedDer;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..badCertificateCallback = (certificate, host, port) =>
            host == '127.0.0.1' && base64Encode(certificate.der) == expectedDer;
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<int> freePort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    throw ArgumentError(
        'cloud-binary agent-binary file-api-binary rtc-probe-binary');
  }
  final directory = await Directory.systemTemp.createTemp('se9-local-check-');
  final processes = <Process>[];
  final logs = <IOSink>[];
  RawDatagramSocket? udp;
  StreamSubscription<RawSocketEvent>? subscription;
  final packets = StreamController<Map<String, dynamic>>.broadcast();
  final cloudPort = await freePort();
  final apiPort = await freePort();
  final tls = Platform.environment['SE9_TEST_TLS'] == '1';
  final autoConfig = Platform.environment['SE9_TEST_AUTOCONFIG'] == '1';
  final cloud = '${tls ? 'https' : 'http'}://127.0.0.1:$cloudPort';
  final files = 'http://127.0.0.1:$apiPort';
  const proxyToken = 'local-test-proxy-token';
  Future<void> start(
      String binary, Map<String, String> environment, String name) async {
    final process = await Process.start(binary, [], environment: environment);
    processes.add(process);
    final log = File('${directory.path}/$name.log').openWrite();
    logs.add(log);
    process.stdout.listen(log.add);
    process.stderr.listen(log.add);
  }

  Future<void> ready(String url) async {
    for (var attempt = 0; attempt < 80; attempt++) {
      try {
        if ((await http.get(Uri.parse(url)).timeout(const Duration(seconds: 1)))
                .statusCode ==
            200) {
          return;
        }
      } catch (error) {
        if (attempt == 79) {
          stderr.writeln('Service readiness error: $error');
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('service not ready: $url');
  }

  Map<String, dynamic> data(http.Response response, int status) {
    check(response.statusCode == status,
        'HTTP ${response.statusCode}, expected $status');
    final envelope = jsonDecode(response.body) as Map<String, dynamic>;
    check(envelope['code'] == '0', 'business response rejected');
    return (envelope['data'] as Map).cast<String, dynamic>();
  }

  try {
    if (tls) {
      final certificate = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=se9-local-test',
        '-addext',
        'subjectAltName=IP:127.0.0.1',
        '-keyout',
        '${directory.path}/tls.key',
        '-out',
        '${directory.path}/tls.crt'
      ]);
      check(certificate.exitCode == 0, 'test IP certificate generation failed');
      SecurityContext.defaultContext
          .setTrustedCertificates('${directory.path}/tls.crt');
      final pem = await File('${directory.path}/tls.crt').readAsLines();
      HttpOverrides.global = LoopbackCertificateOverride(
          pem.where((line) => !line.startsWith('-----')).join());
    }
    await start(
        args[0],
        {
          'RTC_ENABLED': '1',
          if (Platform.environment['SE9_TEST_TURN'] == '1')
            'TURN_URLS': Platform.environment['SE9_TEST_TURN_URL'] ??
                'turn:127.0.0.1:34789?transport=udp',
          if (Platform.environment['SE9_TEST_TURN'] == '1')
            'TURN_SHARED_SECRET_FILE':
                Platform.environment['SE9_TEST_TURN_SECRET']!,
          'RTC_ALLOW_INSECURE_LOCAL': tls ? '0' : '1',
          if (tls) 'TLS_CERT_FILE': '${directory.path}/tls.crt',
          if (tls) 'TLS_KEY_FILE': '${directory.path}/tls.key',
          'RTC_GRANT_KEY_FILE': '${directory.path}/grant.pem',
          'PORT': '$cloudPort',
          'LISTEN_ADDR': '127.0.0.1:$cloudPort',
          'AUTH_STATE_FILE': '${directory.path}/refresh.json',
          'CLOUD_STATE_FILE': '${directory.path}/state.json',
          'DEMO_ADMIN_PASSWORD': 'test-password'
        },
        'cloud');
    await start(
        args[2],
        {
          'FILE_API_BIND_ADDR': '127.0.0.1',
          'FILE_API_PORT': '$apiPort',
          'STORAGE_ROOT': '${directory.path}/storage',
          if (!autoConfig) 'SE9_AGENT_PROXY_TOKEN': proxyToken,
          'SE9_AGENT_PROXY_TOKEN_FILE': '${directory.path}/proxy-key',
          'DEMO_ADMIN_PASSWORD': 'test-password'
        },
        'file-api');
    await ready('$cloud/health');
    await ready('$files/api/v2/health');
    final keyExport = await Process.run('openssl', [
      'pkey',
      '-in',
      '${directory.path}/grant.pem',
      '-pubout',
      '-out',
      '${directory.path}/grant-public.pem'
    ]);
    check(keyExport.exitCode == 0, 'grant public key export failed');
    await start(
        args[1],
        {
          if (!autoConfig) 'SE9_RTC_ENABLED': '1',
          'SE9_RTC_ALLOW_INSECURE_LOCAL': tls ? '0' : '1',
          if (tls) 'SE9_CA_FILE': '${directory.path}/tls.crt',
          'SE9_CLOUD_GRANT_PUBLIC_KEY': '${directory.path}/grant-public.pem',
          'FILE_API_PORT': '$apiPort',
          'SE9_KEY_FILE': '${directory.path}/device.pem',
          'SE9_TOKEN_FILE': '${directory.path}/device-token',
          'SE9_CLOUD_URL': cloud,
          'SE9_CLOUD_BASE_PATH': '',
          if (!autoConfig) 'SE9_AGENT_PROXY_TOKEN': proxyToken,
          'SE9_AGENT_PROXY_TOKEN_FILE': '${directory.path}/proxy-key'
        },
        'agent');
    final tokenFile = File('${directory.path}/device-token');
    for (var attempt = 0;
        attempt < 80 && !await tokenFile.exists();
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    check(await tokenFile.exists(), 'Agent cloud registration failed');
    final login = data(
        await http.post(Uri.parse('$cloud/api/v2/auth/login'),
            headers: {'content-type': 'application/json'},
            body:
                jsonEncode({'username': 'admin', 'password': 'test-password'})),
        200);
    final auth = {
      'authorization': 'Bearer ${login['accessToken']}',
      'content-type': 'application/json'
    };
    udp = await RawDatagramSocket.bind('127.0.0.1', 0);
    subscription = udp.listen((event) {
      if (event == RawSocketEvent.read) {
        Datagram? datagram;
        while ((datagram = udp!.receive()) != null) {
          packets.add((jsonDecode(utf8.decode(datagram!.data)) as Map)
              .cast<String, dynamic>());
        }
      }
    });
    Future<Map<String, dynamic>> exchange(String type, String expected,
        [Map<String, dynamic> extra = const {}]) async {
      final id = '${DateTime.now().microsecondsSinceEpoch}';
      final request = {
        'version': 1,
        'type': type,
        'requestId': id,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'nonce': 'local-test-$id',
        'body': <String, dynamic>{},
        ...extra
      };
      final pending = packets.stream
          .firstWhere((packet) =>
              packet['requestId'] == id && packet['type'] == expected)
          .timeout(const Duration(seconds: 15));
      udp!.send(utf8.encode(jsonEncode(request)), InternetAddress.loopbackIPv4,
          37020);
      return pending;
    }

    final discovery = await exchange('discover_request', 'discover_response');
    final device = discovery['deviceId'] as String;
    final signingKey = SimplePublicKey(
        base64Decode(discovery['body']['publicKey'] as String),
        type: KeyPairType.ed25519);
    final ephemeral = await X25519().newKeyPair();
    final ephemeralPublic = await ephemeral.extractPublicKey();
    final handshake = await exchange('handshake_request', 'handshake_response',
        {'appEphemeralPublicKey': base64Encode(ephemeralPublic.bytes)});
    final remote = SimplePublicKey(
        base64Decode(handshake['body']['deviceEphemeralPublicKey'] as String),
        type: KeyPairType.x25519);
    final secret = await X25519()
        .sharedSecretKey(keyPair: ephemeral, remotePublicKey: remote);
    final result = await exchange('pairing_request', 'pairing_result',
        {'lanSessionId': handshake['body']['lanSessionId']});
    final body = result['body'] as Map;
    final plaintext = await AesGcm.with256bits().decrypt(
        SecretBox(base64Decode(body['ciphertext'] as String),
            nonce: base64Decode(body['nonce'] as String),
            mac: Mac(base64Decode(body['tag'] as String))),
        secretKey: secret);
    final claim = jsonDecode(utf8.decode(plaintext)) as Map;
    check(
        claim['deviceId'] == device &&
            claim['requestId'] == result['requestId'],
        'claim identity mismatch');
    check(signingKey.bytes.length == 32, 'invalid discovery key');
    data(
        await http.post(Uri.parse('$cloud/api/v2/devices/claim/confirm'),
            headers: auth,
            body: jsonEncode({
              'deviceId': device,
              'claimRequestId': claim['requestId'],
              'claimString': claim['claimString']
            })),
        200);
    check(
        (await http.post(Uri.parse('$cloud/api/v2/devices/claim/confirm'),
                    headers: auth,
                    body: jsonEncode({
                      'deviceId': device,
                      'claimString': claim['claimString']
                    })))
                .statusCode ==
            409,
        'repeat claim accepted');
    stdout.writeln(
        'PASS: UDP discovery, X25519/AES-GCM decrypt, cloud claim, repeated-claim rejection');
    final deviceList = data(
        await http.get(Uri.parse('$cloud/api/v2/device_list'), headers: auth),
        200);
    final bound = (deviceList['items'] as List).cast<Map<String, dynamic>>();
    check(
        bound.length == 1 &&
            bound.single['deviceId'] == device &&
            bound.single['role'] == 'owner',
        'bound device list mismatch');
    final selectedDevice = bound.single['deviceId'] as String;
    final otherUser = data(
        await http.post(Uri.parse('$cloud/api/v2/auth/register'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(
                {'account': 'other-user', 'password': 'other-password'})),
        201);
    final otherList = data(
        await http.get(Uri.parse('$cloud/api/v2/devices'),
            headers: {'authorization': 'Bearer ${otherUser['accessToken']}'}),
        200);
    check((otherList['items'] as List).isEmpty,
        'other account can see bound devices');
    check(
        (await http.get(Uri.parse('$cloud/api/v2/device_list'))).statusCode ==
            401,
        'unauthenticated device listing allowed');
    stdout.writeln(
        'PASS: account device_list, compatible devices endpoint, owner isolation, authentication');
    for (var i = 0; i < 50; i++) {
      final list = data(
          await http.get(Uri.parse('$cloud/api/v2/device_list'), headers: auth),
          200);
      if ((list['items'][0]['capabilities']
              as Map?)?['fileTransferTransports'] !=
          null) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await verifyRtc(cloud, auth, device, args[3]);
    if (Platform.environment['SE9_TEST_SKIP_LEGACY'] == '1') return;
    final localLogin = data(
        await http.post(Uri.parse('$files/api/v2/auth/login'),
            body:
                jsonEncode({'username': 'admin', 'password': 'test-password'})),
        200);
    final localAuth = {'authorization': 'Bearer ${localLogin['accessToken']}'};
    check((await http.get(Uri.parse('$files/api/v2/files'))).statusCode == 401,
        'unauthorized files allowed');
    data(await http.get(Uri.parse('$files/api/v2/files'), headers: localAuth),
        200);
    stdout.writeln('PASS: File API login and access control');
    Future<http.Response> relay(String method, String target,
        [List<int> payload = const [],
        Map<String, String> headers = const {}]) async {
      final session = data(
          await http.post(Uri.parse('$cloud/api/v2/sessions'),
              headers: auth, body: jsonEncode({'deviceId': selectedDevice})),
          201);
      final ws = await WebSocket.connect(
          '${tls ? 'wss' : 'ws'}://127.0.0.1:$cloudPort/api/v2/relay/app?sessionId=${session['sessionId']}',
          headers: auth);
      try {
        final pending = ws.first.timeout(const Duration(seconds: 25));
        final extraHeaders = headers.entries
            .map((entry) => '${entry.key}: ${entry.value}\r\n')
            .join();
        ws.add(Uint8List.fromList([
          ...utf8.encode(
              '$method $target HTTP/1.1\r\nHost: localhost\r\n${extraHeaders}Content-Length: ${payload.length}\r\nConnection: close\r\n\r\n'),
          ...payload
        ]));
        final event = await pending;
        check(event is List<int>, 'relay did not return binary HTTP');
        final bytes = event as List<int>;
        var end = -1;
        for (var i = 0; i + 3 < bytes.length; i++) {
          if (bytes[i] == 13 &&
              bytes[i + 1] == 10 &&
              bytes[i + 2] == 13 &&
              bytes[i + 3] == 10) {
            end = i;
            break;
          }
        }
        check(end >= 0, 'invalid relayed HTTP headers');
        final header = latin1.decode(bytes.sublist(0, end));
        final length = int.parse(
            RegExp(r'Content-Length: (\d+)', caseSensitive: false)
                .firstMatch(header)!
                .group(1)!);
        check(bytes.length - end - 4 == length, 'truncated relay response');
        return http.Response.bytes(
            bytes.sublist(end + 4), int.parse(header.split(' ')[1]));
      } finally {
        await ws.close();
      }
    }

    data(await relay('GET', '/api/v2/files'), 200);
    stdout.writeln(
        'PASS: IP HTTP/WS Agent -> Cloud -> File API directory request');
    final content = Uint8List(8 * 1024 * 1024 + 73);
    for (var i = 0; i < content.length; i++) {
      content[i] = i % 251;
    }
    final hash = await Sha256().hash(content);
    final hex = hash.bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    final upload = data(
        await relay(
            'POST',
            '/api/v2/upload/sessions',
            utf8.encode(jsonEncode({
              'path': 'album/test.bin',
              'size': content.length,
              'chunkSize': 8 * 1024 * 1024,
              'sha256': hex
            }))),
        201);
    final uploadId = upload['uploadId'];
    data(
        await relay('PUT', '/api/v2/upload/$uploadId/chunks/0',
            content.sublist(0, 8 * 1024 * 1024)),
        200);
    final missing =
        data(await relay('GET', '/api/v2/upload/$uploadId/missing'), 200);
    check(missing['missingChunks'] == 1, 'missing chunk status wrong');
    data(
        await relay('PUT', '/api/v2/upload/$uploadId/chunks/1',
            content.sublist(8 * 1024 * 1024)),
        200);
    final complete =
        data(await relay('POST', '/api/v2/upload/$uploadId/complete'), 200);
    check(complete['sha256'] == hex, 'upload digest mismatch');
    final downloaded = await relay('GET', '/api/v2/files/album%2Ftest.bin');
    check(
        downloaded.statusCode == 200 &&
            downloaded.bodyBytes.length == content.length,
        'download size mismatch: HTTP ${downloaded.statusCode} bytes=${downloaded.bodyBytes.length}');
    check(
        base64Encode((await Sha256().hash(downloaded.bodyBytes)).bytes) ==
            base64Encode(hash.bytes),
        'download hash mismatch');
    stdout.writeln(
        'PASS: 8 MB remote upload, missing chunk query, SHA-256 merge, >8 MB remote download');
    final range = await relay('GET', '/api/v2/files/album%2Ftest.bin', const [],
        {'Range': 'bytes=1024-'});
    check(
        range.statusCode == 206 &&
            range.bodyBytes.length == content.length - 1024,
        'range download failed');
    final resumed = [...content.sublist(0, 1024), ...range.bodyBytes];
    check(
        base64Encode((await Sha256().hash(resumed)).bytes) ==
            base64Encode(hash.bytes),
        'resumed file hash mismatch');
    data(
        await relay('PATCH', '/api/v2/files/album%2Ftest.bin',
            utf8.encode(jsonEncode({'path': 'album/moved.bin'}))),
        200);
    data(await relay('DELETE', '/api/v2/files/album%2Fmoved.bin'), 200);
    check(
        (await relay('GET', '/api/v2/files/album%2Fmoved.bin')).statusCode ==
            404,
        'deleted file still accessible');
    stdout.writeln(
        'PASS: Range resume with digest verification, rename, delete, missing-file error');
    stdout.writeln('ALL LOCAL CHECKS PASSED');
  } catch (error) {
    stderr.writeln('FAIL: $error\nLogs retained at ${directory.path}');
    rethrow;
  } finally {
    await subscription?.cancel();
    udp?.close();
    await packets.close();
    for (final process in processes.reversed) {
      process.kill();
      await process.exitCode;
    }
    for (final log in logs) {
      await log.close();
    }
  }
}
