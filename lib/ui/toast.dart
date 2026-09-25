// CircleChat 原生客户端 — 轻提示
// 内容自适应宽度的小胶囊提示，居底显示，2 秒后自动消失；
// 仅用于简短消息提示，替代全宽/定宽的 SnackBar。

import 'dart:async';
import 'package:flutter/material.dart';

class Toast {
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(BuildContext context, String text) {
    final overlay = Overlay.of(context, rootOverlay: true);
    hide();
    _entry = OverlayEntry(
      builder: (_) {
        final scheme = Theme.of(context).colorScheme;
        return Positioned(
          left: 0,
          right: 0,
          bottom: 24,
          child: IgnorePointer(
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                constraints: const BoxConstraints(maxWidth: 320),
                decoration: BoxDecoration(
                  color: scheme.inverseSurface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onInverseSurface,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_entry!);
    _timer = Timer(const Duration(seconds: 2), hide);
  }

  static void hide() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }
}
