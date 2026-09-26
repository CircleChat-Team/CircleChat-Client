// CircleChat 原生客户端 — 侧栏
// 结构：品牌栏 + 搜索/功能菜单 + 直排列表（好友申请 → 群与好友按最近消息置顶）+ 底部用户栏。
// 与 Web 端 Sidebar.vue 行为对齐：未读数角标、在线/离开/离线状态、群管理入口（暂未开放）。

import 'package:flutter/material.dart';

import '../../state/chat_store.dart';
import '../../core/intl.dart';
import '../../core/models.dart';
import 'avatar.dart';
import '../toast.dart';

class Sidebar extends StatefulWidget {
  final ChatStore store;

  /// 窄屏点选会话后回调（用于切换到聊天视图）
  final VoidCallback? onOpenChat;

  /// NavigationView 折叠模式：仅显示图标
  final bool collapsed;

  const Sidebar({
    super.key,
    required this.store,
    this.onOpenChat,
    this.collapsed = false,
  });

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  final _qCtrl = TextEditingController();
  String _q = '';

  ChatStore get store => widget.store;

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  void _openChat() => widget.onOpenChat?.call();

  void _toast(String key) {
    if (!mounted) return;
    Toast.show(context, tr(key));
  }

  Future<String?> _prompt(String title, String label) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: Text(tr('common.ok')),
          ),
        ],
      ),
    );
  }

  // ---------- “+” 功能菜单 ----------

  Future<void> _createGroup() async {
    final name = await _prompt(
      tr('chat.group.create'),
      tr('chat.group.create.name'),
    );
    if (name == null || name.isEmpty) return;
    final ok = await store.createGroup(name);
    _toast(ok ? 'chat.create.done' : 'chat.create.fail');
  }

  Future<void> _joinGroup() async {
    final gid = await _prompt(tr('chat.group.join'), tr('chat.group.join.gid'));
    if (gid == null || gid.isEmpty) return;
    final ok = await store.joinGroup(gid);
    _toast(ok ? 'chat.join.done' : 'chat.join.fail');
  }

  Future<void> _friendAdd() async {
    final name = await _prompt(
      tr('chat.friend.add'),
      tr('chat.friend.add.name'),
    );
    if (name == null || name.isEmpty) return;
    final ok = await store.friendRequest(name);
    _toast(ok ? 'chat.friend.done' : 'chat.friend.fail');
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: dark ? const Color(0xFF232323) : const Color(0xFFFAFAFA),
      child: Column(
        children: [
          _head(),
          _tools(),
          Expanded(child: _list()),
          _foot(),
        ],
      ),
    );
  }

  Widget _head() {
    final scheme = Theme.of(context).colorScheme;
    if (widget.collapsed) {
      return Container(
        height: 56,
        alignment: Alignment.center,
        child: Icon(Icons.forum, size: 20, color: scheme.primary),
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
      alignment: Alignment.centerLeft,
      child: Text(
        'CircleChat',
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }

  Widget _tools() {
    final popup = PopupMenuButton<String>(
      icon: const Icon(Icons.add),
      tooltip: tr('chat.friend.add'),
      onSelected: (v) {
        switch (v) {
          case 'group_create':
            _createGroup();
          case 'group_join':
            _joinGroup();
          case 'friend_add':
            _friendAdd();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'group_create',
          child: Text(tr('chat.group.create')),
        ),
        PopupMenuItem(value: 'group_join', child: Text(tr('chat.group.join'))),
        PopupMenuItem(value: 'friend_add', child: Text(tr('chat.friend.add'))),
      ],
    );
    if (widget.collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(child: popup),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _qCtrl,
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: tr('sidebar.search.placeholder'),
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: 4),
          popup,
        ],
      ),
    );
  }

  Widget _list() {
    final entries = store.sidebarSearch(_q);
    final requests = store.friendRequests;
    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        for (final r in requests) _requestItem(r),
        for (final e in entries) e.isGroup ? _groupItem(e) : _friendItem(e),
        if (entries.isEmpty && requests.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                tr('chat.friend.empty'),
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
            ),
          ),
      ],
    );
  }

  Widget _requestItem(FriendRequest r) {
    if (widget.collapsed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Icon(
            Icons.person_add,
            size: 22,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(r.from, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          TextButton(
            onPressed: () => store.friendAccept(r.from),
            child: Text(tr('chat.friend.accept')),
          ),
          TextButton(
            onPressed: () => store.friendDecline(r.from),
            child: Text(
              tr('chat.friend.reject'),
              style: TextStyle(color: Colors.grey[600]),
            ),
          ),
        ],
      ),
    );
  }

  /// 选中指示条：左侧 2px 圆角强调色条（Win11 NavigationView 风格）
  Widget _activeBar(Color color) {
    return Positioned(
      left: 6,
      top: 18,
      bottom: 18,
      child: Container(
        width: 3,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _groupItem(SidebarEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final active = store.active.gid == e.group!.id;
    final unread = store.unread['g:${e.group!.id}'] ?? 0;
    final collapsed = widget.collapsed;
    return InkWell(
      onTap: () {
        _openChat();
        store.switchRoom(e.group!.id);
      },
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: active ? scheme.primaryContainer : null,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 12 : 10,
              vertical: 8,
            ),
            child: Row(
              mainAxisAlignment: collapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Avatar(
                  name: e.name,
                  image: e.avatar != null ? store.mediaUrl(e.avatar!) : '',
                  size: collapsed ? 32 : 36,
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      e.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: active ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                ],
                if (unread > 0) _unreadBadge(unread),
              ],
            ),
          ),
          if (active) _activeBar(scheme.primary),
        ],
      ),
    );
  }

  Widget _friendItem(SidebarEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final name = e.friend!.name;
    final active = store.active.dm == name;
    final online = store.isOnline(name);
    final away = store.isAway(name);
    final unread = store.unread['d:$name'] ?? 0;
    final statusColor = away
        ? Colors.orange
        : (online ? Colors.green : Colors.grey);
    final collapsed = widget.collapsed;
    return InkWell(
      onTap: () {
        if (name == store.me) return;
        _openChat();
        store.switchRoomToDm(name);
      },
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: active ? scheme.primaryContainer : null,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: collapsed ? 12 : 10,
              vertical: 8,
            ),
            child: Row(
              mainAxisAlignment: collapsed
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Stack(
                  children: [
                    Avatar(
                      name: name,
                      image: store.avatarUrl(name),
                      size: collapsed ? 32 : 36,
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.surface, width: 1.5),
                        ),
                      ),
                    ),
                  ],
                ),
                if (!collapsed) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: active ? FontWeight.w600 : null,
                          ),
                        ),
                        Text(
                          away
                              ? tr('chat.away')
                              : online
                              ? tr('chat.online')
                              : tr('chat.offline'),
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (unread > 0) _unreadBadge(unread),
              ],
            ),
          ),
          if (active) _activeBar(scheme.primary),
        ],
      ),
    );
  }

  Widget _unreadBadge(int n) {
    final label = n > 99 ? '99+' : '$n';
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }

  Widget _foot() {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final collapsed = widget.collapsed;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: dark ? const Color(0xFF3B3B3B) : const Color(0xFFE5E5E5),
          ),
        ),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: collapsed ? 4 : 10,
        vertical: 6,
      ),
      child: collapsed
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Avatar(
                  name: store.me,
                  image: store.avatarUrl(store.me),
                  size: 32,
                ),
                IconButton(
                  tooltip: tr('common.logout'),
                  icon: const Icon(Icons.logout),
                  onPressed: () => store.logout(),
                ),
              ],
            )
          : Row(
              children: [
                Avatar(
                  name: store.me,
                  image: store.avatarUrl(store.me),
                  size: 32,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    store.me,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: tr('common.logout'),
                  icon: const Icon(Icons.logout),
                  onPressed: () => store.logout(),
                ),
              ],
            ),
    );
  }
}
