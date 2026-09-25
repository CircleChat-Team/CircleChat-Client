// CircleChat 原生客户端 — 登录页面
// 三步流程：①输入站点地址（初始化） → 连接校验 → ②登录表单（含注册入口）→ ③如需2FA完成验证。
// 首次登录取强制改密；会话由服务端 Set-Cookie 维持并由 restClient 自动捕获。

import 'package:flutter/material.dart';
import '../../core/config.dart';
import '../../core/session.dart';
import '../../core/intl.dart';

class LoginScreen extends StatefulWidget {
  final Session? existingSession;
  final void Function(Session session, SiteConfig config)? onLoggedIn;
  const LoginScreen({super.key, this.existingSession, this.onLoggedIn});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _siteCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _regUserCtrl = TextEditingController();
  final _regPassCtrl = TextEditingController();
  final _regEmailCtrl = TextEditingController();

  bool _connecting = false;
  bool _connected = false;
  bool _loginBusy = false;
  bool _regBusy = false;

  // 2FA 状态
  bool _showTwofa = false;
  String _twofaChallenge = '';
  final _codeCtrl = TextEditingController();

  // 强制改密状态
  bool _showForceChange = false;
  final _curPassCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();

  String? _siteError;
  String? _loginError;
  String? _regError;
  String? _twofaError;

  // 注册表单已打开
  bool _showRegister = false;

  Session? _session;
  SiteConfig _config = SiteConfig(base: '');

  String _errorText(String? value, {String fallback = 'site.network'}) {
    if (value == null || value.isEmpty) return tr(fallback);
    final translated = tr(value);
    return translated == value && value.contains('_') ? tr(fallback) : translated;
  }

  @override
  void initState() {
    super.initState();
    if (widget.existingSession != null) {
      _session = widget.existingSession;
      _config = _session!.config;
      _siteCtrl.text = _config.base;
      _connected = true;
    }
  }

  @override
  void dispose() {
    _siteCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _regUserCtrl.dispose();
    _regPassCtrl.dispose();
    _regEmailCtrl.dispose();
    _codeCtrl.dispose();
    _curPassCtrl.dispose();
    _newPassCtrl.dispose();
    super.dispose();
  }

  // ---------- 站点连接 ----------

  Future<void> _connectSite() async {
    final url = SiteConfig.normalize(_siteCtrl.text);
    if (url == null) {
      setState(() => _siteError = 'site.invalid');
      return;
    }
    setState(() {
      _siteError = null;
      _connecting = true;
    });
    try {
      // 探活（/api/health）→ 校验是否 CircleChat 站点（/api/setup），通过后建立 Session
      final cfg = SiteConfig(base: url);
      final rest = await _health(cfg);
      if (!rest) {
        setState(() {
          _connecting = false;
          _siteError = 'site.unreachable';
        });
        return;
      }
      if (!await _isChat(cfg)) {
        setState(() {
          _connecting = false;
          _siteError = 'site.notChat';
        });
        return;
      }
      _config = cfg;
      // 每次重新连接都创建新 Session，不能沿用上一个站点的 token/用户。
      _session = Session(config: cfg);
      setState(() {
        _connected = true;
        _connecting = false;
      });
    } catch (_) {
      setState(() {
        _connecting = false;
        _siteError = 'site.unreachable';
      });
    }
  }

  Future<bool> _health(SiteConfig cfg) async {
    try {
      final r = await Session(config: cfg).rest.get('/api/health');
      return r.ok;
    } catch (_) {
      return false;
    }
  }

  /// 校验目标地址是否为 CircleChat 站点：
  /// CircleChat 所有 API 返回 {ok,...} 结构，/api/setup 为公开探测端点。
  Future<bool> _isChat(SiteConfig cfg) async {
    try {
      final r = await Session(config: cfg).rest.get('/api/setup');
      return r.ok;
    } catch (_) {
      return false;
    }
  }

  // ---------- 登录 ----------

  Future<void> _doLogin() async {
    setState(() {
      _loginBusy = true;
      _loginError = null;
    });
    try {
      final s = _session!;
      final result = await s.login(_userCtrl.text.trim(), _passCtrl.text);
      setState(() {
        _loginBusy = false;
        if (result['type'] == 'need2fa') {
          _twofaChallenge = (result['challenge'] as String?) ?? '';
          _showTwofa = true;
        } else if (result['type'] == 'forceChange') {
          _showForceChange = true;
        } else {
          _finish(s);
        }
      });
    } on LoginException catch (e) {
      setState(() {
        _loginBusy = false;
        _loginError = _errorText(e.error, fallback: 'login.badCredentials');
      });
    } catch (_) {
      setState(() {
        _loginBusy = false;
        _loginError = 'site.network';
      });
    }
  }

  Future<void> _doTwofa() async {
    setState(() {
      _twofaError = null;
      _loginBusy = true;
    });
    try {
      await _session!.twofaVerify(_twofaChallenge, _codeCtrl.text.trim());
      setState(() {
        _loginBusy = false;
        _showTwofa = false;
      });
      _finish(_session!);
    } on LoginException catch (e) {
      setState(() {
        _twofaError = _errorText(e.error, fallback: 'login.twofa');
        _loginBusy = false;
      });
    } catch (_) {
      setState(() {
        _twofaError = 'site.network';
        _loginBusy = false;
      });
    }
  }

  Future<void> _doForceChange() async {
    setState(() {
      _loginError = null;
      _loginBusy = true;
    });
    try {
      await _session!.changePassword(_curPassCtrl.text, _newPassCtrl.text);
      setState(() {
        _loginBusy = false;
        _showForceChange = false;
      });
      _finish(_session!);
    } catch (e) {
      setState(() {
        _loginBusy = false;
        _loginError = _errorText(e.toString());
      });
    }
  }

  void _finish(Session s) {
    widget.onLoggedIn?.call(s, _config);
  }

  // ---------- 注册 ----------

  Future<void> _doRegister() async {
    setState(() {
      _regBusy = true;
      _regError = null;
    });
    try {
      final r = await _session!.rest.post('/api/register', body: {
        'username': _regUserCtrl.text.trim(),
        'password': _regPassCtrl.text,
        if (_regEmailCtrl.text.trim().isNotEmpty) 'email': _regEmailCtrl.text.trim(),
      });
      if (r.ok) {
        setState(() {
          _regBusy = false;
          _showRegister = false;
          _userCtrl.text = _regUserCtrl.text;
          _loginError = 'reg.pendingHint';
        });
      } else {
        setState(() {
          _regBusy = false;
          _regError = _errorText(r.error, fallback: 'reg.fail');
        });
      }
    } catch (_) {
      setState(() {
        _regBusy = false;
        _regError = 'site.network';
      });
    }
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _showForceChange
                ? _forceChangeForm()
                : _showTwofa
                    ? _twofaForm()
                    : _connected
                        ? _loginForm()
                        : _siteForm(),
          ),
        ),
      ),
    );
  }

  Widget _siteForm() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Icon(Icons.forum_rounded, size: 72, color: Colors.teal),
        const SizedBox(height: 16),
        Text(tr('app.name'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
        const SizedBox(height: 32),
        TextField(
          controller: _siteCtrl,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: tr('login.site'),
            hintText: tr('login.siteHint'),
            border: const OutlineInputBorder(),
            errorText: _siteError,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _connecting ? null : _connectSite,
          icon: _connecting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link),
          label: Text(tr('login.connect')),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 16),
        Text(tr('login.siteDisclaimer'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _loginForm() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextButton.icon(
          onPressed: () {
            setState(() {
              _connected = false;
              _loginError = null;
            });
          },
          icon: const Icon(Icons.arrow_back),
          label: Text(_session!.config.base),
        ),
        const SizedBox(height: 8),
        Text(tr('login.submit'),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        if (_loginError != null && _loginError != 'reg.pendingHint') ...[
          Text(_loginError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _userCtrl,
          autofillHints: const [AutofillHints.username],
          decoration: InputDecoration(
            labelText: tr('login.username'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passCtrl,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => _loginBusy ? null : _doLogin(),
          decoration: InputDecoration(
            labelText: tr('login.password'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _loginBusy ? null : _doLogin,
          child: _loginBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(tr('login.submit')),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: () => setState(() => _showRegister = !_showRegister),
          child: Text(tr(_showRegister ? 'login.back' : 'login.register')),
        ),
        if (_showRegister) _registerForm(),
      ],
    );
  }

  Widget _registerForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        if (_regError != null) ...[
          Text(_regError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _regUserCtrl,
          decoration: InputDecoration(
            labelText: tr('login.username'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _regPassCtrl,
          obscureText: true,
          decoration: InputDecoration(
            labelText: tr('login.password'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _regEmailCtrl,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: tr('login.email'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _regBusy ? null : _doRegister,
          child: _regBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(tr('login.registerSubmit')),
        ),
      ],
    );
  }

  Widget _twofaForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr('login.twofa'),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        if (_twofaError != null) ...[
          Text(_twofaError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          maxLength: 6,
          decoration: InputDecoration(
            labelText: tr('login.twofa.code'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _loginBusy ? null : _doTwofa,
          child: _loginBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(tr('login.confirm')),
        ),
      ],
    );
  }

  Widget _forceChangeForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr('login.forceChange'),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        if (_loginError != null) ...[
          Text(_loginError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 8),
        ],
        TextField(
          controller: _curPassCtrl,
          obscureText: true,
          decoration: InputDecoration(
            labelText: tr('login.curPass'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _newPassCtrl,
          obscureText: true,
          decoration: InputDecoration(
            labelText: tr('login.newPass'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _loginBusy ? null : _doForceChange,
          child: _loginBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(tr('login.confirm')),
        ),
      ],
    );
  }
}
