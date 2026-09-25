// CircleChat 原生客户端 — 数据模型
// 字段与服务端 /api 响应及 WS 消息严格对齐（对应 Web 端 src/types.ts、src/core/chat.ts）
// 所有字段名保持英文原样，零容错。error 为 i18n 文案键，非中文。

/// 统一返回外壳。成功 ok=true；失败含 error（i18n 键或服务端直出文本）。
class ApiResult {
  final bool ok;
  final String? error;
  final String? message;
  final Map<String, dynamic> json;

  ApiResult(this.ok, this.error, this.message, this.json);

  /// 从服务端 JSON 构造；无合法 JSON 时视为失败。
  factory ApiResult.from(dynamic data) {
    if (data is Map<String, dynamic>) {
      return ApiResult(
        (data['ok'] as bool?) ?? false,
        data['error'] as String?,
        data['message'] as String?,
        data,
      );
    }
    return ApiResult(false, null, null, const {});
  }

  dynamic get(String key) => json[key];
  bool get isTrue => ok;
}

/// 好友关系（friendName -> 对方姓名）
class Friend {
  final String name;
  final bool online;
  final String? image;

  Friend(this.name, this.online, this.image);

  factory Friend.fromJson(Map<String, dynamic> j) => Friend(
        (j['name'] as String?) ?? '',
        (j['online'] as bool?) ?? false,
        j['image'] as String?,
      );
}

/// 收到的好友申请
class FriendRequest {
  final String from;
  final int? created;

  FriendRequest(this.from, this.created);

  factory FriendRequest.fromJson(Map<String, dynamic> j) => FriendRequest(
        (j['from'] as String?) ?? '',
        j['created'] as int?,
      );
}

/// 已发出的好友申请
class FriendSent {
  final String to;
  final int? created;

  FriendSent(this.to, this.created);

  factory FriendSent.fromJson(Map<String, dynamic> j) => FriendSent(
        (j['to'] as String?) ?? '',
        j['created'] as int?,
      );
}

/// 全部账号（侧栏用户列表）
class ChatUser {
  final String name;
  final String? image;

  ChatUser(this.name, this.image);

  factory ChatUser.fromJson(Map<String, dynamic> j) => ChatUser(
        (j['name'] as String?) ?? '',
        j['image'] as String?,
      );
}

/// 群
class ChatGroup {
  final String id;
  final String name;
  final String owner;
  final int? created;
  final int? members;
  final String? avatar;
  final String? announcement;

  ChatGroup({
    required this.id,
    required this.name,
    required this.owner,
    this.created,
    this.members,
    this.avatar,
    this.announcement,
  });

  factory ChatGroup.fromJson(Map<String, dynamic> j) => ChatGroup(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        owner: (j['owner'] as String?) ?? '',
        created: j['created'] as int?,
        members: j['members'] as int?,
        avatar: j['avatar'] as String?,
        announcement: j['announcement'] as String?,
      );
}

/// 群成员
class GroupMember {
  final String name;
  final bool owner;
  final int? joined;

  GroupMember(this.name, this.owner, this.joined);

  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        (j['name'] as String?) ?? '',
        (j['owner'] as bool?) ?? false,
        j['joined'] as int?,
      );
}

/// 入群申请
class JoinRequest {
  final String name;
  final int? created;

  JoinRequest(this.name, this.created);

  factory JoinRequest.fromJson(Map<String, dynamic> j) => JoinRequest(
        (j['name'] as String?) ?? '',
        j['created'] as int?,
      );
}

/// 群内图片/文件
class GroupFile {
  final int idx;
  final String type;
  final String? name;
  final int? size;
  final int? ts;
  final String? content;

  GroupFile(this.idx, this.type, this.name, this.size, this.ts, this.content);

  factory GroupFile.fromJson(Map<String, dynamic> j) => GroupFile(
        (j['idx'] as int?) ?? 0,
        (j['type'] as String?) ?? 'file',
        j['name'] as String?,
        j['size'] as int?,
        j['ts'] as int?,
        j['content'] as String?,
      );
}

/// 群管理详情
class GroupDetail {
  final ChatGroup group;
  final bool isOwner;
  final List<JoinRequest> requests;
  final List<GroupMember> members;
  final List<GroupFile> files;

  GroupDetail(this.group, this.isOwner, this.requests, this.members, this.files);

  factory GroupDetail.fromJson(Map<String, dynamic> j) => GroupDetail(
        ChatGroup.fromJson((j['group'] as Map<String, dynamic>?) ?? const {}),
        (j['isOwner'] as bool?) ?? false,
        ((j['requests'] as List?) ?? const [])
            .map((e) => JoinRequest.fromJson((e as Map<String, dynamic>)))
            .toList(),
        ((j['members'] as List?) ?? const [])
            .map((e) => GroupMember.fromJson((e as Map<String, dynamic>)))
            .toList(),
        ((j['files'] as List?) ?? const [])
            .map((e) => GroupFile.fromJson((e as Map<String, dynamic>)))
            .toList(),
      );
}

/// 合并转发单条记录
class MergeItem {
  final String from;
  final String type;
  final String? content;
  final String? name;
  final int? size;

  MergeItem(this.from, this.type, this.content, this.name, this.size);

  factory MergeItem.fromJson(Map<String, dynamic> j) => MergeItem(
        (j['from'] as String?) ?? '',
        (j['type'] as String?) ?? 'text',
        j['content'] as String?,
        j['name'] as String?,
        j['size'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'from': from,
        'type': type,
        'content': content,
        'name': name,
        'size': size,
      };
}

/// 合并转发数据（type='merge' 消息的 content 为 JSON 字符串）
class MergeData {
  final String? title;
  final List<MergeItem> items;

  MergeData(this.title, this.items);

  factory MergeData.fromJson(Map<String, dynamic> j) => MergeData(
        j['title'] as String?,
        ((j['items'] as List?) ?? const [])
            .map((e) => MergeItem.fromJson((e as Map<String, dynamic>)))
            .toList(),
      );
}

/// 聊天消息
class ChatMessage {
  final int? idx;
  final String type; // text | image | file | video | audio | merge
  final String from;
  final String? gid;
  final String? dm;
  final String content;
  final String? name;
  final int? size;
  final int? ts;
  final int? time;
  final int? replyTo;
  final Map<String, dynamic>? reply;
  final List<String>? at;
  final List<Map<String, dynamic>>? reactions;
  final int? recalled;
  final String? recalledBy;
  final bool fileExpired;

  ChatMessage({
    this.idx,
    required this.type,
    required this.from,
    this.gid,
    this.dm,
    required this.content,
    this.name,
    this.size,
    this.ts,
    this.time,
    this.replyTo,
    this.reply,
    this.at,
    this.reactions,
    this.recalled,
    this.recalledBy,
    this.fileExpired = false,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        idx: j['idx'] as int?,
        type: (j['type'] as String?) ?? 'text',
        from: (j['from'] as String?) ?? '',
        gid: j['gid'] as String?,
        dm: j['dm'] as String?,
        content: (j['content'] as String?) ?? '',
        name: j['name'] as String?,
        size: j['size'] as int?,
        ts: j['ts'] as int?,
        time: j['time'] as int?,
        replyTo: j['replyTo'] as int?,
        reply: j['reply'] as Map<String, dynamic>?,
        at: (j['at'] as List?)?.map((e) => e as String).toList(),
        reactions: (j['reactions'] as List?)?.map((e) => e as Map<String, dynamic>).toList(),
        recalled: j['recalled'] as int?,
        recalledBy: j['recalled_by'] as String?,
        fileExpired: (j['file_expired'] as bool?) ?? false,
      );

  /// 时间戳取值：优先 ts，回退 time，再无则为 0
  int get tsValue => ts ?? time ?? 0;
}

/// 用户资料卡
class ProfileData {
  final String name;
  final String role;
  final int? created;
  final String? image;
  final bool online;
  final int? msgs;

  ProfileData(this.name, this.role, this.created, this.image, this.online, this.msgs);

  factory ProfileData.fromJson(Map<String, dynamic> j) => ProfileData(
        (j['name'] as String?) ?? '',
        (j['role'] as String?) ?? 'user',
        j['created'] as int?,
        j['image'] as String?,
        (j['online'] as bool?) ?? false,
        j['msgs'] as int?,
      );
}

/// 处罚记录
class PenaltyItem {
  final int id;
  final String type;
  final String target;
  final String? reason;
  final String? actor;
  final int? created;
  final int? expires;
  final int? durationMs;
  final bool active;
  final bool permanent;
  final bool revoked;
  final String? revokedBy;
  final int? revokedAt;

  PenaltyItem({
    required this.id,
    required this.type,
    required this.target,
    this.reason,
    this.actor,
    this.created,
    this.expires,
    this.durationMs,
    this.active = false,
    this.permanent = false,
    this.revoked = false,
    this.revokedBy,
    this.revokedAt,
  });

  factory PenaltyItem.fromJson(Map<String, dynamic> j) => PenaltyItem(
        id: (j['id'] as int?) ?? 0,
        type: (j['type'] as String?) ?? '',
        target: (j['target'] as String?) ?? '',
        reason: j['reason'] as String?,
        actor: j['actor'] as String?,
        created: j['created'] as int?,
        expires: j['expires'] as int?,
        durationMs: j['duration_ms'] as int?,
        active: (j['active'] as bool?) ?? false,
        permanent: (j['permanent'] as bool?) ?? false,
        revoked: (j['revoked'] as bool?) ?? false,
        revokedBy: j['revoked_by'] as String?,
        revokedAt: j['revoked_at'] as int?,
      );
}

/// 举报记录
class ReportItem {
  final int id;
  final int msgIdx;
  final String? msgFrom;
  final String? msgType;
  final String? msgSnippet;
  final String? reason;
  final String? reporter;
  final String? reportedIp;
  final int? created;
  final String? status;

  ReportItem({
    required this.id,
    required this.msgIdx,
    this.msgFrom,
    this.msgType,
    this.msgSnippet,
    this.reason,
    this.reporter,
    this.reportedIp,
    this.created,
    this.status,
  });

  factory ReportItem.fromJson(Map<String, dynamic> j) => ReportItem(
        id: (j['id'] as int?) ?? 0,
        msgIdx: (j['msg_idx'] as int?) ?? 0,
        msgFrom: j['msg_from'] as String?,
        msgType: j['msg_type'] as String?,
        msgSnippet: j['msg_snippet'] as String?,
        reason: j['reason'] as String?,
        reporter: j['reporter'] as String?,
        reportedIp: j['reported_ip'] as String?,
        created: j['created'] as int?,
        status: j['status'] as String?,
      );
}

/// 审计日志条目
class LogItem {
  final int? id;
  final int ts;
  final String? actor;
  final String action;
  final String? target;
  final String? detail;
  final String? ip;

  LogItem(this.id, this.ts, this.actor, this.action, this.target, this.detail, this.ip);

  factory LogItem.fromJson(Map<String, dynamic> j) => LogItem(
        j['id'] as int?,
        (j['ts'] as int?) ?? 0,
        j['actor'] as String?,
        (j['action'] as String?) ?? '',
        j['target'] as String?,
        j['detail'] as String?,
        j['ip'] as String?,
      );
}

/// 群内文件管理粒度的文件记录（/api/groups/file 相关）
class GroupEntryFile {
  final int idx;
  final String type;
  final String? name;
  final int? size;
  final int? ts;
  final String? content;

  GroupEntryFile(this.idx, this.type, this.name, this.size, this.ts, this.content);

  factory GroupEntryFile.fromJson(Map<String, dynamic> j) => GroupEntryFile(
        (j['idx'] as int?) ?? 0,
        (j['type'] as String?) ?? 'file',
        j['name'] as String?,
        j['size'] as int?,
        j['ts'] as int?,
        j['content'] as String?,
      );
}