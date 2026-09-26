// CircleChat 原生客户端 — 单条消息气泡
// 文本 / 图片 / 文件 / 音视频 / 合并转发 / 撤回；支持引用回复、表情回应；
// 长按弹出操作菜单（回复 / 复制 / 撤回 / 回应 / 举报），行为与 Web 端对齐。

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../state/chat_store.dart';
import '../../core/intl.dart';
import '../../core/format.dart';
import '../../core/models.dart';
import 'avatar.dart';
import '../toast.dart';

/// 快捷回应表情（与 Web 端一致）
const _quickEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

class MessageBubble extends StatelessWidget {
  final ChatStore store;
  final ChatMessage m;
  final bool isGroup;

  const MessageBubble({
    super.key,
    required this.store,
    required this.m,
    required this.isGroup,
  });

  bool get mine => m.from == store.me;

  @override
  Widget build(BuildContext context) {
    // 撤回消息：居中灰色提示
    if ((m.recalled ?? 0) != 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            tr('chat.recalled'),
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey[600],
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    final scheme = Theme.of(context).colorScheme;
    final bubble = _bubble(context, scheme);
    final avatar = Avatar(
      name: m.from,
      image: store.avatarUrl(m.from),
      size: 34,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment:
            mine ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: mine
            ? [Flexible(child: bubble), const SizedBox(width: 8), avatar]
            : [avatar, const SizedBox(width: 8), Flexible(child: bubble)],
      ),
    );
  }

  Widget _bubble(BuildContext context, ColorScheme scheme) {
    final bg = mine ? const Color(0xFFE6F1FB) : scheme.surface;
    final fg = scheme.onSurface;
    final timeColor = mine ? scheme.onPrimary.withOpacity(0.8) : scheme.onSurfaceVariant;

    return GestureDetector(
      onLongPress: () => _showActions(context, scheme),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: mine ? const Color(0xFFC7E0F4) : const Color(0xFFE5E5E5)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 群聊中他人消息显示发送者昵称
            if (isGroup && !mine) ...[
              Text(
                m.from,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(avatarColor(m.from)),
                ),
              ),
              const SizedBox(height: 2),
            ],
            if (m.reply != null) _replyRef(scheme),
            _content(scheme, fg),
            if (m.reactions != null && m.reactions!.isNotEmpty) ...[
              const SizedBox(height: 6),
              _reactions(scheme),
            ],
            if (m.tsValue > 0) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  friendlyTime(m.tsValue),
                  style: TextStyle(fontSize: 11, color: timeColor),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _replyRef(ColorScheme scheme) {
    final r = m.reply!;
    final from = (r['from'] as String?) ?? '';
    final snippet = (r['content'] as String?) ?? '';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(from, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.primary)),
          Text(
            snippet,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _content(ColorScheme scheme, Color fg) {
    switch (m.type) {
      case 'image':
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260, maxHeight: 300),
            child: Image.network(
              store.mediaUrl(m.content),
              fit: BoxFit.contain,
              loadingBuilder: (c, w, p) =>
                  p == null ? w : const SizedBox(width: 120, height: 120, child: Center(child: CircularProgressIndicator())),
              errorBuilder: (_, __, ___) => Container(
                width: 120,
                height: 120,
                color: Colors.black.withOpacity(0.06),
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image, color: Colors.grey),
              ),
            ),
          ),
        );
      case 'file':
      case 'video':
      case 'audio':
        return _mediaCard(scheme, fg);
      case 'merge':
        return _mergeCard(scheme);
      default:
        return Text(
          m.content,
          style: TextStyle(color: fg, fontSize: 15, height: 1.35),
        );
    }
  }

  Widget _mediaCard(ColorScheme scheme, Color fg) {
    final icon = switch (m.type) {
      'video' => Icons.video_file,
      'audio' => Icons.audio_file,
      _ => Icons.insert_drive_file,
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: scheme.primary),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  m.name ?? tr('chat.file.defaultName'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                if (m.size != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    fmtSize(m.size),
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mergeCard(ColorScheme scheme) {
    var count = 0;
    try {
      final o = jsonDecode(m.content);
      if (o is Map && o['items'] is List) count = (o['items'] as List).length;
    } catch (_) {}
    final label = count > 0 ? '${tr('chat.merge.label')} · $count' : tr('chat.merge.label');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forward_to_inbox, color: scheme.primary),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  Widget _reactions(ColorScheme scheme) {
    final list = m.reactions!;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final r in list)
          ActionChip(
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: scheme.surface,
            label: Text(
              '${(r['emoji'] as String?) ?? ''} ${((r['users'] as List?) ?? const []).length}',
              style: const TextStyle(fontSize: 12),
            ),
            onPressed: m.idx == null ? null : () => store.sendReact(m.idx!, (r['emoji'] as String?) ?? ''),
          ),
      ],
    );
  }

  // ---------- 长按操作 ----------

  void _showActions(BuildContext context, ColorScheme scheme) {
    final actions = <Widget>[
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Wrap(
          spacing: 10,
          children: [
            for (final e in _quickEmojis)
              InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () {
                  Navigator.pop(context);
                  if (m.idx != null) store.sendReact(m.idx!, e);
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Text(e, style: const TextStyle(fontSize: 20)),
                ),
              ),
          ],
        ),
      ),
      ListTile(
        leading: const Icon(Icons.reply),
        title: Text(tr('chat.reply')),
        onTap: () {
          Navigator.pop(context);
          store.setReplyTo(m.idx);
        },
      ),
      if (m.type == 'text')
        ListTile(
          leading: const Icon(Icons.copy),
          title: Text(tr('chat.copy')),
          onTap: () {
            Navigator.pop(context);
            Clipboard.setData(ClipboardData(text: m.content));
          },
        )
      else
        ListTile(
          leading: const Icon(Icons.copy),
          title: Text(tr('chat.copy')),
          onTap: () {
            Navigator.pop(context);
            Clipboard.setData(ClipboardData(text: store.mediaUrl(m.content)));
          },
        ),
      if (store.canRecall(m))
        ListTile(
          leading: const Icon(Icons.undo),
          title: Text(tr('chat.recall')),
          onTap: () {
            Navigator.pop(context);
            store.sendRecall(m.idx!);
          },
        ),
      ListTile(
        leading: const Icon(Icons.report),
        title: Text(tr('chat.report.title')),
        onTap: () {
          Navigator.pop(context);
          _report(context, scheme);
        },
      ),
    ];

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [...actions, const SizedBox(height: 8)],
        ),
      ),
    );
  }

  Future<void> _report(BuildContext context, ColorScheme scheme) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('chat.report.title')),
        content: TextField(
          controller: reasonCtrl,
          maxLines: 2,
          decoration: InputDecoration(
            hintText: tr('chat.report.reason'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('chat.report.submit'))),
        ],
      ),
    );
    if (ok == true && m.idx != null) {
      final reason = reasonCtrl.text.trim();
      final done = await store.reportMessage(m.idx!, reason.isEmpty ? 'other' : reason);
      if (context.mounted) {
        Toast.show(context, tr(done ? 'chat.report.done' : 'chat.report.fail'));
      }
    }
  }
}
