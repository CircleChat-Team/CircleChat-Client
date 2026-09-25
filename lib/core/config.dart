// CircleChat 原生客户端 — 站点配置
// 客户端通过“输入站点地址初始化”，随后调用该站的 REST /api 与 WebSocket /ws。
// 站点地址持久化到本地（shared_preferences），所有请求基于它解析。

import 'package:shared_preferences/shared_preferences.dart';

/// 站点地址配置。展示地址与请求地址可分离（对应 Web 端 config.apiBase 语境）。
/// 这里统一由一个“站点地址”推导 REST base 与 WebSocket url。
class SiteConfig {
  /// 站点根地址，存储时归一化（去尾部斜杠），如 https://chat.example.com
  String base;

  /// 当前已登录用户名（会话由 cookie 维持，此处仅存展示用）
  String? username;

  SiteConfig({required this.base, this.username});

  static const _kSiteKey = 'circlechat_site';
  static const _kUserKey = 'circlechat_user';

  /// REST base，形如 https://chat.example.com
  String get apiBase => base;

  /// 把相对资源路径解析成完整地址（用于 /uploads/xxx 等媒体地址）
  String resolve(String pathOrUrl) {
    if (pathOrUrl.isEmpty) return '';
    if (pathOrUrl.startsWith('http://') || pathOrUrl.startsWith('https://')) {
      return pathOrUrl;
    }
    if (pathOrUrl.startsWith('//')) return '${base.startsWith('https') ? 'https:' : 'http:'}$pathOrUrl';
    if (!pathOrUrl.startsWith('/')) return '$base/$pathOrUrl';
    return '$base$pathOrUrl';
  }

  /// WebSocket 地址（标准 RFC6455，/ws 路径）
  String get wsUrl {
    final u = Uri.parse(base);
    final scheme = u.scheme == 'https' ? 'wss' : 'ws';
    String host = u.host;
    if (u.hasPort) host = '$host:${u.port}';
    return '$scheme://$host/ws';
  }

  /// 归一化站点地址：补协议、去尾部斜杠。返回 null 表示非法。
  static String? normalize(String input) {
    var s = input.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'https://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return null;
    if (u.scheme != 'http' && u.scheme != 'https') return null;
    if (u.userInfo.isNotEmpty || u.query.isNotEmpty || u.fragment.isNotEmpty) {
      return null;
    }
    // 客户端 API 路径固定为 /api/*，站点地址只接受根地址，避免
    // 用户误填路径后生成一个看似正常但实际不可用的请求地址。
    if (u.path.isNotEmpty && u.path != '/') return null;
    final scheme = u.scheme;
    String host = u.host;
    if (u.hasPort) host = '$host:${u.port}';
    return '$scheme://$host';
  }
  static Future<SiteConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final site = prefs.getString(_kSiteKey);
    if (site == null || site.isEmpty) return null;
    return SiteConfig(base: site, username: prefs.getString(_kUserKey));
  }

  /// 保存到本地。
  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    if (base.isEmpty) {
      await prefs.remove(_kSiteKey);
      await prefs.remove(_kUserKey);
    } else {
      await prefs.setString(_kSiteKey, base);
      if (username != null && username!.isNotEmpty) {
        await prefs.setString(_kUserKey, username!);
      }
    }
  }

  /// 清除站点（登出时拆除本地配置）
  Future<void> clear() async {
    base = '';
    username = null;
    await save();
  }
}
