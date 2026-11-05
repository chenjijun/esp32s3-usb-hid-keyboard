// 主框架：顶部状态条 + 四个页面 + 底部导航。

import 'package:flutter/material.dart';

import '../core/remote.dart';
import '../core/scope.dart';
import '../debug_flags.dart';
import 'connect_sheet.dart';
import 'keyboard_page.dart';
import 'keys_page.dart';
import 'mouse_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _index = kStartTab.clamp(0, 3);
  Remote? _remote;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kOpenConnectSheet) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showConnectSheet(context);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 生命周期回调里不能再去 dependOnInheritedWidget，先缓存一份
    _remote = RemoteScope.of(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切后台/锁屏时把鼠标键松开：不然「按住左键」状态会让主机一直以为在拖拽
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _remote?.releaseMouseButtons();
    }
  }

  static const _pages = [
    KeyboardPage(),
    MousePage(),
    KeysPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final remote = RemoteScope.of(context);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(remote: remote),
            Expanded(
              child: IndexedStack(index: _index, children: _pages),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomNav(
        index: _index,
        onChanged: (i) => setState(() => _index = i),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.remote});

  final Remote remote;

  @override
  Widget build(BuildContext context) {
    final color = switch (remote.phase) {
      Phase.connected => C.ok,
      Phase.connecting || Phase.scanning => C.warn,
      Phase.idle => remote.lastError != null ? C.danger : C.faint,
    };

    final text = switch (remote.phase) {
      Phase.connected => remote.statusLine.replaceFirst('已连接 · ', ''),
      Phase.connecting => '连接中…',
      Phase.scanning => '扫描中…',
      Phase.idle => remote.lastError != null ? '连接失败' : '未连接',
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 4),
      child: Row(
        children: [
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: StatusPill(
                text: text,
                color: color,
                trailing: remote.connected && remote.rtt != null ? '${remote.rtt}ms' : null,
                onTap: () => showConnectSheet(context),
              ),
            ),
          ),
          if (remote.connected && (remote.leds & 2) != 0) ...[
            const SizedBox(width: 6),
            const Tag('CAPS', color: C.warn),
          ],
          if (remote.connected && (remote.leds & 1) != 0) ...[
            const SizedBox(width: 6),
            const Tag('NUM', color: C.accent),
          ],
          const Spacer(),
          IconButton(
            tooltip: remote.connected ? '连接管理' : '连接设备',
            onPressed: () => showConnectSheet(context),
            icon: Icon(
              remote.connected ? Icons.bluetooth_connected : Icons.bluetooth_searching,
              color: remote.connected ? C.ok : C.soft,
              size: 21,
            ),
          ),
          IconButton(
            tooltip: '松开所有按键',
            onPressed: remote.connected ? remote.releaseAll : null,
            icon: Icon(
              Icons.pan_tool_alt_outlined,
              size: 20,
              color: remote.connected ? C.soft : C.faint,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.index, required this.onChanged});

  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: C.bg,
        border: Border(top: BorderSide(color: C.line, width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              _item(0, Icons.keyboard_outlined, Icons.keyboard, '键盘'),
              _item(1, Icons.mouse_outlined, Icons.mouse, '鼠标'),
              _item(2, Icons.bolt_outlined, Icons.bolt, '快捷键'),
              _item(3, Icons.tune_outlined, Icons.tune, '设置'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _item(int i, IconData icon, IconData activeIcon, String label) {
    final active = i == index;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(i),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(active ? activeIcon : icon, size: 21, color: active ? C.accent : C.faint),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                color: active ? C.accent : C.faint,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
