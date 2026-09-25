// CircleChat 原生客户端 — REST 封装
// 基于 dart:io HttpClient，手动管理 Set-Cookie：登录/2FA 成功后捕获
// circlechat_token 并持久化；后续所有请求携带该 cookie。返回统一 ApiResult。
// 使用自研封装而非第三方 dio，避免引入不必要的运行时依赖与版权耦合。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

/// 请求结果：成功返回 response，失败抛 ApiException。
class ApiException implements Exception {
  final int? status;
  final String message;
  ApiException(this.status, this.message);

  @override
  String toString() => 'ApiException($status): $message';
}

/// 网络错误类型
enum NetError { connect, timeout, tls, http, parse }

class RestClient {
  final String base;
  final Duration timeout;

  RestClient({required this.base, this.timeout = const Duration(seconds: 15)});

  String get _tokenKey {
    // 会话必须按站点隔离，避免登录 A 站后把 cookie 发给 B 站。
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    return 'circlechat_token_$safe';
  }

  /// 已保存的会话 token（cookie 值），null 表示未登录。
  String? cachedToken;

  /// 从本地恢复会话 token（应用启动/站点重建时调用）。
  Future<void> restoreToken() async {
    final prefs = await SharedPreferences.getInstance();
    cachedToken = prefs.getString(_tokenKey);
  }

  /// 手工设置 token（供重启后 / 跨站点复用；通常由 setCookie 自动捕获）。
  Future<void> setToken(String? token) async {
    cachedToken = (token == null || token.isEmpty) ? null : token;
    final prefs = await SharedPreferences.getInstance();
    if (cachedToken == null) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, cachedToken!);
    }
  }

  /// 是否已具备持久会话（用于启动时判断能否免登录直接进主页）。
  bool get hasSession => cachedToken != null;

  /// 统一发起请求。path 为相对路径（如 /api/login）。
  Future<ApiResult> request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    final apiResult = await _send(method, path, query: query, body: body, headers: headers);
    return apiResult;
  }

  Future<HttpClientRequest> _open(HttpClient client, String method, Uri uri) {
    return client.openUrl(method, uri);
  }

  Future<ApiResult> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    final hc = _newClient();
    try {
      final normalizedPath = path.startsWith('/') ? path : '/$path';
      var urlStr = '$base$normalizedPath';
      if (query != null && query.isNotEmpty) {
        final qs = query.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
        urlStr += (urlStr.contains('?') ? '&' : '?') + qs;
      }
      final uri = Uri.parse(urlStr);
      final req = await _open(hc, method, uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.userAgentHeader, 'CircleChat-Client/1.0');
      if (cachedToken != null) {
        req.headers.set(HttpHeaders.cookieHeader, 'circlechat_token=$cachedToken');
      }
      if (headers != null) {
        headers.forEach((k, v) => req.headers.set(k, v));
      }
      if (body != null) {
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
        req.headers.set(HttpHeaders.contentLengthHeader, utf8.encode(jsonEncode(body)).length.toString());
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(timeout);

      // 捕获服务端下发的会话 cookie
      final setCookies = res.headers[HttpHeaders.setCookieHeader];
      if (setCookies != null) {
        for (final c in setCookies) {
          final m = RegExp(r'circlechat_token=([^;]*)').firstMatch(c);
          if (m != null) {
            final raw = Uri.decodeComponent(m.group(1)!);
            await setToken(raw.isEmpty ? null : raw);
          }
        }
      }

      final bodyStr = await _readBody(res);
      final status = res.statusCode;
      res.detachSocket().then((s) => s.destroy()).catchError((_) {});
      if (status >= 200 && status < 300) {
        try {
          return ApiResult.from(jsonDecode(bodyStr));
        } catch (_) {
          throw ApiException(status, 'malformed_json');
        }
      }
      // 错误响应：尽量取 error 文案
      String err = 'http_$status';
      try {
        final m = jsonDecode(bodyStr);
        if (m is Map && m['error'] is String) err = m['error'] as String;
      } catch (_) {}
      throw ApiException(status, err);
    } on TimeoutException {
      throw ApiException(null, 'timeout');
    } on SocketException catch (e) {
      throw ApiException(null, 'network_${e.message}');
    } on HttpException catch (e) {
      throw ApiException(null, 'http_${e.message}');
    } on ApiException {
      rethrow;
    } finally {
      hc.close(force: true);
    }
  }

  HttpClient _newClient() {
    final client = HttpClient()
      ..connectionTimeout = timeout;
    return client;
  }

  Future<String> _readBody(HttpClientResponse res) async {
    final completer = Completer<String>();
    final sb = StringBuffer();
    res.transform(utf8.decoder).listen(
      (chunk) => sb.write(chunk),
      onDone: () => completer.complete(sb.toString()),
      onError: (e) => completer.completeError(e),
      cancelOnError: true,
    );
    return completer.future.timeout(timeout + const Duration(seconds: 5));
  }

  // ---------- 便捷方法 ----------

  Future<ApiResult> get(String path, {Map<String, String>? query}) =>
      request('GET', path, query: query);

  Future<ApiResult> post(String path, {Map<String, dynamic>? body, Map<String, String>? query}) =>
      request('POST', path, query: query, body: body);

  Future<ApiResult> delete(String path, {Map<String, dynamic>? body, Map<String, String>? query}) =>
      request('DELETE', path, query: query, body: body);
}
