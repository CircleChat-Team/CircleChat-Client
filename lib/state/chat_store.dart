// CircleChat 原生客户端 — 全局状态管理
// 持有会话数据（我的信息、在线名单、群、好友、未读、消息列表），
// 消费 WebSocket 下发的各类事件，并向 UI 提供响应式状态（ChangeNotifier）。

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/ws_client.dart';
import '../core/session.dart';

/// 一个会话键：群 'g:id' / 私聊 'd:peer'
class RoomKey {
  final String? gid;
  final String? dm;
  RoomKey({this.gid, this.dm});

  String? get key {
    if (gid != null) return 'g:$gid';
    if (dm != null) return 'd:$dm';
    return null;
  }

  String? get peer {
    // 私聊会话中自己之外的另一方
    return dm;
  }

  bool matches(ChatMessage m) {
    if (gid != null) return m.gid == gid;
    if (dm != null) {
      if (m.dm == null) return false;
      final peers = m.dm!.split(':');
      return peers.contains(dm);
    }
    return m.gid == null && m.dm == null;
  }
}

/// 侧栏直排条目：群或好友，带最近消息时间排序键（与 Web 端行为一致）
class SidebarEntry {
  final ChatGroup? group;
  final Friend? friend;
  final int sort;

  SidebarEntry.group(ChatGroup g, int s) : group = g, friend = null, sort = s;
  SidebarEntry.friend(Friend f, int s) : group = null, friend = f, sort = s;

  bool get isGroup => group != null;
  String get id => isGroup ? 'g:${group!.id}' : 'd:${friend!.name}';
  String get name => isGroup ? group!.name : friend!.name;
  String? get owner => group?.owner;
  String? get avatar => group?.avatar;
}

class ChatStore extends ChangeNotifier {
  late Session session;
  late WsClient ws;

  // 我的身份
  String me = '';
  String role = 'user';
  bool isAdmin = false;
  bool muted = false;
  int? mutedUntil;

  // 在线名单
  final List<String> online = [];
  final List<String> away = [];

  // 数据
  List<ChatUser> allUsers = [];
  List<ChatGroup> myGroups = [];
  List<Friend> myFriends = [];
  List<FriendRequest> friendRequests = [];
  List<FriendSent> friendSent = [];
  List<AnnouncementItem> announcements = [];
  List<InboxNotification> inboxNotifications = [];
  List<PenaltyItem> myPenalties = [];
  int get inboxUnread => inboxNotifications.where((item) => !item.read).length;

  // 当前会话
  RoomKey active = RoomKey();
  List<ChatMessage> messages = [];
  Map<String, bool> _renderedIdx = {};
  String? typingWho;

  // 未读
  final Map<String, int> unread = {};
  final Map<String, int> lastTs = {};

  // 连接状态
  ConnState connState = ConnState.off;

  ChatStore(this.session) {
    ws = WsClient(session);
    ws.onMessage = _handleWs;
    ws.onState = (s) {
      connState = s;
      notifyListeners();
    };
  }

  bool isFriendOf(String name) => myFriends.any((f) => f.name == name);

  /// 是否已选中会话（群或私聊）
  bool get hasRoom => active.gid != null || active.dm != null;

  /// 当前会话显示名：群名 / 私聊对方 / 空
  String get roomTitle {
    final a = active;
    if (a.gid != null) {
      for (final g in myGroups) {
        if (g.id == a.gid) return g.name;
      }
      return '';
    }
    return a.dm ?? '';
  }

  /// 头像图片地址（可能为相对路径，需经 mediaUrl 解析）
  String avatarOf(String name) => _findUser(name)?.image ?? '';

  /// 头像完整可访问地址；无头像返回空串（UI 显示首字占位）。
  String avatarUrl(String name) {
    final img = avatarOf(name);
    return img.isEmpty ? '' : mediaUrl(img);
  }

  /// 把相对资源路径解析成完整地址（上传/媒体展示用）
  String mediaUrl(String pathOrUrl) => session.config.resolve(pathOrUrl);

  /// 侧栏直排条目：群 + 好友合并，按最近消息时间置顶
  List<SidebarEntry> get sidebarItems {
    final items = <SidebarEntry>[];
    for (final g in myGroups) {
      items.add(SidebarEntry.group(g, lastTs['g:${g.id}'] ?? 0));
    }
    for (final f in myFriends) {
      items.add(SidebarEntry.friend(f, lastTs['d:${f.name}'] ?? 0));
    }
    items.sort((a, b) => b.sort.compareTo(a.sort));
    return items;
  }

  /// 侧栏搜索过滤（按名称小写包含匹配）
  List<SidebarEntry> sidebarSearch(String q) {
    final kw = q.trim().toLowerCase();
    if (kw.isEmpty) return sidebarItems;
    return sidebarItems
        .where((e) => e.name.toLowerCase().contains(kw))
        .toList();
  }

  bool get dmGating => active.dm != null && !isFriendOf(active.dm!);

  bool isOnline(String name) => online.contains(name) || name == me;

  bool isAway(String name) => name != me && away.contains(name);

  String imageOf(String name) => _findUser(name)?.image ?? '';

  ChatUser? _findUser(String name) {
    for (final u in allUsers) {
      if (u.name == name) return u;
    }
    return null;
  }

  // ---------------- 初始化 ----------------

  Future<void> init(String newMe) async {
    me = newMe;
    role = session.role;
    isAdmin = session.isAdmin;
    connect();
    await Future.wait([loadUsers(), loadFriends(), loadGroups(), loadInbox()]);
    notifyListeners();
  }

  void connect() {
    ws.connect();
  }

  // ---------------- 数据加载 ----------------

  Future<void> loadUsers() async {
    try {
      final r = await session.rest.get('/api/users');
      if (r.ok) {
        allUsers = ((r.json['users'] as List?) ?? const [])
            .map((e) => ChatUser.fromJson((e as Map<String, dynamic>)))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> loadFriends() async {
    try {
      final r = await session.rest.get('/api/friends');
      if (r.ok) {
        myFriends = ((r.json['friends'] as List?) ?? const [])
            .map((e) => Friend.fromJson((e as Map<String, dynamic>)))
            .toList();
        friendRequests = ((r.json['requests'] as List?) ?? const [])
            .map((e) => FriendRequest.fromJson((e as Map<String, dynamic>)))
            .toList();
        friendSent = ((r.json['sent'] as List?) ?? const [])
            .map((e) => FriendSent.fromJson((e as Map<String, dynamic>)))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> loadGroups() async {
    try {
      final r = await session.rest.get('/api/groups');
      if (r.ok) {
        myGroups = ((r.json['groups'] as List?) ?? const [])
            .map((e) => ChatGroup.fromJson((e as Map<String, dynamic>)))
            .toList();
        notifyListeners();
        // 被移除/退出群后自动退回第一个群
        if (active.gid != null && !myGroups.any((g) => g.id == active.gid)) {
          switchRoom(myGroups.isNotEmpty ? myGroups.first.id : null);
        }
        // 首次加载且未选择任何会话时，默认进入第一个群
        if (!hasRoom && myGroups.isNotEmpty) {
          switchRoom(myGroups.first.id);
        }
      }
    } catch (_) {}
  }

  Future<void> loadInbox() async {
    try {
      final results = await Future.wait([
        session.rest.get('/api/announcements'),
        session.rest.get('/api/me/notifications'),
        session.rest.get('/api/me/penalties'),
      ]);
      final a = results[0];
      final n = results[1];
      final p = results[2];
      if (a.ok) {
        announcements = ((a.json['announcements'] as List?) ?? const [])
            .map(
              (item) => AnnouncementItem.fromJson(item as Map<String, dynamic>),
            )
            .toList();
      }
      if (n.ok) {
        inboxNotifications = ((n.json['notifications'] as List?) ?? const [])
            .map(
              (item) =>
                  InboxNotification.fromJson(item as Map<String, dynamic>),
            )
            .toList();
      }
      if (p.ok) {
        myPenalties = ((p.json['penalties'] as List?) ?? const [])
            .map((item) => PenaltyItem.fromJson(item as Map<String, dynamic>))
            .toList();
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> markInboxRead() async {
    if (inboxUnread == 0) return;
    try {
      final result = await session.rest.post('/api/me/notifications/read');
      if (result.ok) {
        inboxNotifications = inboxNotifications
            .map(
              (item) => InboxNotification(
                id: item.id,
                title: item.title,
                body: item.body,
                created: item.created,
                read: true,
              ),
            )
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  // ---------------- 会话切换 ----------------

  void switchRoom(String? gid) {
    active = RoomKey(gid: gid);
    _resetRoom();
    clearUnread('g:$gid');
    loadHistory();
    notifyListeners();
  }

  void switchRoomToDm(String peer) {
    if (peer.isEmpty || peer == me) return;
    active = RoomKey(dm: peer);
    _resetRoom();
    clearUnread('d:$peer');
    loadHistory();
    notifyListeners();
  }

  void _resetRoom() {
    messages = [];
    _renderedIdx = {};
  }

  Future<void> loadHistory() async {
    final a = active;
    if (a.gid == null && a.dm == null) {
      notifyListeners();
      return;
    }
    try {
      final r = await session.rest.get(
        '/api/messages',
        query: a.gid != null ? {'gid': a.gid!} : {'dm': a.dm!},
      );
      if (r.ok) {
        // 防止异步返回时用户已切换会话
        if (active.gid != a.gid || active.dm != a.dm) return;
        final list = ((r.json['messages'] as List?) ?? const [])
            .map((e) => ChatMessage.fromJson((e as Map<String, dynamic>)))
            .toList();
        messages = list;
        _renderedIdx = {};
        for (final m in messages) {
          if (m.idx != null) _renderedIdx['${m.idx}'] = true;
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  void clearUnread(String key) {
    unread.remove(key);
    notifyListeners();
  }

  int get unreadTotal {
    var n = 0;
    unread.forEach((k, v) => n += v);
    return n;
  }

  // ---------------- WebSocket 事件处理 ----------------

  void _handleWs(Map<String, dynamic> obj) {
    final type = obj['type'] as String? ?? '';
    switch (type) {
      case 'msg':
        _onWsMsg(obj['data']);
        break;
      case 'recall':
        _onWsRecall(obj['data']);
        break;
      case 'typing':
        if (obj['from'] is String &&
            obj['from'] != me &&
            obj['from'] == active.dm) {
          typingWho = obj['from'] as String;
          notifyListeners();
        }
        break;
      case 'reaction':
        _onWsReaction(obj['data']);
        break;
      case 'presence':
        online
          ..clear()
          ..addAll(
            (obj['users'] as List?)?.map((e) => e as String) ?? const [],
          );
        away
          ..clear()
          ..addAll((obj['away'] as List?)?.map((e) => e as String) ?? const []);
        notifyListeners();
        break;
      case 'groups.changed':
        loadGroups();
        break;
      case 'friends.changed':
        loadFriends();
        break;
      case 'penalty':
        _onPenalty(obj['data']);
        break;
      case 'logged.out':
        _onLoggedOut();
        break;
      case 'me.changed':
        if (obj['username'] is String && obj['username'] != me) {
          me = obj['username'] as String;
          session.config.username = me;
          session.config.save();
          notifyListeners();
        }
        break;
      case 'session.invalid':
        // 会话失效：通知 UI 回到登录
        onSessionInvalid?.call();
        break;
      default:
        break;
    }
  }

  /// 会话失效回调（由 UI 挂接到登录流程）。
  void Function()? onSessionInvalid;

  void _onWsMsg(dynamic data) {
    if (data is! Map<String, dynamic>) return;
    final m = ChatMessage.fromJson(data);
    _bumpRoom(m);
    if (active.matches(m)) {
      _appendMsg(m);
    }
    if (m.from != me) {
      if (!active.matches(m)) _addUnread(m);
    }
    notifyListeners();
  }

  void _appendMsg(ChatMessage m) {
    if (m.idx != null) {
      final k = '${m.idx}';
      if (_renderedIdx[k] == true) return;
      _renderedIdx[k] = true;
    }
    messages.add(m);
  }

  void _bumpRoom(ChatMessage m) {
    final k = _roomKeyOf(m);
    if (k != null) lastTs[k] = DateTime.now().millisecondsSinceEpoch;
  }

  String? _roomKeyOf(ChatMessage m) {
    if (m.gid != null) return 'g:${m.gid}';
    if (m.dm != null) {
      final peers = m.dm!
          .split(':')
          .where((n) => n.isNotEmpty && n != me)
          .toList();
      if (peers.isNotEmpty) return 'd:${peers.first}';
    }
    return null;
  }

  void _addUnread(ChatMessage m) {
    final k = _roomKeyOf(m);
    if (k != null) {
      unread[k] = (unread[k] ?? 0) + 1;
    }
  }

  void _onWsRecall(dynamic data) {
    if (data is! Map<String, dynamic>) return;
    final idx = data['idx'];
    if (idx is! int) return;
    for (final m in messages) {
      if (m.idx == idx) {
        // ChatMessage 是 immutable，这里重建替换
        final i = messages.indexOf(m);
        messages[i] = ChatMessage(
          idx: m.idx,
          type: m.type,
          from: m.from,
          gid: m.gid,
          dm: m.dm,
          content: m.content,
          name: m.name,
          size: m.size,
          ts: m.ts,
          time: m.time,
          replyTo: m.replyTo,
          reply: m.reply,
          at: m.at,
          reactions: m.reactions,
          recalled: 1,
          recalledBy: (data['by'] as String?) ?? '',
        );
        notifyListeners();
        break;
      }
    }
  }

  void _onWsReaction(dynamic data) {
    if (data is! Map<String, dynamic>) return;
    final idx = data['idx'];
    if (idx is! int) return;
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.idx == idx) {
        final old = m;
        messages[i] = ChatMessage(
          idx: old.idx,
          type: old.type,
          from: old.from,
          gid: old.gid,
          dm: old.dm,
          content: old.content,
          name: old.name,
          size: old.size,
          ts: old.ts,
          time: old.time,
          replyTo: old.replyTo,
          reply: old.reply,
          at: old.at,
          reactions: (data['reactions'] as List?)
              ?.map((e) => e as Map<String, dynamic>)
              .toList(),
          recalled: old.recalled,
          recalledBy: old.recalledBy,
        );
        notifyListeners();
        break;
      }
    }
  }

  void _onPenalty(dynamic data) {
    if (data is! Map<String, dynamic>) return;
    muted = (data['muted'] as bool?) ?? false;
    mutedUntil = data['mutedUntil'] is num
        ? (data['mutedUntil'] as num).toInt()
        : null;
    if ((data['banned'] as bool?) == true) {
      // 被封禁：退出登录
      _onLoggedOut();
      return;
    }
    notifyListeners();
  }

  void _onLoggedOut() {
    session.logout();
    ws.close();
    onSessionInvalid?.call();
  }

  /// 主动注销（侧栏“退出登录”）：销毁会话并回到登录页。
  void logout() => _onLoggedOut();

  // ---------------- 发送 ----------------

  void sendText(String text, {bool md = false}) {
    final val = text.trim();
    if (val.isEmpty) return;
    if (dmGating) {
      onError?.call('chat.dm.gateToast');
      return;
    }
    ws.sendText(
      val,
      md: md,
      gid: active.gid,
      pm: active.dm,
      replyTo: _replyToIdx,
    );
  }

  int? _replyToIdx;

  void setReplyTo(int? idx) {
    _replyToIdx = idx;
    notifyListeners();
  }

  void sendMedia(String kind, String url, String name, int size) {
    ws.sendMedia(kind, url, name, size, gid: active.gid, pm: active.dm);
  }

  void notifyTyping() => ws.notifyTyping();

  // ---------------- 消息操作 / 社交操作 ----------------

  DateTime _lastTypingAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 输入框节流：每 2 秒最多推送一次 typing
  void notifyTypingThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastTypingAt).inMilliseconds < 2000) return;
    _lastTypingAt = now;
    ws.notifyTyping();
  }

  /// 是否可撤回：本人消息且未被撤回
  bool canRecall(ChatMessage m) =>
      (m.recalled ?? 0) == 0 && m.from == me && m.idx != null;

  void sendRecall(int idx) => ws.recall(idx);

  void sendReact(int idx, String emoji) => ws.react(idx, emoji);

  /// 当前引用回复目标（由 setReplyTo 设置的 idx 反查消息）
  ChatMessage? get replyTarget {
    final idx = _replyToIdx;
    if (idx == null) return null;
    for (final m in messages) {
      if (m.idx == idx) return m;
    }
    return null;
  }

  /// 举报一条消息；成功返回 true。
  Future<bool> reportMessage(int idx, String reason) async {
    try {
      final r = await session.rest.post(
        '/api/report',
        body: {'idx': idx, 'reason': reason},
      );
      return r.ok;
    } catch (_) {
      return false;
    }
  }

  /// 同意好友申请
  Future<void> friendAccept(String from) async {
    try {
      await session.rest.post('/api/friends/accept', body: {'from': from});
    } catch (_) {}
    await loadFriends();
  }

  /// 拒绝好友申请
  Future<void> friendDecline(String from) async {
    try {
      await session.rest.post('/api/friends/decline', body: {'from': from});
    } catch (_) {}
    await loadFriends();
  }

  /// 创建群组；成功返回 true。
  Future<bool> createGroup(String name) async {
    try {
      final r = await session.rest.post('/api/groups', body: {'name': name});
      if (r.ok) {
        await loadGroups();
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// 加入群组（公开群直接加入 / 需审核时提交申请）。
  Future<bool> joinGroup(String gid) async {
    try {
      final r = await session.rest.post('/api/groups/join', body: {'gid': gid});
      if (r.ok) {
        await loadGroups();
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// 发送好友申请；成功返回 true。
  Future<bool> friendRequest(String to) async {
    try {
      final r = await session.rest.post(
        '/api/friends/request',
        body: {'to': to},
      );
      return r.ok;
    } catch (_) {
      return false;
    }
  }

  /// 错误回调（供 UI 提示）。
  void Function(String errorKey)? onError;

  @override
  void dispose() {
    ws.close();
    super.dispose();
  }
}
