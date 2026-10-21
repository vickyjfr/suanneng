import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class LoggingHttpClient extends http.BaseClient {
  LoggingHttpClient(this.inner, {bool? enabled, void Function(String)? onLog})
      : enabled = enabled ??
            const bool.fromEnvironment('SE9_HTTP_LOGS',
                defaultValue: kDebugMode),
        _write = onLog ?? debugPrint;
  final http.Client inner;
  final bool enabled;
  final void Function(String) _write;
  static int _nextId = 0;
  static const _captureLimit = 64 * 1024;
  static const _printLimit = 4096;

  static bool _sensitive(String key) {
    final name = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
    return const [
      'authorization',
      'credential',
      'password',
      'token',
      'secret',
      'cookie',
      'grant',
      'signature',
      'privatekey',
      'claimstring',
      'resetcode',
      'context'
    ].any(name.contains);
  }

  static Object? _redact(Object? value) {
    if (value is Map) {
      return value.map((key, value) =>
          MapEntry('$key', _sensitive('$key') ? '[REDACTED]' : _redact(value)));
    }
    if (value is List) return value.map(_redact).toList();
    return value;
  }

  static String _safeUri(Uri uri) {
    final query = uri.queryParametersAll.map((key, values) =>
        MapEntry(key, _sensitive(key) ? ['[REDACTED]'] : values));
    return uri
        .replace(
            userInfo: uri.userInfo.isEmpty ? '' : '[REDACTED]',
            queryParameters: uri.hasQuery ? query : null)
        .toString();
  }

  String _body(List<int> bytes, {bool oversized = false}) {
    if (oversized || bytes.length > _captureLimit) {
      return '[body omitted: exceeds $_captureLimit bytes]';
    }
    if (bytes.isEmpty) return '<empty>';
    try {
      return jsonEncode(_redact(jsonDecode(utf8.decode(bytes))));
    } catch (_) {
      return '[non-JSON body omitted: ${bytes.length} bytes]';
    }
  }

  void _log(int id, String text) {
    if (!enabled) return;
    final safe = text.length > _printLimit
        ? '${text.substring(0, _printLimit)} …[truncated]'
        : text;
    try {
      _write('[SE9-HTTP #$id] $safe');
    } catch (_) {}
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!enabled) return inner.send(request);
    final id = ++_nextId, watch = Stopwatch()..start();
    final uri = _safeUri(request.url);
    _log(id,
        '--> ${request.method} $uri headers=${jsonEncode(_redact(request.headers))}');
    if (request is http.Request) {
      _log(id, 'requestBody=${_body(request.bodyBytes)}');
    }
    String safeError(Object error) {
      var message = '$error'.replaceAll(request.url.toString(), uri);
      for (final entry in request.headers.entries) {
        if (_sensitive(entry.key) && entry.value.isNotEmpty) {
          message = message.replaceAll(entry.value, '[REDACTED]');
          if (entry.value.startsWith('Bearer ')) {
            message =
                message.replaceAll(entry.value.substring(7), '[REDACTED]');
          }
        }
      }
      return message;
    }

    try {
      final response = await inner.send(request);
      _log(id,
          '<-- status=${response.statusCode} headersMs=${watch.elapsedMilliseconds} headers=${jsonEncode(_redact(response.headers))}');
      Stream<List<int>> observed() async* {
        final capture = BytesBuilder(copy: false);
        var count = 0, complete = false;
        try {
          await for (final chunk in response.stream) {
            count += chunk.length;
            if (capture.length < _captureLimit) {
              capture.add(chunk.sublist(
                  0, (chunk.length).clamp(0, _captureLimit - capture.length)));
            }
            yield chunk;
          }
          complete = true;
          _log(id,
              'DONE status=${response.statusCode} elapsedMs=${watch.elapsedMilliseconds} bytes=$count responseBody=${_body(capture.takeBytes(), oversized: count > _captureLimit)}');
        } catch (error) {
          _log(id,
              'ERROR body elapsedMs=${watch.elapsedMilliseconds} ${error.runtimeType}: ${safeError(error)}');
          rethrow;
        } finally {
          if (!complete) {
            _log(id,
                'INCOMPLETE elapsedMs=${watch.elapsedMilliseconds} bytes=$count');
          }
        }
      }

      return http.StreamedResponse(observed(), response.statusCode,
          contentLength: response.contentLength,
          request: response.request,
          headers: response.headers,
          isRedirect: response.isRedirect,
          persistentConnection: response.persistentConnection,
          reasonPhrase: response.reasonPhrase);
    } catch (error) {
      _log(id,
          'ERROR elapsedMs=${watch.elapsedMilliseconds} ${error.runtimeType}: ${safeError(error)}');
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}
