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
import 'mailbox_panel.dart';
import '../toast.dart';

class HomeScreen extends StatefulWidget {
  final ChatStore store;

  const HomeScreen({super.key, required this.store});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  ChatStore get store => widget.store;
  bool _chatOpen = false;

  /// NavigationView 折叠状态：折叠后侧栏仅显示图标（宽约 56px）
  bool _navCollapsed = false;

  late final AnimationController _navCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
    value: 1.0, // 1 = 展开宽度，0 = 折叠宽度
  );

  late final Animation<double> _navAnim = CurvedAnimation(
    parent: _navCtrl,
    curve: Curves.easeOutCubic,
  );

  void _toggleNav() {
    if (_navCollapsed) {
      setState(() => _navCollapsed = false);
      _navCtrl.forward();
    } else {
      setState(() => _navCollapsed = true);
      _navCtrl.reverse();
    }
  }

  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
    store.onError = _toast;
  }

  @override
  void dispose() {
    _navCtrl.dispose();
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
            // Win11 布局：侧栏与聊天区为独立圆角卡片，浮在亚克力背景上
            return Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedBuilder(
                    animation: _navAnim,
                    builder: (context, _) {
                      final width = 56 + 224 * _navAnim.value;
                      // Keep expanded controls out of the narrow range where
                      // their minimum sizes would overflow during the tween.
                      final compact = width < 240;
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: SizedBox(
                          width: width,
                          child: Sidebar(store: store, collapsed: compact),
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _chat(),
                    ),
                  ),
                ],
              ),
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

    final dark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: dark ? const Color(0xFF2B2B2B) : const Color(0xFFFFFFFF),
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
                    onPressed: _toggleNav,
                  ),
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(connIcon, size: 18, color: connColor),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    store.roomTitle.isEmpty
                        ? tr('chat.placeholder')
                        : store.roomTitle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            backgroundColor: scheme.surface,
            actions: [
              IconButton(
                tooltip: tr('mailbox.title'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => MailboxPanel(store: store),
                ),
                icon: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    const Icon(Icons.notifications_outlined),
                    if (store.inboxUnread > 0)
                      Positioned(
                        right: -2,
                        top: -2,
                        child: Container(
                          width: 9,
                          height: 9,
                          decoration: const BoxDecoration(
                            color: Colors.red,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          Expanded(child: MessageList(store: store)),
          if (store.hasRoom) InputBar(store: store),
        ],
      ),
    );
  }
}
