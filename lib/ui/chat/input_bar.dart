// CircleChat 原生客户端 — 输入栏
// 引用回复条 + 多行文本输入 + 发送；输入时每 2 秒推送一次 typing；
// 被禁言时禁用发送并提示。

import 'package:flutter/material.dart';
import '../../state/chat_store.dart';
import '../../core/intl.dart';
import '../../core/models.dart';

class InputBar extends StatefulWidget {
  final ChatStore store;

  const InputBar({super.key, required this.store});

  @override
  State<InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<InputBar> {
  final _ctrl = TextEditingController();
  final _focusNode = FocusNode();

  ChatStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    // 进入会话后默认聚焦输入框，方便直接输入
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _send() {
    final text = _ctrl.text;
    if (text.trim().isEmpty) return;
    store.sendText(text);
    _ctrl.clear();
  }

  String _snippet(ChatMessage m) {
    if (m.type == 'text') return m.content;
    return m.name ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = store.muted;
    final reply = store.replyTarget;

    return Material(
      elevation: 0,
      color: scheme.surface,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (muted)
              Container(
                width: double.infinity,
                color: scheme.errorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  tr('chat.muted'),
                  style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
                ),
              ),
            if (reply != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${tr('chat.reply')} ${reply.from}: ${_snippet(reply)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: tr('common.close'),
                      onPressed: () => store.setReplyTo(null),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      focusNode: _focusNode,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onChanged: (_) => store.notifyTypingThrottled(),
                      onSubmitted: (_) {
                        if (!muted) _send();
                      },
                      decoration: InputDecoration(
                        hintText: tr('chat.typePlaceholder'),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filledTonal(
                    tooltip: tr('chat.typePlaceholder'),
                    onPressed: muted ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
