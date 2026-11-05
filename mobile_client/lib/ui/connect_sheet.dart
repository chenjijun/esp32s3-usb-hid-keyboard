// 连接面板：蓝牙（扫描列表）与 Wi-Fi（填地址）两种链路。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../core/protocol.dart';
import '../core/remote.dart';
import '../core/scope.dart';
import 'theme.dart';
import 'widgets.dart';

Future<void> showConnectSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ConnectSheet(),
  );
}

class _ConnectSheet extends StatefulWidget {
  const _ConnectSheet();

  @override
  State<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<_ConnectSheet> {
  TextEditingController? _hostCtl;
  TextEditingController? _portCtl;
  bool _autoScanned = false;
  bool _inited = false;

  TextEditingController get _host => _hostCtl!;
  TextEditingController get _port => _portCtl!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inited) return;
    _inited = true;

    final remote = RemoteScope.of(context);
    _hostCtl = TextEditingController(text: remote.wifiHost);
    _portCtl = TextEditingController(text: remote.wifiPort.toString());

    if (!_autoScanned && remote.kind == LinkKind.ble && !remote.connected) {
      _autoScanned = true;
      // 打开面板就顺手扫一轮，省得用户再点一次
      if (remote.adapterState == BluetoothAdapterState.on) {
        WidgetsBinding.instance.addPostFrameCallback((_) => remote.startScan());
      }
    }
  }

  @override
  void dispose() {
    _hostCtl?.dispose();
    _portCtl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = RemoteScope.of(context);
    final media = MediaQuery.of(context);
    final maxHeight = media.size.height * 0.86 - media.viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: const BoxDecoration(
          color: C.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
          border: Border(top: BorderSide(color: C.line)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: C.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Text('连接设备',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: C.ink)),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20, color: C.soft),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentBar<LinkKind>(
                values: const [LinkKind.ble, LinkKind.wifi],
                labels: const ['蓝牙 BLE', 'Wi-Fi'],
                selected: remote.kind,
                onChanged: (k) {
                  remote.setKind(k);
                  if (k == LinkKind.ble && !remote.connected) remote.startScan();
                },
              ),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: remote.kind == LinkKind.ble
                  ? _bleList(remote)
                  : _wifiForm(remote),
            ),
            if (remote.connected)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                child: TinyButton(
                  label: '断开连接',
                  icon: Icons.link_off,
                  expand: true,
                  tone: C.surface,
                  foreground: C.danger,
                  onTap: () {
                    remote.disconnect();
                    Navigator.of(context).pop();
                  },
                ),
              ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // 蓝牙
  // -------------------------------------------------------------------------
  Widget _bleList(Remote remote) {
    final scanning = remote.phase == Phase.scanning;
    final connecting = remote.phase == Phase.connecting;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      children: [
        Row(
          children: [
            Icon(
              remote.canScan ? Icons.bluetooth : Icons.bluetooth_disabled,
              size: 16,
              color: remote.canScan ? C.ok : C.danger,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                remote.canScan
                    ? (scanning ? '正在扫描…（板子指示灯应为蓝色）' : '蓝牙已就绪')
                    : '蓝牙不可用：请打开系统蓝牙，并允许本 App 使用蓝牙',
                style: TextStyle(
                  fontSize: 12,
                  color: remote.canScan ? C.soft : C.danger,
                ),
              ),
            ),
            if (scanning)
              TextButton(
                onPressed: remote.stopScan,
                child: const Text('停止', style: TextStyle(fontSize: 12)),
              )
            else
              TextButton(
                onPressed: remote.canScan && !connecting ? remote.startScan : null,
                child: const Text('扫描', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        if (remote.connected) ...[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: C.accentDim,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: C.accent.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.bluetooth_connected, size: 18, color: C.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(remote.statusLine,
                      style: const TextStyle(fontSize: 13, color: C.ink)),
                ),
                Text(remote.rtt != null ? '${remote.rtt}ms' : '',
                    style: const TextStyle(fontSize: 12, color: C.soft)),
              ],
            ),
          ),
        ],
        if (!remote.connected && remote.lastRemoteId != null) ...[
          const SizedBox(height: 10),
          TinyButton(
            label: '重连上次设备${remote.lastName != null && remote.lastName!.isNotEmpty ? "（${remote.lastName}）" : ""}',
            icon: Icons.history,
            expand: true,
            onTap: connecting ? () {} : remote.connectLastBle,
          ),
        ],
        const SizedBox(height: 10),
        if (remote.scans.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 26),
            child: Column(
              children: [
                Icon(scanning ? Icons.bluetooth_searching : Icons.wifi_tethering_off,
                    size: 34, color: C.faint),
                const SizedBox(height: 10),
                Text(
                  scanning ? '正在找 ESP32-Keyboard…' : '点右上「扫描」开始查找',
                  style: const TextStyle(fontSize: 13, color: C.soft),
                ),
                const SizedBox(height: 6),
                const Text(
                  '板子上按 BOOT 切到蓝牙模式（指示灯蓝色）\n设备名可在「设置」里改',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: C.faint, height: 1.5),
                ),
              ],
            ),
          )
        else
          ...remote.scans.map((r) => _deviceRow(remote, r, connecting)),
      ],
    );
  }

  Widget _deviceRow(Remote remote, ScanResult r, bool busy) {
    final adv = r.advertisementData;
    final rawName = adv.advName.isNotEmpty ? adv.advName : r.device.platformName;
    final name = rawName.isEmpty ? '未命名设备' : rawName;
    final isTarget = name.toLowerCase().contains(remote.deviceName.toLowerCase());

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isTarget ? C.surfaceMax : C.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: busy ? null : () => remote.connectBle(r.device),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(
              children: [
                Icon(
                  isTarget ? Icons.keyboard_alt_outlined : Icons.bluetooth,
                  size: 19,
                  color: isTarget ? C.accent : C.soft,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 13.5, color: C.ink, fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (isTarget) ...[
                            const SizedBox(width: 6),
                            const Tag('目标', color: C.accent),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${r.device.remoteId.str} · ${r.rssi} dBm',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: C.faint),
                      ),
                    ],
                  ),
                ),
                if (busy)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: C.accent),
                  )
                else
                  const Icon(Icons.chevron_right, size: 18, color: C.faint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Wi-Fi
  // -------------------------------------------------------------------------
  Widget _wifiForm(Remote remote) {
    final connecting = remote.phase == Phase.connecting;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('先在手机系统设置里连上板子的热点',
                  style: TextStyle(fontSize: 12.5, color: C.ink, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Tag('热点', color: C.accent2),
                  const SizedBox(width: 6),
                  Text(LinkInfo.apSsid,
                      style: const TextStyle(fontSize: 12.5, color: C.ink, fontFamily: 'monospace')),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Tag('密码', color: C.accent2),
                  const SizedBox(width: 6),
                  Text(LinkInfo.apPassword,
                      style: const TextStyle(fontSize: 12.5, color: C.ink, fontFamily: 'monospace')),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'iOS 首次连接会问「是否允许访问本地网络」，必须允许；\n'
                '安卓连上热点后若提示「此 WLAN 无法访问互联网」，选择保持连接。',
                style: TextStyle(fontSize: 11, color: C.soft, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: _field(
                controller: _host,
                label: '主机地址',
                hint: LinkInfo.defaultHost,
                keyboard: TextInputType.url,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: _field(
                controller: _port,
                label: '端口',
                hint: LinkInfo.defaultPort.toString(),
                keyboard: TextInputType.number,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TinyButton(
                label: remote.connected ? '重新连接' : '连接',
                icon: Icons.link,
                expand: true,
                tone: C.accent,
                foreground: C.bg,
                enabled: !connecting,
                onTap: () {
                  final port = int.tryParse(_port.text.trim()) ?? LinkInfo.defaultPort;
                  remote.setWifi(_host.text, port);
                  remote.connectWifi();
                },
              ),
            ),
            const SizedBox(width: 8),
            TinyButton(
              label: '重置',
              icon: Icons.restart_alt,
              enabled: !connecting,
              onTap: () {
                _host.text = LinkInfo.defaultHost;
                _port.text = LinkInfo.defaultPort.toString();
              },
            ),
          ],
        ),
        if (connecting)
          const Padding(
            padding: EdgeInsets.only(top: 14),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: C.accent),
              ),
            ),
          ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required TextInputType keyboard,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: C.soft)),
        const SizedBox(height: 5),
        TextField(
          controller: controller,
          keyboardType: keyboard,
          autocorrect: false,
          style: const TextStyle(fontSize: 13.5, color: C.ink, fontFamily: 'monospace'),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: const TextStyle(fontSize: 13, color: C.faint),
            filled: true,
            fillColor: C.surfaceHi,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
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
      ],
    );
  }
}
