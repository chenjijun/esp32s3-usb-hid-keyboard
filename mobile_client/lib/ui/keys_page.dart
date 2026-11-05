// 快捷键页：常用组合键（Windows / macOS 两套）+ BIOS 开机引导键。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/protocol.dart';
import '../core/remote.dart';
import '../core/scope.dart';
import 'theme.dart';
import 'widgets.dart';

class KeysPage extends StatefulWidget {
  const KeysPage({super.key});

  @override
  State<KeysPage> createState() => _KeysPageState();
}

class _KeysPageState extends State<KeysPage> {
  String _biosSel = 'delete';

  @override
  Widget build(BuildContext context) {
    final remote = RemoteScope.of(context);
    final isWin = remote.presetOs == 'windows';
    final presets = isWin ? Layout.winPresets : Layout.macPresets;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Column(
        children: [
          SegmentBar<String>(
            values: const ['windows', 'mac'],
            labels: const ['被控电脑：Windows', '被控电脑：macOS'],
            selected: remote.presetOs,
            onChanged: remote.setPresetOs,
          ),
          const SizedBox(height: 10),
          Expanded(
            child: GridView.builder(
              padding: EdgeInsets.zero,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                mainAxisExtent: 60,
              ),
              itemCount: presets.length,
              itemBuilder: (context, i) => _presetTile(remote, presets[i], isWin),
            ),
          ),
          const SizedBox(height: 10),
          _biosPanel(remote),
        ],
      ),
    );
  }

  Widget _presetTile(Remote remote, Preset p, bool isWin) {
    return Material(
      color: C.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (remote.haptics) HapticFeedback.selectionClick();
          remote.sendPreset(p.keys);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                p.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, color: C.ink, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 3),
              Text(
                _comboText(p.keys, isWin),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10.5, color: C.faint, fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _comboText(List<String> keys, bool isWin) {
    String one(String t) => switch (t) {
          'ctrl' => 'Ctrl',
          'shift' => 'Shift',
          'alt' => 'Alt',
          'cmd' || 'win' => isWin ? 'Win' : '⌘',
          'space' => 'Space',
          'esc' => 'Esc',
          'enter' => 'Enter',
          'delete' => 'Del',
          'tab' => 'Tab',
          _ => t.length == 1 ? t.toUpperCase() : t,
        };
    return keys.map(one).join(' + ');
  }

  Widget _biosPanel(Remote remote) {
    return Panel(
      title: 'BIOS 开机引导键（板子上电自己连发，不依赖手机）',
      trailing: remote.bootKey != null
          ? Tag('固件：${remote.bootKey == 'off' ? '已关闭' : remote.bootKey!.toUpperCase()}',
              color: C.ok)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final k in Layout.biosKeys)
                GestureDetector(
                  onTap: () => setState(() => _biosSel = k.token),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: _biosSel == k.token ? C.accent : C.surfaceHi,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: _biosSel == k.token ? C.accent : C.line,
                      ),
                    ),
                    child: Text(
                      k.label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: _biosSel == k.token ? C.bg : C.ink,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TinyButton(
                  label: '写入板子',
                  icon: Icons.save_outlined,
                  expand: true,
                  tone: C.accent,
                  foreground: C.bg,
                  enabled: remote.connected,
                  onTap: () => remote.setBootKey(_biosSel),
                ),
              ),
              const SizedBox(width: 6),
              TinyButton(
                label: '立即连发',
                icon: Icons.bolt,
                enabled: remote.connected,
                onTap: remote.replayBootKey,
              ),
              const SizedBox(width: 6),
              TinyButton(
                label: '查询',
                icon: Icons.refresh,
                enabled: remote.connected,
                onTap: remote.queryBootKey,
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '写进去的值掉电不丢；下次板子上电后会连发约 8 秒，够进 BIOS。\n'
            '台式机常见 Del / F2，笔记本常见 F2 / F10 / F12。',
            style: TextStyle(fontSize: 10.5, color: C.faint, height: 1.5),
          ),
        ],
      ),
    );
  }
}
