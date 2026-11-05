// 通用小部件：卡片、状态胶囊、键帽、迷你按钮。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// 圆角卡片
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.margin = EdgeInsets.zero,
  });

  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: C.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Text(title!,
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: C.soft,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                      )),
                  const Spacer(),
                  ?trailing,
                ],
              ),
            ),
          child,
        ],
      ),
    );
  }
}

/// 连接状态胶囊：圆点 + 文字（+ 延迟）
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.text,
    required this.color,
    this.trailing,
    this.onTap,
  });

  final String text;
  final Color color;
  final String? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: C.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6)],
              ),
            ),
            const SizedBox(width: 7),
            // 用 Flexible 而不是固定宽度：窄屏（或标题很长）时让它自己收缩，
            // 否则 Row 会溢出
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: C.ink, fontWeight: FontWeight.w500),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 6),
              Text(trailing!, style: const TextStyle(fontSize: 11.5, color: C.soft)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 键帽。用 onTapDown 触发（不等抬手），按下去的手感才对得上。
class KeyButton extends StatefulWidget {
  const KeyButton({
    super.key,
    required this.label,
    required this.flex,
    required this.onTap,
    this.onLongPress,
    this.active = false,
    this.locked = false,
    this.flash = false,
    this.haptics = true,
    this.fontSize = 15,
  });

  final String label;
  final double flex;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool active;
  final bool locked;
  final bool flash;
  final bool haptics;
  final double fontSize;

  @override
  State<KeyButton> createState() => _KeyButtonState();
}

class _KeyButtonState extends State<KeyButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final emphasized = widget.active || widget.locked;

    final Color bg;
    if (widget.locked) {
      bg = C.accent2;
    } else if (widget.active) {
      bg = C.accent;
    } else if (_down) {
      bg = C.surfaceMax;
    } else {
      bg = C.surfaceHi;
    }

    final fg = emphasized ? C.bg : C.ink;

    return Expanded(
      flex: (widget.flex * 10).round(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) {
          if (widget.haptics) HapticFeedback.selectionClick();
          setState(() => _down = true);
          widget.onTap();
        },
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onLongPress: widget.onLongPress == null
            ? null
            : () {
                if (widget.haptics) HapticFeedback.mediumImpact();
                widget.onLongPress!();
              },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          height: double.infinity,
          margin: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: emphasized ? bg : (widget.flash ? C.accent.withValues(alpha: 0.7) : C.line),
              width: widget.locked ? 2 : 1,
            ),
            boxShadow: emphasized
                ? [BoxShadow(color: bg.withValues(alpha: 0.35), blurRadius: 12, spreadRadius: 1)]
                : null,
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                widget.label,
                maxLines: 1,
                style: TextStyle(
                  color: fg,
                  fontSize: widget.fontSize,
                  fontWeight: emphasized ? FontWeight.w700 : FontWeight.w500,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 小按钮（次要操作）
class TinyButton extends StatelessWidget {
  const TinyButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.tone = C.surfaceHi,
    this.foreground = C.ink,
    this.enabled = true,
    this.expand = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final Color tone;
  final Color foreground;
  final bool enabled;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final child = Material(
      color: enabled ? tone : C.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: enabled ? foreground : C.faint),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: enabled ? foreground : C.faint,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: child) : child;
  }
}

/// 分页选择条（键盘的分页、快捷键的 Windows/macOS 切换都用它）
class SegmentBar<T> extends StatelessWidget {
  const SegmentBar({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });

  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: C.line),
      ),
      child: Row(
        children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(values[i]),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: values[i] == selected ? C.surfaceMax : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 12.5,
                      color: values[i] == selected ? C.ink : C.soft,
                      fontWeight: values[i] == selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 小标签
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color = C.soft});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(text, style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
