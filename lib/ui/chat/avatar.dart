// CircleChat 原生客户端 — 通用圆形头像
// 有图片显示图片；无图时显示姓名首字 + 稳定底色（与 Web 端 avatarColor 一致）。

import 'package:flutter/material.dart';
import '../../core/format.dart';

class Avatar extends StatelessWidget {
  final String name;
  final String image; // 空串表示无图
  final double size;

  const Avatar({super.key, required this.name, this.image = '', this.size = 36});

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (image.isNotEmpty) {
      child = ClipOval(
        child: Image.network(
          image,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _letter(),
          loadingBuilder: (c, w, p) => p == null ? w : _letter(),
        ),
      );
    } else {
      child = _letter();
    }
    return SizedBox(width: size, height: size, child: child);
  }

  Widget _letter() {
    final initial =
        (name.isEmpty ? '?' : name.substring(0, 1)).toUpperCase();
    return Container(
      width: size,
      height: size,
      decoration:
          BoxDecoration(color: Color(avatarColor(name)), shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
