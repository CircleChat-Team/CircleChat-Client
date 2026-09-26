// CircleChat 原生客户端 — 应用入口
// 启动流程：加载本地站点配置 → 若有持久会话则免登录进主界面，否则进登录页。
// 桌面平台（Windows/macOS/Linux）：无边框窗口 + 自定义 32px 标题栏 + 8px 圆角。

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'core/config.dart';
import 'core/session.dart';
import 'core/intl.dart';
import 'state/chat_store.dart';
import 'ui/login/login_screen.dart';
import 'ui/chat/home_screen.dart';
import 'ui/window_frame.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (isDesktop) {
    await windowManager.ensureInitialized();
    const opts = WindowOptions(
      title: 'CircleChat',
      size: Size(1200, 800),
      minimumSize: Size(480, 360),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      // 无边框窗口：隐藏系统标题栏，由 WindowFrame 绘制自定义 32px 标题栏与窗口按钮。
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      await windowManager.show();
    });
  }
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
    final app = MaterialApp(
      title: tr('app.name'),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF0067C0),
          onPrimary: Colors.white,
          primaryContainer: Color(0xFFDCEEFF),
          onPrimaryContainer: Color(0xFF001B33),
          surface: Color(0xFFFFFFFF),
          onSurface: Color(0xFF1A1A1A),
          surfaceContainerHighest: Color(0xFFF0F0F0),
          outline: Color(0xFF8A8A8A),
          outlineVariant: Color(0xFFE5E5E5),
          error: Color(0xFFC42B1C),
        ),
        useMaterial3: true,
        fontFamily: 'Segoe UI',
        scaffoldBackgroundColor: const Color(0xFFFFFFFF),
        visualDensity: VisualDensity.standard,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFF8A8A8A)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFFBDBDBD)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFF0067C0), width: 2),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 18),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            minimumSize: const Size(0, 40),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFFFFFF),
          foregroundColor: Color(0xFF1A1A1A),
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 48,
          titleTextStyle: TextStyle(
            fontFamily: 'Segoe UI',
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A1A),
          ),
        ),
        // WinUI / Fluent 风格：卡片与浮层统一 8px 圆角、无 tint 干扰
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFFFFFFFF),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFFFFFFFF),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        listTileTheme: ListTileThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: const Color(0xFFFFFFFF),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        menuTheme: MenuThemeData(
          style: MenuStyle(
            backgroundColor: WidgetStateProperty.all(const Color(0xFFFFFFFF)),
            surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
            shape: WidgetStateProperty.all(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        tooltipTheme: TooltipThemeData(
          decoration: BoxDecoration(
            color: const Color(0xFF3B3B3B),
            borderRadius: BorderRadius.circular(4),
          ),
          textStyle: const TextStyle(color: Colors.white, fontSize: 12),
        ),
        // Win11：细圆角滚动条（常显、hover 交互）、图标/文本按钮 hover 圆角填充、无描边开关
        scrollbarTheme: ScrollbarThemeData(
          thumbColor: const WidgetStatePropertyAll<Color?>(Color(0xFFA6A6A6)),
          trackColor: const WidgetStatePropertyAll<Color?>(Color(0xFFF0F0F0)),
          thumbVisibility: const WidgetStatePropertyAll<bool?>(true),
          thickness: const WidgetStatePropertyAll<double?>(8),
          radius: const Radius.circular(4),
          minThumbLength: 48,
          interactive: true,
        ),
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            backgroundColor: WidgetStateProperty.resolveWith<Color?>(
              (s) => s.contains(WidgetState.hovered)
                  ? const Color(0xFFF0F0F0)
                  : Colors.transparent,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            backgroundColor: WidgetStateProperty.resolveWith<Color?>(
              (s) => s.contains(WidgetState.hovered)
                  ? const Color(0xFFF0F0F0)
                  : Colors.transparent,
            ),
          ),
        ),
        switchTheme: SwitchThemeData(
          trackOutlineWidth: const WidgetStatePropertyAll(0),
        ),
        dividerTheme: const DividerThemeData(color: Color(0xFFE5E5E5), thickness: 1),
      ),
      darkTheme: ThemeData(
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4CC2FF),
          onPrimary: Color(0xFF001B33),
          primaryContainer: Color(0xFF103049),
          onPrimaryContainer: Color(0xFFE6F6FF),
          surface: Color(0xFF2B2B2B),
          onSurface: Colors.white,
          surfaceContainerHighest: Color(0xFF3B3B3B),
          onSurfaceVariant: Color(0xFFC5C5C5),
          outline: Color(0xFF6E6E6E),
          outlineVariant: Color(0xFF3B3B3B),
          error: Color(0xFFC42B1C),
          errorContainer: Color(0xFF5A2B24),
          onErrorContainer: Color(0xFFFFDAD6),
          secondary: Color(0xFF4CC2FF),
          onSecondary: Color(0xFF001B33),
        ),
        useMaterial3: true,
        fontFamily: 'Segoe UI',
        scaffoldBackgroundColor: const Color(0xFF202020),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF2B2B2B),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFF6E6E6E)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFF5A5A5A)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: Color(0xFF4CC2FF), width: 2),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            minimumSize: const Size(0, 40),
            padding: const EdgeInsets.symmetric(horizontal: 18),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            minimumSize: const Size(0, 40),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF2B2B2B),
          foregroundColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          toolbarHeight: 48,
          titleTextStyle: TextStyle(
            fontFamily: 'Segoe UI',
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF2B2B2B),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF2B2B2B),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        listTileTheme: ListTileThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        popupMenuTheme: PopupMenuThemeData(
          color: const Color(0xFF2B2B2B),
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        menuTheme: MenuThemeData(
          style: MenuStyle(
            backgroundColor: WidgetStateProperty.all(const Color(0xFF2B2B2B)),
            surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
            shape: WidgetStateProperty.all(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        scrollbarTheme: ScrollbarThemeData(
          thumbColor: const WidgetStatePropertyAll<Color?>(Color(0xFF6E6E6E)),
          trackColor: const WidgetStatePropertyAll<Color?>(Color(0xFF3B3B3B)),
          thumbVisibility: const WidgetStatePropertyAll<bool?>(true),
          thickness: const WidgetStatePropertyAll<double?>(8),
          radius: const Radius.circular(4),
          minThumbLength: 48,
          interactive: true,
        ),
        iconButtonTheme: IconButtonThemeData(
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            backgroundColor: WidgetStateProperty.resolveWith<Color?>(
              (s) => s.contains(WidgetState.hovered)
                  ? const Color(0x14FFFFFF)
                  : Colors.transparent,
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: ButtonStyle(
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            backgroundColor: WidgetStateProperty.resolveWith<Color?>(
              (s) => s.contains(WidgetState.hovered)
                  ? const Color(0x14FFFFFF)
                  : Colors.transparent,
            ),
          ),
        ),
        switchTheme: SwitchThemeData(
          trackOutlineWidth: const WidgetStatePropertyAll(0),
        ),
        dividerTheme: const DividerThemeData(color: Color(0xFF3B3B3B), thickness: 1),
      ),
      home: _buildHome(),
    );
    // 桌面平台：包一层窗口框架（自定义标题栏 + 8px 圆角）
    return isDesktop ? WindowFrame(child: app) : app;
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
