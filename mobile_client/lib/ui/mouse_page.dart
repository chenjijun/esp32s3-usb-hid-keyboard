// 鼠标页：触控板（单指移动 / 双指滚动 / 轻点左键）+ 三键 + 速度。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/remote.dart';
import '../core/scope.dart';
import 'theme.dart';
import 'widgets.dart';

class MousePage extends StatefulWidget {
  const MousePage({super.key});

  @override
  State<MousePage> createState() => _MousePageState();
}

class _MousePageState extends State<MousePage> {
  /// 是否处于「按住左键」状态（框选文字 / 拖文件用）
  bool _dragLock = false;

  @override
  Widget build(BuildContext context) {
    final remote = RemoteScope.of(context);

    // 断线时固件那边已经把所有键松开了，界面上的「按住左键」也要跟着复位
    if (_dragLock && !remote.connected) {
      _dragLock = false;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        children: [
          _speedRow(remote),
          const SizedBox(height: 8),
          Expanded(
            child: _Trackpad(
              haptics: remote.haptics,
              onMove: remote.moveBy,
              onClick: remote.mouseClick,
              onWheel: remote.wheel,
            ),
          ),
          const SizedBox(height: 10),
          _buttons(remote),
          const SizedBox(height: 8),
          _wheelRow(remote),
        ],
      ),
    );
  }

  Widget _speedRow(Remote remote) {
    return Row(
      children: [
        const Icon(Icons.speed, size: 16, color: C.soft),
        const SizedBox(width: 4),
        Text(
          '速度 ×${remote.mouseSpeed.toStringAsFixed(1)}',
          style: const TextStyle(fontSize: 12, color: C.soft),
        ),
        Expanded(
          child: Slider(
            value: remote.mouseSpeed,
            min: 0.4,
            max: 4.0,
            divisions: 36,
            onChanged: remote.setMouseSpeed,
          ),
        ),
        TinyButton(
          label: '1.6',
          onTap: () => remote.setMouseSpeed(1.6),
        ),
      ],
    );
  }

  Widget _buttons(Remote remote) {
    return Row(
      children: [
        _MouseKey(
          label: '左键',
          sub: '长按拖拽',
          icon: Icons.ads_click,
          held: remote.mouseHeld.contains('left'),
          haptics: remote.haptics,
          onClick: () => remote.mouseClick('left'),
          onHoldStart: () => remote.mouseDown('left'),
          onHoldEnd: () => remote.mouseUp('left'),
        ),
        const SizedBox(width: 8),
        _MouseKey(
          label: '中键',
          sub: '长按滚动',
          icon: Icons.mouse,
          held: remote.mouseHeld.contains('middle'),
          haptics: remote.haptics,
          onClick: () => remote.mouseClick('middle'),
          onHoldStart: () => remote.mouseDown('middle'),
          onHoldEnd: () => remote.mouseUp('middle'),
        ),
        const SizedBox(width: 8),
        _MouseKey(
          label: '右键',
          sub: '长按拖拽',
          icon: Icons.touch_app_outlined,
          held: remote.mouseHeld.contains('right'),
          haptics: remote.haptics,
          onClick: () => remote.mouseClick('right'),
          onHoldStart: () => remote.mouseDown('right'),
          onHoldEnd: () => remote.mouseUp('right'),
        ),
      ],
    );
  }

  Widget _wheelRow(Remote remote) {
    return Row(
      children: [
        TinyButton(
          label: '滚轮 ↑',
          icon: Icons.keyboard_arrow_up,
          onTap: () => remote.wheel(3),
        ),
        const SizedBox(width: 6),
        TinyButton(
          label: '滚轮 ↓',
          icon: Icons.keyboard_arrow_down,
          onTap: () => remote.wheel(-3),
        ),
        const Spacer(),
        TinyButton(
          label: _dragLock ? '松开左键' : '按住左键',
          icon: _dragLock ? Icons.lock : Icons.lock_open,
          tone: _dragLock ? C.accent : C.surfaceHi,
          foreground: _dragLock ? C.bg : C.ink,
          onTap: () {
            setState(() => _dragLock = !_dragLock);
            if (_dragLock) {
              remote.mouseDown('left');
            } else {
              remote.mouseUp('left');
            }
            if (remote.haptics) HapticFeedback.mediumImpact();
          },
        ),
      ],
    );
  }
}

class _MouseKey extends StatefulWidget {
  const _MouseKey({
    required this.label,
    required this.sub,
    required this.icon,
    required this.held,
    required this.haptics,
    required this.onClick,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final String label;
  final String sub;
  final IconData icon;
  final bool held;
  final bool haptics;
  final VoidCallback onClick;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  State<_MouseKey> createState() => _MouseKeyState();
}

class _MouseKeyState extends State<_MouseKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.held || _down;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          if (widget.haptics) HapticFeedback.selectionClick();
          setState(() => _down = true);
        },
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onClick,
        onLongPressStart: (_) {
          if (widget.haptics) HapticFeedback.mediumImpact();
          widget.onHoldStart();
        },
        onLongPressEnd: (_) {
          setState(() => _down = false);
          widget.onHoldEnd();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: 58,
          decoration: BoxDecoration(
            color: active ? C.accent : C.surfaceHi,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: active ? C.accent : C.line),
            boxShadow: active
                ? [BoxShadow(color: C.accent.withValues(alpha: 0.3), blurRadius: 14)]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 19, color: active ? C.bg : C.ink),
              const SizedBox(height: 2),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: active ? C.bg : C.ink,
                ),
              ),
              Text(
                widget.sub,
                style: TextStyle(fontSize: 9.5, color: active ? C.bg : C.faint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 触控板本体。
///
/// 单指拖动 → 相对位移；双指上下 → 滚轮；轻点 → 左键。
/// 位移不做任何平滑，直接乘速度倍率交给 Remote 攒批（30Hz 发一次）。
class _Trackpad extends StatefulWidget {
  const _Trackpad({
    required this.haptics,
    required this.onMove,
    required this.onClick,
    required this.onWheel,
  });

  final bool haptics;
  final void Function(double dx, double dy) onMove;
  final void Function(String button) onClick;
  final void Function(int n) onWheel;

  @override
  State<_Trackpad> createState() => _TrackpadState();
}

class _TrackpadState extends State<_Trackpad> {
  final Map<int, Offset> _pointers = {};
  Offset? _lastPos;
  bool _multi = false;
  DateTime? _downAt;
  Offset _downPos = Offset.zero;
  double _wheelAcc = 0;

  @override
  Widget build(BuildContext context) {
    final active = _pointers.isNotEmpty;

    return Listener(
      key: const ValueKey('trackpad'),
      onPointerDown: (e) {
        _pointers[e.pointer] = e.localPosition;
        if (widget.haptics) HapticFeedback.selectionClick();
        if (_pointers.length == 1) {
          _downAt = DateTime.now();
          _downPos = e.localPosition;
          _multi = false;
        } else {
          _multi = true; // 第二根手指进来 = 滚动模式，别再动指针
        }
        setState(() => _lastPos = e.localPosition);
      },
      onPointerMove: (e) {
        _pointers[e.pointer] = e.localPosition;
        if (_pointers.length >= 2) {
          // 双指滚动：只取一根手指的位移，滚轮一格约 3
          _wheelAcc += e.delta.dy;
          if (_wheelAcc.abs() >= 18) {
            final steps = (_wheelAcc / 18).truncate();
            widget.onWheel(_wheelAcc > 0 ? -steps.abs() : steps.abs());
            _wheelAcc = 0;
          }
        } else {
          widget.onMove(e.delta.dx, e.delta.dy);
        }
        setState(() => _lastPos = e.localPosition);
      },
      onPointerUp: (e) {
        _pointers.remove(e.pointer);
        if (_pointers.isEmpty) {
          final dt = _downAt == null
              ? const Duration(seconds: 1)
              : DateTime.now().difference(_downAt!);
          final moved = (e.localPosition - _downPos).distance;
          if (!_multi && dt.inMilliseconds < 300 && moved < 12) {
            widget.onClick('left');
            if (widget.haptics) HapticFeedback.mediumImpact();
          }
          _multi = false;
          _wheelAcc = 0;
          setState(() => _lastPos = null);
        }
      },
      onPointerCancel: (e) {
        _pointers.remove(e.pointer);
        if (_pointers.isEmpty) setState(() => _lastPos = null);
      },
      child: Container(
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: active ? C.accent.withValues(alpha: 0.55) : C.line),
        ),
        child: Stack(
          children: [
            // 背景网格，看起来像触控板
            Positioned.fill(
              child: CustomPaint(painter: _GridPainter()),
            ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.touch_app_outlined,
                      size: 26, color: active ? C.accent.withValues(alpha: 0.7) : C.faint),
                  const SizedBox(height: 8),
                  Text(
                    '单指移动 · 双指滚动 · 轻点左键',
                    style: TextStyle(
                      fontSize: 12,
                      color: active ? C.soft : C.faint,
                    ),
                  ),
                ],
              ),
            ),
            if (_lastPos != null)
              Positioned(
                left: _lastPos!.dx - 16,
                top: _lastPos!.dy - 16,
                child: IgnorePointer(
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: C.accent.withValues(alpha: 0.18),
                      border: Border.all(color: C.accent.withValues(alpha: 0.6)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = C.line.withValues(alpha: 0.35)
      ..strokeWidth = 0.6;
    const step = 26.0;
    for (var x = step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
