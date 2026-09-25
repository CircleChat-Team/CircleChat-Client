// CircleChat 原生客户端 — 会话 / 鉴权
// 管理站点地址、登录、2FA、注销；持有唯一 RestClient 实例。
// 登录/2FA 成功后由服务端 Set-Cookie 下发 token 并被 restClient 自动捕获。

import 'api_client.dart';
import 'config.dart';

/// 登录流程状态：正常 / 需要2FA / 首次强制改密
class Session {
  final SiteConfig config;
  final RestClient rest;
  // 身份字段默认初始化，避免登录/启动异步加载角色前被提前读取
  String me = '';
  String role = 'user';
  bool isAdmin = false;
  bool mustChange = false;

  Session({required this.config}) : rest = RestClient(base: config.apiBase) {
    _restoreFromConfig();
  }

  void _restoreFromConfig() {
    if (config.username != null) me = config.username!;
  }

  /// 应用启动时可调用：恢复持久 token 并探测登录态。
  Future<bool> init() async {
    await rest.restoreToken();
    if (!rest.hasSession) return false;
    try {
      final r = await rest.get('/api/me');
      if (r.ok) {
        me = (r.json['username'] as String?) ?? me;
        role = (r.json['role'] as String?) ?? 'user';
        isAdmin = role == 'admin';
        mustChange = (r.json['mustChange'] as bool?) ?? false;
        config.username = me;
        await config.save();
        return true;
      }
      // 会话失效：清除 token
      await rest.setToken(null);
      return false;
    } catch (_) {
      // 网络错误不能判定未登录，交由上层决定
      // 保守处理：有 token 但 /api/me 失败时也视为需重新校验，但保留 token 供下次
      return rest.hasSession;
    }
  }

  /// 登录。成功返回 {type:'ok'|'need2fa'|'forceChange'}；失败抛该结构字段。
  Future<Map<String, dynamic>> login(String username, String password) async {
    final r = await rest.post('/api/login', body: {'username': username, 'password': password});
    if (!r.ok) throw LoginException(r.error ?? 'login_failed');
    if ((r.json['need2fa'] as bool?) == true) {
      return {'type': 'need2fa', 'challenge': r.json['challenge']};
    }
    me = (r.json['username'] as String?) ?? username;
    mustChange = (r.json['mustChange'] as bool?) ?? false;
    role = 'user'; // me 之后补充
    config.username = me;
    await config.save();
    _loadRole();
    return {'type': mustChange ? 'forceChange' : 'ok'};
  }

  /// 2FA 第二步验证。
  Future<void> twofaVerify(String challenge, String code) async {
    final r = await rest.post('/api/twofa/verify', body: {'challenge': challenge, 'code': code});
    if (!r.ok) throw LoginException(r.error ?? 'twofa_bad');
    me = (r.json['username'] as String?) ?? me;
    mustChange = (r.json['mustChange'] as bool?) ?? false;
    config.username = me;
    await config.save();
    _loadRole();
  }

  Future<void> _loadRole() async {
    try {
      final r = await rest.get('/api/me');
      if (r.ok) {
        role = (r.json['role'] as String?) ?? 'user';
        isAdmin = role == 'admin';
      }
    } catch (_) {}
  }

  /// 注销：通知服务端销毁会话，并清除本地 token 与站点配置。
  Future<void> logout() async {
    try {
      await rest.post('/api/logout');
    } catch (_) {}
    await rest.setToken(null);
    await config.clear();
  }

  /// 修改本人密码（可能用于首次强制改密）。
  Future<void> changePassword(String current, String newPass) async {
    final r = await rest.post('/api/pass', body: {'current': current, 'password': newPass});
    if (!r.ok) throw ApiException(400, r.error ?? 'pass_failed');
    mustChange = false;
  }
}

/// 登录失败异常（携带服务端 error 文案键）
class LoginException implements Exception {
  final String error;
  LoginException(this.error);
  @override
  String toString() => 'LoginException: $error';
}