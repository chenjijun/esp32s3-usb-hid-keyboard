// 设置页：连接信息、操作习惯、运行日志、关于。

import 'package:flutter/material.dart';

import '../core/protocol.dart';
import '../core/remote.dart';
import '../core/scope.dart';
import '../version.dart';
import 'connect_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  TextEditingController? _nameCtl;
  bool _loaded = false;

  TextEditingController get _name => _nameCtl!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _nameCtl = TextEditingController(text: RemoteScope.of(context).deviceName);
    }
  }

  @override
  void dispose() {
    _nameCtl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = RemoteScope.of(context);

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      children: [
        Panel(
          title: '连接',
          trailing: Tag(remote.connected ? '已连接' : '未连接',
              color: remote.connected ? C.ok : C.faint),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _kv('链路', remote.kind == LinkKind.ble ? '蓝牙 BLE' : 'Wi-Fi TCP'),
              _kv('状态', remote.statusLine),
              if (remote.kind == LinkKind.wifi)
                _kv('地址', '${remote.wifiHost}:${remote.wifiPort}'),
              if (remote.lastName != null && remote.lastName!.isNotEmpty)
                _kv('上次设备', remote.lastName!),
              if (remote.rtt != null) _kv('延迟', '${remote.rtt} ms'),
              const SizedBox(height: 10),
              TinyButton(
                label: remote.connected ? '连接管理' : '连接设备',
                icon: Icons.link,
                expand: true,
                tone: C.accent,
                foreground: C.bg,
                onTap: () => showConnectSheet(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Panel(
          title: '目标设备名',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autocorrect: false,
                onSubmitted: remote.setDeviceName,
                style: const TextStyle(fontSize: 14, color: C.ink, fontFamily: 'monospace'),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: LinkInfo.defaultName,
                  hintStyle: const TextStyle(color: C.faint, fontFamily: 'monospace'),
                  filled: true,
                  fillColor: C.surfaceHi,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: C.line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: C.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: C.accent),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '扫描时用它来高亮目标设备。板子广播的名字由固件里的 DEVICE_NAME 决定，'
                '要改名字得重新烧固件。',
                style: TextStyle(fontSize: 10.5, color: C.faint, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Panel(
          child: Row(
            children: [
              const Icon(Icons.vibration, size: 18, color: C.soft),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('触感反馈', style: TextStyle(fontSize: 13.5, color: C.ink)),
                    SizedBox(height: 2),
                    Text('按键时轻轻震一下，盲按不容易点错',
                        style: TextStyle(fontSize: 10.5, color: C.faint)),
                  ],
                ),
              ),
              Switch(value: remote.haptics, onChanged: remote.setHaptics),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Panel(
          title: '运行日志',
          trailing: TinyButton(label: '清空', onTap: remote.clearLog),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: SizedBox(
            height: 148,
            child: remote.log.isEmpty
                ? const Center(
                    child: Text('还没有记录', style: TextStyle(fontSize: 12, color: C.faint)),
                  )
                : ListView.separated(
                    reverse: true,
                    itemCount: remote.log.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 5),
                    itemBuilder: (context, i) {
                      final item = remote.log[remote.log.length - 1 - i];
                      final t = item.at;
                      final clock = '${t.hour.toString().padLeft(2, '0')}:'
                          '${t.minute.toString().padLeft(2, '0')}:'
                          '${t.second.toString().padLeft(2, '0')}';
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(clock,
                              style: const TextStyle(
                                  fontSize: 10, color: C.faint, fontFamily: 'monospace')),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item.text,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.35,
                                color: item.isError ? C.danger : C.soft,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Panel(
          title: '关于',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('版本', style: TextStyle(fontSize: 12.5, color: C.soft)),
                  const Spacer(),
                  Text(kAppVersion,
                      style: const TextStyle(
                          fontSize: 12.5, color: C.ink, fontFamily: 'monospace')),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '手机端是「遥控器」。iOS / 安卓都不允许普通 App 抓本机键盘，'
                '所以这里用屏幕键盘 + 文本框把按键发到被控电脑，'
                '和在电脑上装驱动的那类工具不是一回事。',
                style: TextStyle(fontSize: 11.5, color: C.soft, height: 1.55),
              ),
              const SizedBox(height: 10),
              const Text('协议（与电脑端完全一致）',
                  style: TextStyle(fontSize: 11, color: C.faint)),
              const SizedBox(height: 4),
              Text(
                'BLE 服务 ${LinkInfo.service}\n'
                '写 ${LinkInfo.rx}　通知 ${LinkInfo.tx}\n'
                'Wi-Fi TCP ${LinkInfo.defaultHost}:${LinkInfo.defaultPort}',
                style: const TextStyle(
                    fontSize: 10, color: C.faint, fontFamily: 'monospace', height: 1.6),
              ),
              const SizedBox(height: 10),
              const Text('github.com/chenjijun/esp32s3-usb-hid-keyboard',
                  style: TextStyle(fontSize: 10.5, color: C.accent, fontFamily: 'monospace')),
              const SizedBox(height: 2),
              const Text('MIT License',
                  style: TextStyle(fontSize: 10.5, color: C.faint)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(k, style: const TextStyle(fontSize: 12.5, color: C.soft)),
          ),
          Expanded(
            child: Text(v,
                style: const TextStyle(fontSize: 12.5, color: C.ink, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
