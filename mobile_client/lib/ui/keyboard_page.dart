// 屏幕键盘：分页键位 + 粘滞修饰键 + 文本输入。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/protocol.dart';
import '../core/remote.dart';
import '../core/scope.dart';
import 'connect_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

class KeyboardPage extends StatefulWidget {
  const KeyboardPage({super.key});

  @override
  State<KeyboardPage> createState() => _KeyboardPageState();
}

class _KeyboardPageState extends State<KeyboardPage> {
  int _tab = 0;

  static const _labels = ['字母', '符号', '编辑', '功能', '数字'];
  static const _layouts = <List<List<KeyCap>>>[
    Layout.alpha,
    Layout.symbols,
    Layout.nav,
    Layout.fn,
    Layout.numpad,
  ];

  @override
  Widget build(BuildContext context) {
    final remote = RemoteScope.of(context);
    final mods = remote.activeModifiers;

    return LayoutBuilder(
      builder: (context, cons) {
        // 横屏 / 矮屏：把空间全留给键位，连接卡和说明行先收起来
        final compact = cons.maxHeight < 460;
        // 横屏还要换一套「宽排布」：竖屏 6 行在横屏里行高只剩 20 多 pt
        final wide = compact && cons.maxWidth > cons.maxHeight;
        final rows = wide && _tab == 0 ? Layout.alphaWide : _layouts[_tab];

        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
          child: Column(
            children: [
              SegmentBar<int>(
                values: const [0, 1, 2, 3, 4],
                labels: _labels,
                selected: _tab,
                onChanged: (v) => setState(() => _tab = v),
              ),
              const SizedBox(height: 8),
              if (!compact) ...[
                _connectionCard(remote),
                const SizedBox(height: 8),
              ],
              Expanded(child: _grid(rows, remote, compact: compact)),
              if (mods.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _stickyHint(remote),
                ),
              const SizedBox(height: 6),
              _modifierBar(remote, compact: compact),
              if (!compact) ...[
                const SizedBox(height: 8),
                _textBar(remote),
                const SizedBox(height: 4),
                const Text(
                  '⇧ Shift　⌃ Ctrl　⌥ Alt　⊞ Win/⌘　· 修饰键点一下=用一次，长按=锁定',
                  style: TextStyle(fontSize: 10, color: C.faint),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// 键位上方的连接卡：没连上时是「去连接」的入口，连上后变成主机状态一览。
  Widget _connectionCard(Remote remote) {
    if (!remote.connected) {
      return Material(
        color: C.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => showConnectSheet(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: C.line),
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: const BoxDecoration(
                    color: C.accentDim,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.bluetooth_searching, size: 17, color: C.accent),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('还没有连接设备',
                          style: TextStyle(
                              fontSize: 13, color: C.ink, fontWeight: FontWeight.w600)),
                      SizedBox(height: 2),
                      Text('点这里扫描 ESP32-Keyboard（板子指示灯应为蓝色）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: C.soft)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 18, color: C.faint),
              ],
            ),
          ),
        ),
      );
    }

    final mode = remote.kind == LinkKind.ble ? '蓝牙' : 'Wi-Fi';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.line),
      ),
      child: Row(
        children: [
          const Icon(Icons.link, size: 15, color: C.ok),
          const SizedBox(width: 6),
          Text('$mode 链路正常',
              style: const TextStyle(fontSize: 12.5, color: C.ink)),
          const SizedBox(width: 8),
          if (remote.rtt != null)
            Tag('${remote.rtt}ms', color: remote.rtt! < 60 ? C.ok : C.warn),
          const Spacer(),
          if ((remote.leds & 2) != 0) ...[
            const Tag('CAPS', color: C.warn),
            const SizedBox(width: 4),
          ],
          if ((remote.leds & 1) != 0) ...[
            const Tag('NUM', color: C.accent),
            const SizedBox(width: 4),
          ],
          if (remote.bootKey != null)
            Tag('引导键 ${remote.bootKey == 'off' ? '关' : remote.bootKey!.toUpperCase()}',
                color: C.accent2),
        ],
      ),
    );
  }

  Widget _grid(List<List<KeyCap>> rows, Remote remote, {bool compact = false}) {
    return LayoutBuilder(
      builder: (context, cons) {
        const gap = 4.0;
        final maxRowH = compact ? 64.0 : (_tab == 0 ? 62.0 : 70.0);
        final height = math.min(cons.maxHeight, rows.length * maxRowH + (rows.length - 1) * gap);
        final keyWidth = cons.maxWidth / 11;
        final fontSize = (keyWidth * 0.4).clamp(11.0, 16.0);

        return Center(
          child: SizedBox(
            height: height,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const SizedBox(height: gap),
                  Expanded(
                    child: Row(
                      children: [
                        for (final cap in rows[i])
                          KeyButton(
                            label: cap.label,
                            flex: cap.flex,
                            fontSize: fontSize,
                            active: remote.isSticky(cap.token),
                            locked: remote.isLocked(cap.token),
                            flash: remote.flashing.contains(cap.token),
                            haptics: remote.haptics,
                            onTap: () => remote.tapKey(cap),
                            onLongPress:
                                cap.modifier ? () => remote.lockSticky(cap.token) : null,
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _stickyHint(Remote remote) {
    final locked = remote.stickyLocked;
    final text = locked.isEmpty
        ? '修饰键已按下，下一个键生效'
        : '已锁定：${locked.map((t) => _name(t)).join(' + ')}（再点一下解锁）';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(locked.isEmpty ? Icons.touch_app_outlined : Icons.lock_outline,
            size: 13, color: locked.isEmpty ? C.accent : C.accent2),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: locked.isEmpty ? C.accent : C.accent2,
            ),
          ),
        ),
      ],
    );
  }

  String _name(String token) => switch (token) {
        'shift' => 'Shift',
        'ctrl' => 'Ctrl',
        'alt' => 'Alt',
        'cmd' => 'Win',
        _ => token,
      };

  Widget _modifierBar(Remote remote, {bool compact = false}) {
    final any = remote.activeModifiers.isNotEmpty;
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          for (final cap in Layout.modifiers)
            KeyButton(
              label: cap.label,
              flex: 1,
              fontSize: 16,
              active: remote.isSticky(cap.token),
              locked: remote.isLocked(cap.token),
              haptics: remote.haptics,
              onTap: () => remote.toggleSticky(cap.token),
              onLongPress: () => remote.lockSticky(cap.token),
            ),
          if (any)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: TinyButton(
                label: '清除',
                icon: Icons.close,
                onTap: remote.clearSticky,
              ),
            ),
          if (compact)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: TinyButton(
                label: '输入',
                icon: Icons.keyboard_alt_outlined,
                onTap: () => _showTypeSheet(context, remote),
              ),
            ),
        ],
      ),
    );
  }

  Widget _textBar(Remote remote) {
    return Row(
      children: [
        Expanded(
          child: TinyButton(
            label: '输入文本（用手机键盘打字发给电脑）',
            icon: Icons.keyboard_alt_outlined,
            expand: true,
            tone: C.surfaceHi,
            onTap: () => _showTypeSheet(context, remote),
          ),
        ),
        const SizedBox(width: 8),
        TinyButton(
          label: '粘贴',
          icon: Icons.content_paste_go,
          onTap: () async {
            if (!remote.connected) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('还没连接设备，先在右上角连接')),
              );
              return;
            }
            final data = await Clipboard.getData(Clipboard.kTextPlain);
            if (!mounted) return;
            final text = data?.text;
            if (text == null || text.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('剪贴板是空的')),
              );
              return;
            }
            remote.sendText(text);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已发送 ${text.length} 个字符')),
            );
          },
        ),
      ],
    );
  }

  Future<void> _showTypeSheet(BuildContext context, Remote remote) async {
    final controller = TextEditingController();
    var enterAtEnd = false;
    var warning = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (ctx, setSheetState) {
            void send() {
              if (!remote.connected) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('还没连接设备，先在右上角连接')),
                );
                return;
              }
              final raw = controller.text;
              if (raw.isEmpty) return;
              remote.sendText(enterAtEnd ? '$raw\n' : raw);
              Navigator.of(ctx).pop();
            }

            return Container(
              decoration: const BoxDecoration(
                color: C.bg,
                borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                border: Border(top: BorderSide(color: C.line)),
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('输入文本',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600, color: C.ink)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('取消', style: TextStyle(color: C.soft)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: 1,
                    maxLines: 4,
                    onChanged: (v) => setSheetState(() => warning = !Cmd.isTypeable(v)),
                    style: const TextStyle(fontSize: 15, color: C.ink),
                    decoration: InputDecoration(
                      hintText: '要发到被控电脑的文字…',
                      hintStyle: const TextStyle(color: C.faint, fontSize: 14),
                      filled: true,
                      fillColor: C.surface,
                      contentPadding: const EdgeInsets.all(12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: C.line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: C.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: C.accent),
                      ),
                    ),
                  ),
                  if (warning)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        '含中文/emoji：固件是逐个键码敲的，非 ASCII 字符会被跳过。\n'
                        '要在电脑上打中文，请在电脑上切好输入法。',
                        style: TextStyle(fontSize: 11.5, color: C.warn, height: 1.5),
                      ),
                    ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Switch(
                        value: enterAtEnd,
                        onChanged: (v) => setSheetState(() => enterAtEnd = v),
                      ),
                      const Text('发送后按回车',
                          style: TextStyle(fontSize: 12.5, color: C.soft)),
                      const Spacer(),
                      TinyButton(
                        label: '发送',
                        icon: Icons.send,
                        tone: C.accent,
                        foreground: C.bg,
                        onTap: send,
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
