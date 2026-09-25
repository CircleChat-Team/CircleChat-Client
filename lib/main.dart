// CircleChat 原生客户端 — 应用入口
// 启动流程：加载本地站点配置 → 若有持久会话则免登录进主界面，否则进登录页。

import 'package:flutter/material.dart';
import 'core/config.dart';
import 'core/session.dart';
import 'core/intl.dart';
import 'state/chat_store.dart';
import 'ui/login/login_screen.dart';
import 'ui/chat/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  currentLang = I18n.fromPlatform();
  runApp(const CircleChatApp());
}

class CircleChatApp extends StatefulWidget {
  const CircleChatApp({super.key});

  @override
  State<CircleChatApp> createState() => _CircleChatAppState();
}

class _CircleChatAppState extends State<CircleChatApp> {
  Session? _session;
  ChatStore? _store;
  bool _booting = true;
  String? _storeUser;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final config = await SiteConfig.load();
    if (config == null || config.base.isEmpty) {
      setState(() => _booting = false);
      return;
    }
    final session = Session(config: config);
    final ok = await session.init();
    if (ok && session.rest.hasSession) {
      setState(() {
        _session = session;
        _booting = false;
      });
    } else {
      setState(() => _booting = false);
    }
  }

  void _onLoggedIn(Session session, SiteConfig config) {
    setState(() {
      _session = session;
      _store?.dispose();
      _store = null;
      _storeUser = null;
    });
  }

  /// 会话失效（logged.out / session.invalid）：回到登录页
  void _onSessionInvalid() {
    setState(() {
      _session = null;
      _store?.dispose();
      _store = null;
      _storeUser = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: tr('app.name'),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF315CFF), brightness: Brightness.light),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF315CFF), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    if (_booting) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final session = _session;
    if (session == null) {
      return LoginScreen(
        onLoggedIn: _onLoggedIn,
      );
    }
    // 首次进入/会话变更时，保证 store 与 session 绑定
    if (_store == null || _storeUser != session.config.username) {
      _store?.dispose();
      _storeUser = session.config.username;
      _store = ChatStore(session)..onSessionInvalid = _onSessionInvalid;
      _store!.init(session.config.username ?? '');
    }
    final store = _store!;
    return HomeScreen(store: store);
  }
}