// CircleChat 原生客户端 — 格式化工具

/// 字节数 → 可读大小（与 Web 端 fmtSize 语义一致）
String fmtSize(num? bytes) {
  final b = bytes ?? 0;
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var u = -1;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(1)} ${u < 0 ? 'B' : units[u]}';
}

/// 时间戳（ms）→ 时:分
String clock(int? ts) {
  final d = DateTime.fromMillisecondsSinceEpoch(ts ?? 0);
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${two(d.hour)}:${two(d.minute)}';
}

/// 根据名称生成稳定的头像底色（与 Web 端 avatarColor 一致）
int avatarColor(String name) {
  const palette = <int>[
    0xFF07c160, 0xFF10aeff, 0xFFf76260, 0xFFffc300,
    0xFF6467f0, 0xFFff7a45, 0xFF34c759, 0xFFff2d55,
    0xFF5ac8fa, 0xFFa2845e, 0xFF5856d6, 0xFFff9500,
  ];
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

/// 时间戳 → 友好显示：今天显示时:分，今天以前显示 月-日，跨年显示 年-月-日
String friendlyTime(int? ts) {
  if (ts == null || ts <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ts);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  String two(int n) => n < 10 ? '0$n' : '$n';
  if (day == today) {
    return '${two(d.hour)}:${two(d.minute)}';
  }
  if (d.year == now.year) {
    return '${two(d.month)}-${two(d.day)}';
  }
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}