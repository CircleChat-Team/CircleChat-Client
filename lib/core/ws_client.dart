// CircleChat 原生客户端 — WebSocket 封装
// 标准 RFC6455（dart 官方 web_socket_channel 库），对接服务端自研 /ws 处理器。
// 心跳每 30s；断线后按指数退避重连（1s→2s→…→30s 封顶）；重连前先 /api/me 校验会话。

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/io.dart';
import 'session.dart';

/// 连接状态
enum ConnState { off, connecting, on }

/// 服务端下发的各类事件，统一回调。
class WsClient {
  final Session session;
  ConnState state = ConnState.off;

  /// 事件回调：参数为 {type, data/from/...} 原始 JSON map。
  void Function(Map<String, dynamic> msg)? onMessage;

  /// 连接状态变化回调（供 UI 展示在线/连接中/离线）。
  void Function(ConnState state)? onState;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  int _reconnectDelay = 1000;
  bool _manualClose = false;
  bool _connectedOnce = false;

  WsClient(this.session);

  String get _wsUrl => session.config.wsUrl;

  bool get connected => _channel != null && state == ConnState.on;

  /// 建立连接。若需校验会话，可在调用前先 session.init()。
  void connect() {
    _manualClose = false;
    _setState(ConnState.connecting);
    WebSocketChannel channel;
    try {
      channel = IOWebSocketChannel.connect(
        _wsUrl,
        headers: {'Cookie': 'circlechat_token=${session.rest.cachedToken ?? ''}'},
      );
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _channel = channel;
    channel.ready.then((_) {
      _markConnected();
    }).catchError((_) {
      // 连接失败交由 stream onError/onDone 处理
    });
    _sub = channel.stream.listen(
      (data) => _handleData(data),
      onError: (_) => _handleClose(),
      onDone: () => _handleClose(),
      cancelOnError: true,
    );
  }

  void _handleData(dynamic data) {
    if (data is String) {
      try {
        final obj = jsonDecode(data);
        if (obj is Map<String, dynamic>) {
          onMessage?.call(obj);
        }
      } catch (_) {
        /* 忽略非法 JSON */
      }
    }
  }

  /// 首次连接真正建立（收到任意数据即视为活跃）。
  void _markConnected() {
    if (!_connectedOnce) {
      _connectedOnce = true;
      _reconnectDelay = 1000;
      _setState(ConnState.on);
      _startHeartbeat();
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) => send({'type': 'ping'}));
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void _handleClose() {
    _stopHeartbeat();
    _cleanupChannel();
    if (_manualClose) {
      _setState(ConnState.off);
      return;
    }
    if (!_connectedOnce) {
      // 尚未成功连上过：通过 /api/me 判断会话是否仍有效，决定是否重连
      session
          .init()
          .then((ok) {
            if (ok) {
              _scheduleReconnect();
            } else {
              _setState(ConnState.off);
              onMessage?.call({'type': 'session.invalid'});
            }
          })
          .catchError((_) => _scheduleReconnect());
    } else {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _setState(ConnState.connecting);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelay), () {
      connect();
    });
    _reconnectDelay = (_reconnectDelay * 2).clamp(1000, 30000);
  }

  void _cleanupChannel() {
    _sub?.cancel();
    _sub = null;
    _channel = null;
  }

  void _setState(ConnState s) {
    state = s;
    onState?.call(s);
  }

  /// 发送客户端→服务端消息（JSON）。
  bool send(Map<String, dynamic> obj) {
    final ch = _channel;
    if (ch == null || state != ConnState.on) return false;
    try {
      ch.sink.add(jsonEncode(obj));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 主动关闭（登出等场景）。
  void close() {
    _manualClose = true;
    _reconnectTimer?.cancel();
    _stopHeartbeat();
    _cleanupChannel();
    _setState(ConnState.off);
  }

  // ---------- 协议便捷方法 ----------

  void sendText(String content, {bool md = false, String? gid, String? pm, int? replyTo}) {
    final data = <String, dynamic>{'type': 'text', 'content': content};
    if (md) data['md'] = 1;
    if (gid != null) data['gid'] = gid;
    if (pm != null) data['pm'] = pm;
    if (replyTo != null) data['replyTo'] = replyTo;
    send({'type': 'msg', 'data': data});
  }

  void sendMedia(String kind, String url, String name, int size, {String? gid, String? pm}) {
    final data = <String, dynamic>{'type': kind, 'content': url, 'name': name, 'size': size};
    if (gid != null) data['gid'] = gid;
    if (pm != null) data['pm'] = pm;
    send({'type': 'msg', 'data': data});
  }

  void notifyTyping() => send({'type': 'typing'});

  void react(int idx, String emoji) => send({'type': 'react', 'data': {'idx': idx, 'emoji': emoji}});

  void recall(int idx) => send({'type': 'recall', 'data': {'idx': idx}});

  /// 推送在线/隐身状态。invisible: 1 隐身；away: 1 离开。
  void pushStatus({bool invisible = false, bool away = false}) {
    send({
      'type': 'status',
      'data': {'invisible': invisible ? 1 : 0, 'away': away ? 1 : 0}
    });
  }
}