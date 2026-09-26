// CircleChat 原生客户端 — 主界面
// 布局：宽屏（≥760px）为“侧栏 + 聊天区”双栏；窄屏在侧栏 / 聊天之间切换。
// 顶部栏显示连接状态与会话标题；错误提示（store.onError）以 SnackBar 呈现。

import 'package:flutter/material.dart';
import '../../state/chat_store.dart';
import '../../core/intl.dart';
import '../../core/ws_client.dart';
import 'sidebar.dart';
import 'message_list.dart';
import 'input_bar.dart';
import '../toast.dart';

class HomeScreen extends StatefulWidget {
  final ChatStore store;

  const HomeScreen({super.key, required this.store});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  ChatStore get store => widget.store;
  bool _chatOpen = false;

  /// NavigationView 折叠状态：折叠后侧栏仅显示图标（宽约 56px）
  bool _navCollapsed = false;

  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
    store.onError = _toast;
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (mounted) setState(() {});
  }

  void _toast(String key) {
    if (!mounted) return;
    Toast.show(context, tr(key));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 760;
          if (wide) {
            return Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  width: _navCollapsed ? 56 : 280,
                  child: Sidebar(store: store, collapsed: _navCollapsed),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: _chat()),
              ],
            );
          }
          // 窄屏：侧栏 / 聊天 二选一
          return _chatOpen
              ? _chat(onBack: () => setState(() => _chatOpen = false))
              : Sidebar(
                  store: store,
                  onOpenChat: () => setState(() => _chatOpen = true),
                );
        },
      ),
    );
  }

  Widget _chat({VoidCallback? onBack}) {
    final scheme = Theme.of(context).colorScheme;
    final conn = store.connState;
    final connIcon = switch (conn) {
      ConnState.on => Icons.cloud_done,
      ConnState.connecting => Icons.cloud_sync,
      ConnState.off => Icons.cloud_off,
    };
    final connColor = conn == ConnState.on ? Colors.green : Colors.grey;

    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Column(
      children: [
        AppBar(
          titleSpacing: 0,
          leading: onBack != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: onBack,
                )
              // 宽屏：NavigationView 折叠/展开按钮
              : IconButton(
                  tooltip: tr(_navCollapsed ? 'nav.expand' : 'nav.collapse'),
                  icon: Icon(_navCollapsed ? Icons.menu : Icons.menu_open),
                  onPressed: () => setState(() => _navCollapsed = !_navCollapsed),
                ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(connIcon, size: 18, color: connColor),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  store.roomTitle.isEmpty ? tr('chat.placeholder') : store.roomTitle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          backgroundColor: scheme.surface,
        ),
        Expanded(child: MessageList(store: store)),
        if (store.hasRoom) InputBar(store: store),
      ],
      ),
    );
  }
}
