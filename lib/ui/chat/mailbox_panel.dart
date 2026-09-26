import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/intl.dart';
import '../../state/chat_store.dart';

class MailboxPanel extends StatefulWidget {
  final ChatStore store;
  const MailboxPanel({super.key, required this.store});
  @override
  State<MailboxPanel> createState() => _MailboxPanelState();
}

class _MailboxPanelState extends State<MailboxPanel> {
  int _tab = 0;
  @override
  void initState() {
    super.initState();
    widget.store.loadInbox();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('mailbox.title'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: tr('common.close'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Row(
              children: [
                _tabButton(0, 'mailbox.tab.announce'),
                _tabButton(1, 'mailbox.tab.notify', badge: store.inboxUnread),
                _tabButton(2, 'mailbox.tab.penalty'),
              ],
            ),
            const Divider(height: 1),
            if (_tab == 1)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: store.inboxUnread == 0
                      ? null
                      : store.markInboxRead,
                  child: Text(tr('mailbox.notify.readAll')),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: _tab == 0
                    ? _announcements(store)
                    : _tab == 1
                    ? _notifications(store)
                    : _penalties(store),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabButton(int index, String key, {int badge = 0}) => Expanded(
    child: TextButton(
      onPressed: () {
        setState(() => _tab = index);
        if (index == 1) widget.store.markInboxRead();
      },
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            tr(key),
            style: TextStyle(
              fontWeight: _tab == index ? FontWeight.bold : null,
            ),
          ),
          if (badge > 0) ...[
            const SizedBox(width: 5),
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
    ),
  );

  List<Widget> _announcements(ChatStore store) {
    if (store.announcements.isEmpty) return [_empty('mailbox.announce.empty')];
    return [
      for (final item in store.announcements)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if ((item.content ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(item.content!),
                ],
                const SizedBox(height: 6),
                Text(
                  '${item.actor ?? '—'} · ${friendlyTime(item.created)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
    ];
  }

  List<Widget> _notifications(ChatStore store) {
    if (store.inboxNotifications.isEmpty) {
      return [_empty('mailbox.notify.empty')];
    }
    return [
      for (final item in store.inboxNotifications)
        Card(
          color: item.read
              ? null
              : Theme.of(context).colorScheme.primaryContainer,
          child: ListTile(
            leading: item.read
                ? const Icon(Icons.notifications_none)
                : const Icon(
                    Icons.fiber_manual_record,
                    size: 14,
                    color: Colors.red,
                  ),
            title: Text(item.title ?? ''),
            subtitle: Text(
              [
                if ((item.body ?? '').isNotEmpty) item.body!,
                friendlyTime(item.created),
              ].join('\n'),
            ),
            isThreeLine: (item.body ?? '').isNotEmpty,
          ),
        ),
    ];
  }

  List<Widget> _penalties(ChatStore store) {
    if (store.myPenalties.isEmpty) return [_empty('mailbox.penalty.empty')];
    return [
      for (final item in store.myPenalties)
        Card(
          child: ListTile(
            title: Text(item.type),
            subtitle: Text(
              [
                tr(
                  item.active
                      ? 'mailbox.penalty.active'
                      : 'mailbox.penalty.inactive',
                ),
                if (item.permanent)
                  tr('mailbox.penalty.permanent')
                else if (item.expires != null)
                  tr(
                    'mailbox.penalty.until',
                    args: [friendlyTime(item.expires)],
                  ),
                if ((item.reason ?? '').isNotEmpty)
                  tr('mailbox.penalty.reason', args: [item.reason!]),
                tr('mailbox.penalty.actor', args: [item.actor ?? '—']),
                friendlyTime(item.created),
              ].join('\n'),
            ),
            isThreeLine: true,
          ),
        ),
    ];
  }

  Widget _empty(String key) => Padding(
    padding: const EdgeInsets.all(28),
    child: Center(child: Text(tr(key))),
  );
}
