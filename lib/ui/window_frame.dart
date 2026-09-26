// CircleChat 原生客户端 — Windows 11 窗口框架
// 无边框窗口：顶部 32px 自定义标题栏（拖动区域 + 最小化/最大化/关闭），
// 背景色模拟 Mica（浅 #F3F3F3 / 深 #202020），跟随系统主题。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 是否为桌面平台（Windows / Linux / macOS）；移动端与 Web 不启用自定义标题栏。
bool get isDesktop =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

class WindowFrame extends StatefulWidget {
  final Widget child;

  const WindowFrame({super.key, required this.child});

  @override
  State<WindowFrame> createState() => _WindowFrameState();
}

class _WindowFrameState extends State<WindowFrame> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (isDesktop) {
      windowManager.addListener(this);
      _syncMaximized();
    }
  }

  @override
  void dispose() {
    if (isDesktop) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => _syncMaximized();

  @override
  void onWindowUnmaximize() => _syncMaximized();

  Future<void> _syncMaximized() async {
    if (!isDesktop) return;
    final m = await windowManager.isMaximized();
    if (mounted && m != _maximized) setState(() => _maximized = m);
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return widget.child;
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final radius =
        _maximized ? BorderRadius.zero : BorderRadius.circular(8);
    // WindowFrame 位于 MaterialApp 外层，需自行提供 Directionality/基础 Material，
    // 否则标题栏中的 Text 会因缺少 Directionality 抛异常。
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        type: MaterialType.transparency,
        child: ClipRRect(
          borderRadius: radius,
          child: ColoredBox(
            color: dark ? const Color(0xFF202020) : const Color(0xFFF3F3F3),
            child: Column(
              children: [
                TitleBar(dark: dark, maximized: _maximized),
                Expanded(child: widget.child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 32px 自定义标题栏：左侧标题（可拖动/双击最大化），右侧窗口控制按钮。
/// 遵循 Win11 规范：标题距左 16px，按钮 46px 宽、图标 10px、full-bleed 背板。
class TitleBar extends StatelessWidget {
  final bool dark;
  final bool maximized;

  const TitleBar({super.key, required this.dark, required this.maximized});

  @override
  Widget build(BuildContext context) {
    final fg = dark ? Colors.white : const Color(0xFF1A1A1A);
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onDoubleTap: () => _toggleMaximize(),
              child: DragToMoveArea(
                child: SizedBox(
                  height: 32,
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      Text(
                        'CircleChat',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: fg,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _WinButton(
            icon: Icons.remove,
            iconColor: fg,
            dark: dark,
            isClose: false,
            onPressed: () => windowManager.minimize(),
          ),
          _WinButton(
            icon: maximized ? Icons.filter_none : Icons.crop_square,
            iconColor: fg,
            dark: dark,
            isClose: false,
            onPressed: () => _toggleMaximize(),
          ),
          _WinButton(
            icon: Icons.close,
            iconColor: fg,
            dark: dark,
            isClose: true,
            onPressed: () => windowManager.close(),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleMaximize() async {
    if (!isDesktop) return;
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }
}

/// 窗口控制按钮：46×32，悬停/按下反馈；关闭按钮悬停 #C42B1C。
class _WinButton extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final bool dark;
  final bool isClose;
  final VoidCallback onPressed;

  const _WinButton({
    required this.icon,
    required this.iconColor,
    required this.dark,
    required this.isClose,
    required this.onPressed,
  });

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    if (widget.isClose) {
      bg = _pressed
          ? const Color(0xFFB31E13)
          : _hover
              ? const Color(0xFFC42B1C)
              : Colors.transparent;
    } else {
      final base = widget.dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
      bg = _pressed
          ? base.withValues(alpha: 0.12)
          : _hover
              ? base.withValues(alpha: 0.06)
              : Colors.transparent;
    }
    // 关闭按钮悬停/按下时红底白字；其余时刻跟随主题前景色
    final iconColor = (widget.isClose && (_hover || _pressed))
        ? Colors.white
        : widget.iconColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onPressed();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: Container(
          width: 46,
          height: 32,
          color: bg,
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 10, color: iconColor),
        ),
      ),
    );
  }
}
