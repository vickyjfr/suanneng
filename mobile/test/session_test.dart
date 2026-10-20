import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:se9_mobile/main.dart';

http.Response success(Map<String, dynamic> data) => http.Response(jsonEncode({'code': '0', 'data': data}), 200);
void seed({bool expired = true}) {
  SharedPreferences.setMockInitialValues({'se9.cloud.session': jsonEncode({
    'accessToken': 'access-1', 'refreshToken': 'refresh-1',
    'expiresAt': DateTime.now().millisecondsSinceEpoch + (expired ? -1000 : 3600000),
    'lastRefreshAt': DateTime.now().millisecondsSinceEpoch,
  })});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('login persists session and a new API instance restores without login', () async {
    SharedPreferences.setMockInitialValues({});
    final client = MockClient((request) async {
      expect(request.url.path, '/api/v2/auth/login');
      return success({'accessToken': 'access', 'refreshToken': 'refresh', 'expiresIn': 3600});
    });
    await Se9Api('', cloudUrl: 'https://test', client: client).login('user', 'password');
    final restored = Se9Api('', client: MockClient((_) async => fail('unexpected network request')));
    expect(await restored.restoreSession(), isTrue);
    expect(restored.cloudToken, 'access');
  });
  test('refresh rotation persists the new refresh token across restarts', () async {
    seed();
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(jsonDecode(request.body)['refreshToken'], calls == 1 ? 'refresh-1' : 'refresh-2');
      return success({'accessToken': 'access-${calls + 1}', 'refreshToken': 'refresh-${calls + 1}', 'expiresIn': 3600});
    });
    expect(await Se9Api('', client: client).restoreSession(), isTrue);
    final restarted = Se9Api('', client: client);
    expect(await restarted.restoreSession(), isTrue);
    await restarted.refreshCloudToken();
    expect(calls, 2);
  });
  test('concurrent refresh requests share one network call', () async {
    seed(expired: false);
    var calls = 0;
    final client = MockClient((_) async {
      calls++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return success({'accessToken': 'new', 'refreshToken': 'new-refresh', 'expiresIn': 3600});
    });
    final api = Se9Api('', client: client);
    await api.restoreSession();
    await Future.wait([api.refreshCloudToken(), api.refreshCloudToken()]);
    expect(calls, 1);
  });
  test('network errors preserve stored session', () async {
    seed();
    final api = Se9Api('', client: MockClient((_) async => throw http.ClientException('offline')));
    expect(await api.restoreSession(), isTrue);
    expect((await SharedPreferences.getInstance()).getString('se9.cloud.session'), isNotNull);
  });
  test('invalid refresh token clears session', () async {
    seed();
    final api = Se9Api('', client: MockClient((_) async => http.Response('{}', 401)));
    expect(await api.restoreSession(), isFalse);
    expect(api.cloudToken, isNull);
    expect((await SharedPreferences.getInstance()).getString('se9.cloud.session'), isNull);
  });
  test('401 access response refreshes and retries with new bearer token', () async {
    seed(expired: false);
    var requests = 0;
    final api = Se9Api('', client: MockClient((request) async {
      if (request.url.path.endsWith('/refresh')) return success({'accessToken': 'new', 'refreshToken': 'rotated', 'expiresIn': 3600});
      requests++;
      if (requests == 1) return http.Response('{}', 401);
      expect(request.headers['authorization'], 'Bearer new');
      return success({'user': {'account': 'user'}});
    }));
    await api.restoreSession();
    expect((await api.accountInfo())['account'], 'user');
    expect(requests, 2);
  });
  test('logout clears saved login even when offline', () async {
    seed(expired: false);
    final api = Se9Api('', client: MockClient((_) async => throw http.ClientException('offline')));
    await api.restoreSession();
    await expectLater(api.logout(), throwsA(isA<http.ClientException>()));
    expect(api.cloudToken, isNull);
    expect((await SharedPreferences.getInstance()).getString('se9.cloud.session'), isNull);
  });
}
