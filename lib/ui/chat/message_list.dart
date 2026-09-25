// CircleChat 原生客户端 — 消息列表
// 渲染当前会话消息 + 底部“正在输入”提示；切换会话后定位到底部，
// 停留在底部时收到新消息自动跟随滚动。

import 'package:flutter/material.dart';
import '../../state/chat_store.dart';
import '../../core/intl.dart';
import 'message_bubble.dart';

class MessageList extends StatefulWidget {
  final ChatStore store;

  const MessageList({super.key, required this.store});

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final _scroll = ScrollController();
  int _lastLen = -1;
  String? _lastRoom;

  ChatStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    store.addListener(_onStore);
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    _scroll.dispose();
    super.dispose();
  }

  void _onStore() {
    if (!mounted) return;
    final room = store.active.key;
    final len = store.messages.length;
    final roomChanged = room != _lastRoom;
    final grew = len > _lastLen || _lastLen < 0;
    _lastRoom = room;
    _lastLen = len;
    setState(() {});
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.maxScrollExtent - pos.pixels < 120;
    if (roomChanged || (grew && atBottom)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!store.hasRoom) {
      return Center(
        child: Text(
          tr('chat.placeholder'),
          style: TextStyle(color: Colors.grey[600]),
        ),
      );
    }
    final msgs = store.messages;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: msgs.length + 1,
      itemBuilder: (context, i) {
        if (i == msgs.length) return _typingIndicator();
        return MessageBubble(
          store: store,
          m: msgs[i],
          isGroup: store.active.gid != null,
        );
      },
    );
  }

  Widget _typingIndicator() {
    final who = store.typingWho;
    if (who == null || who.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 60, 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 220),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          tr('chat.typing', args: [who]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
