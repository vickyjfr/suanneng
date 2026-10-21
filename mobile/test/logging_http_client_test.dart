import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:se9_mobile/network/logging_http_client.dart';

void main() {
  test('logs correlated request, status and JSON while redacting credentials',
      () async {
    final logs = <String>[];
    final client = LoggingHttpClient(
        MockClient((request) async => http.Response(
                jsonEncode({
                  'code': '0',
                  'data': {
                    'accessToken': 'server-token',
                    'resumeToken': 'resume-secret',
                    'iceServers': [
                      {'credential': 'turn-password'}
                    ],
                    'items': []
                  }
                }),
                200,
                headers: {
                  'set-cookie': 'secret-cookie',
                  'content-type': 'application/json'
                })),
        enabled: true,
        onLog: logs.add);
    final response = await client.post(
        Uri.parse('https://example.test/api/v2/auth/login?token=query-secret'),
        headers: {
          'authorization': 'Bearer bearer-secret',
          'content-type': 'application/json'
        },
        body: jsonEncode({
          'password': 'password-secret',
          'nested': {'turnSharedSecret': 'turn-secret'}
        }));
    expect(response.statusCode, 200);
    expect(jsonDecode(response.body)['data']['accessToken'], 'server-token');
    final text = logs.join('\n');
    expect(text, contains('POST https://example.test'));
    expect(text, contains('status=200'));
    expect(text, contains('elapsedMs='));
    expect(text, contains('"items":[]'));
    for (final secret in [
      'query-secret',
      'bearer-secret',
      'password-secret',
      'turn-secret',
      'server-token',
      'resume-secret',
      'secret-cookie',
      'turn-password'
    ]) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, contains('[REDACTED]'));
  });
  test('retains network errors and redacts credential-bearing error URLs',
      () async {
    final logs = <String>[];
    final uri =
        Uri.parse('https://example.test/api/v2/device_list?accessToken=hidden');
    final client = LoggingHttpClient(
        MockClient((request) async =>
            throw http.ClientException('offline', request.url)),
        enabled: true,
        onLog: logs.add);
    await expectLater(client.get(uri), throwsA(isA<http.ClientException>()));
    expect(logs.join('\n'), contains('ERROR'));
    expect(logs.join('\n'), contains('ClientException'));
    expect(logs.join('\n'), isNot(contains('hidden')));
  });
  test('logs HTTP failures and omits oversized or non-JSON payloads', () async {
    final logs = <String>[];
    final large = 'binary-private-data' * 5000;
    final client = LoggingHttpClient(
        MockClient((request) async => http.Response(large, 503)),
        enabled: true,
        onLog: logs.add);
    final response =
        await client.get(Uri.parse('https://example.test/api/v2/device_list'));
    expect(response.body, large);
    expect(response.statusCode, 503);
    expect(logs.join('\n'), contains('status=503'));
    expect(logs.join('\n'), contains('body omitted'));
    expect(logs.join('\n'), isNot(contains('binary-private-data')));
  });
  test('disabled logging preserves responses without emitting logs', () async {
    final logs = <String>[];
    final client = LoggingHttpClient(
        MockClient((request) async => http.Response('ok', 200)),
        enabled: false,
        onLog: logs.add);
    expect((await client.get(Uri.parse('https://example.test'))).body, 'ok');
    expect(logs, isEmpty);
  });
}
