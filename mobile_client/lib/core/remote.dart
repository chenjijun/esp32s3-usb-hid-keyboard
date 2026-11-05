// 应用状态：链路、扫描、粘滞修饰键、鼠标位移攒批、固件回执、设置持久化。
//
// 界面只读这里的字段、只调这里的方法；这里不引用任何 Widget。
// 这样界面能做得很薄，逻辑也能用纯 Dart 单测覆盖。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';
import 'transport.dart';

enum LinkKind { ble, wifi }

enum Phase { idle, scanning, connecting, connected }

class LogItem {
  LogItem(this.text, {this.isError = false}) : at = DateTime.now();
  final DateTime at;
  final String text;
  final bool isError;
}

class Remote extends ChangeNotifier {
  // 设置项（会存盘）
  LinkKind kind = LinkKind.ble;
  String deviceName = LinkInfo.defaultName;
  String wifiHost = LinkInfo.defaultHost;
  int wifiPort = LinkInfo.defaultPort;

  /// 触控板位移倍率：手指 1px → 主机多少 px
  double mouseSpeed = 1.6;
  bool haptics = true;

  /// 快捷键预设按哪套系统显示：windows / mac
  String presetOs = 'windows';

  /// 上次连上的 BLE 设备（下次可一键重连）
  String? lastRemoteId;
  String? lastName;

  // 运行状态
  Phase phase = Phase.idle;
  String statusLine = '未连接';
  String? lastError;
  BluetoothAdapterState adapterState = BluetoothAdapterState.unknown;
  List<ScanResult> scans = const [];

  /// 固件当前的 BIOS 引导键；null 表示还没查询到
  String? bootKey;
  /// 最近一次 PING 的往返耗时（毫秒）
  int? rtt;
  /// 主机 LED 位图：bit0 NumLock、bit1 CapsLock、bit2 ScrollLock
  int leds = 0;

  /// 粘滞修饰键（一次性：发完一个键就松开）
  final Set<String> stickyOneShot = {};
  /// 锁定住的修饰键（一直按着，直到再点一下）
  final Set<String> stickyLocked = {};
  /// 刚按过的键，用来闪一下
  final Set<String> flashing = {};
  /// 界面上「按着」的鼠标键
  final Set<String> mouseHeld = {};

  final List<LogItem> log = [];

  Transport? _transport;
  StreamSubscription<String>? _incomingSub;
  StreamSubscription<Object>? _dropSub;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _scanningSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _drainTimer;
  Timer? _heartbeat;
  Timer? _flashTimer;
  int? _pingSentAt;
  double _pendingX = 0;
  double _pendingY = 0;
  bool _disposed = false;
  SharedPreferences? _prefs;

  bool get connected => phase == Phase.connected;
  bool get canScan => adapterState == BluetoothAdapterState.on;

  /// 当前生效的修饰键，按固定顺序排（先按的 ctrl 再按 shift，主机看到的顺序才稳定）
  List<String> get activeModifiers {
    const order = ['ctrl', 'shift', 'alt', 'cmd'];
    final all = {...stickyOneShot, ...stickyLocked};
    return order.where(all.contains).toList();
  }

  bool isSticky(String token) => stickyOneShot.contains(token) || stickyLocked.contains(token);
  bool isLocked(String token) => stickyLocked.contains(token);

  // -------------------------------------------------------------------------
  // 初始化
  // -------------------------------------------------------------------------
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final p = _prefs!;
    kind = LinkKind.values[p.getInt('kind') ?? 0];
    deviceName = p.getString('deviceName') ?? LinkInfo.defaultName;
    wifiHost = p.getString('wifiHost') ?? LinkInfo.defaultHost;
    wifiPort = p.getInt('wifiPort') ?? LinkInfo.defaultPort;
    mouseSpeed = p.getDouble('mouseSpeed') ?? 1.6;
    haptics = p.getBool('haptics') ?? true;
    presetOs = p.getString('presetOs') ?? 'windows';
    lastRemoteId = p.getString('lastRemoteId');
    lastName = p.getString('lastName');

    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      adapterState = state;
      if (state != BluetoothAdapterState.on && phase == Phase.scanning) {
        stopScan();
      }
      _safeNotify();
    });

    // 拿一次当前状态（adapterState 流只推变化）
    try {
      adapterState = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // 模拟器 / 没有蓝牙的设备：保持 unknown，界面提示即可
    }

    _addLog('就绪。蓝牙 ${adapterState == BluetoothAdapterState.on ? "可用" : "不可用"}');
    _safeNotify();
  }

  void _save() {
    final p = _prefs;
    if (p == null) return;
    p.setInt('kind', kind.index);
    p.setString('deviceName', deviceName);
    p.setString('wifiHost', wifiHost);
    p.setInt('wifiPort', wifiPort);
    p.setDouble('mouseSpeed', mouseSpeed);
    p.setBool('haptics', haptics);
    p.setString('presetOs', presetOs);
    if (lastRemoteId != null) p.setString('lastRemoteId', lastRemoteId!);
    if (lastName != null) p.setString('lastName', lastName!);
  }

  void setKind(LinkKind k) {
    kind = k;
    _save();
    _safeNotify();
  }

  void setDeviceName(String v) {
    deviceName = v.trim().isEmpty ? LinkInfo.defaultName : v.trim();
    _save();
    _safeNotify();
  }

  void setWifi(String host, int port) {
    wifiHost = host.trim().isEmpty ? LinkInfo.defaultHost : host.trim();
    wifiPort = port;
    _save();
    _safeNotify();
  }

  void setMouseSpeed(double v) {
    mouseSpeed = v.clamp(0.4, 4.0);
    _save();
    _safeNotify();
  }

  void setHaptics(bool v) {
    haptics = v;
    _save();
    _safeNotify();
  }

  void setPresetOs(String v) {
    presetOs = v;
    _save();
    _safeNotify();
  }

  // -------------------------------------------------------------------------
  // 扫描
  // -------------------------------------------------------------------------
  Future<void> startScan() async {
    if (adapterState != BluetoothAdapterState.on) {
      lastError = defaultTargetPlatform == TargetPlatform.iOS
          ? '蓝牙不可用：请打开系统蓝牙，并允许本 App 使用蓝牙'
          : '蓝牙不可用：请在系统设置里打开蓝牙';
      _addLog(lastError!, isError: true);
      _safeNotify();
      return;
    }

    lastError = null;
    phase = Phase.scanning;
    scans = const [];
    _safeNotify();

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      // 按信号强度排，最近的排前面
      final list = [...results]..sort((a, b) => b.rssi.compareTo(a.rssi));
      scans = list;
      _safeNotify();
    });

    await _scanningSub?.cancel();
    _scanningSub = FlutterBluePlus.isScanning.listen((scanning) {
      if (!scanning && phase == Phase.scanning) {
        phase = Phase.idle;
        statusLine = scans.isEmpty ? '没扫到设备' : '扫描结束';
        _safeNotify();
      }
    });

    try {
      await FlutterBluePlus.startScan(
        // 固件在广播里带了服务 UUID，按它过滤最省电也最快；
        // 名字匹配留给「手动按名字找」的情况（withNames 在部分安卓机型上不可靠）
        withServices: [Guid(LinkInfo.service)],
        timeout: const Duration(seconds: 12),
        androidScanMode: AndroidScanMode.lowLatency,
        androidUsesFineLocation: true,
      );
    } catch (e) {
      phase = Phase.idle;
      lastError = '扫描失败：$e';
      _addLog(lastError!, isError: true);
      _safeNotify();
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (phase == Phase.scanning) {
      phase = Phase.idle;
      _safeNotify();
    }
  }

  // -------------------------------------------------------------------------
  // 连接
  // -------------------------------------------------------------------------
  Future<void> connectBle(BluetoothDevice device) async {
    await stopScan();
    phase = Phase.connecting;
    statusLine = '正在连接…';
    lastError = null;
    _safeNotify();

    final transport = BleTransport(device);
    try {
      await transport.open();
      _transport = transport;
      _attach(transport);
      phase = Phase.connected;
      statusLine = '已连接 · ${device.platformName.isEmpty ? device.remoteId.str : device.platformName}';
      lastRemoteId = device.remoteId.str;
      lastName = device.platformName;
      _save();
      _addLog('已连接 ${statusLine.split("·").last.trim()}');
      _afterConnected();
    } catch (e) {
      await transport.close();
      _transport = null;
      phase = Phase.idle;
      statusLine = '连接失败';
      lastError = _humanize(e);
      _addLog(lastError!, isError: true);
    }
    _safeNotify();
  }

  Future<void> connectLastBle() async {
    final id = lastRemoteId;
    if (id == null) return;
    await connectBle(BluetoothDevice.fromId(id));
  }

  Future<void> connectWifi() async {
    phase = Phase.connecting;
    statusLine = '正在连接…';
    lastError = null;
    _safeNotify();

    final transport = TcpTransport(wifiHost, wifiPort);
    try {
      await transport.open();
      _transport = transport;
      _attach(transport);
      phase = Phase.connected;
      statusLine = '已连接 · Wi-Fi';
      _addLog('已连接 $wifiHost:$wifiPort');
      _afterConnected();
    } catch (e) {
      await transport.close();
      _transport = null;
      phase = Phase.idle;
      statusLine = '连接失败';
      lastError = _humanize(e);
      _addLog(lastError!, isError: true);
    }
    _safeNotify();
  }

  void _attach(Transport transport) {
    _incomingSub = transport.incoming.listen(_onLine);
    _dropSub = transport.onDropped.listen((e) {
      if (phase != Phase.connected) return;
      phase = Phase.idle;
      statusLine = '已断开';
      _addLog('连接断开：${_humanize(e)}', isError: true);
      _cleanup();
      _safeNotify();
    });
  }

  void _afterConnected() {
    // 连上先问两件事：延迟多少、固件里存的是哪个引导键
    _pingSentAt = DateTime.now().millisecondsSinceEpoch;
    unawaited(sendLine(Cmd.ping));
    unawaited(sendLine(Cmd.bootKeyQuery));

    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      _pingSentAt = DateTime.now().millisecondsSinceEpoch;
      unawaited(sendLine(Cmd.ping));
    });
  }

  Future<void> disconnect() async {
    // 先松键，再断线：不然主机可能以为某个键一直按着
    if (connected) {
      try {
        await _transport?.write(Cmd.releaseAll);
        await _transport?.write(Cmd.mouseRelease);
      } catch (_) {}
    }
    _cleanup();
    phase = Phase.idle;
    statusLine = '未连接';
    bootKey = null;
    rtt = null;
    leds = 0;
    _addLog('已断开连接');
    _safeNotify();
  }

  void _cleanup() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _drainTimer?.cancel();
    _drainTimer = null;
    _pendingX = 0;
    _pendingY = 0;
    _incomingSub?.cancel();
    _incomingSub = null;
    _dropSub?.cancel();
    _dropSub = null;
    final t = _transport;
    _transport = null;
    mouseHeld.clear();
    if (t != null) unawaited(t.close());
  }

  // -------------------------------------------------------------------------
  // 发送
  // -------------------------------------------------------------------------
  Future<bool> sendLine(String line, {bool quiet = false}) async {
    final t = _transport;
    if (t == null || phase != Phase.connected) {
      if (!quiet) {
        statusLine = '未连接，命令没发出去';
        _safeNotify();
      }
      return false;
    }
    try {
      await t.write(line);
      return true;
    } catch (e) {
      _addLog('发送失败：${_humanize(e)}', isError: true);
      _safeNotify();
      return false;
    }
  }

  /// 点一个键帽。修饰键走粘滞，其余按当前粘滞状态决定单发还是组合。
  void tapKey(KeyCap cap) {
    if (cap.modifier) {
      toggleSticky(cap.token);
      return;
    }

    final mods = activeModifiers;
    if (cap.media) {
      unawaited(sendLine(Cmd.media(cap.token)));
    } else {
      for (final line in Cmd.chord(mods, cap.token)) {
        unawaited(sendLine(line, quiet: true));
      }
    }

    // 一次性修饰键用完即弃；锁定的保持
    if (stickyOneShot.isNotEmpty) {
      stickyOneShot.clear();
    }
    _flash(cap.token);
  }

  void sendPreset(List<String> keys) {
    unawaited(sendLine(Cmd.combo(keys)));
    _flash('preset');
  }

  void sendText(String text) {
    if (text.isEmpty) return;
    for (final line in Cmd.typeText(text)) {
      unawaited(sendLine(line, quiet: true));
    }
    _flash('type');
  }

  void toggleSticky(String token) {
    if (stickyLocked.contains(token)) {
      stickyLocked.remove(token);
    } else if (stickyOneShot.contains(token)) {
      stickyOneShot.remove(token);
    } else {
      stickyOneShot.add(token);
    }
    _safeNotify();
  }

  /// 长按修饰键 = 锁定，点一下解锁
  void lockSticky(String token) {
    if (stickyLocked.contains(token)) {
      stickyLocked.remove(token);
    } else {
      stickyOneShot.remove(token);
      stickyLocked.add(token);
    }
    _safeNotify();
  }

  void clearSticky() {
    stickyOneShot.clear();
    stickyLocked.clear();
    _safeNotify();
  }

  /// 只松开鼠标键（切后台时用）。
  ///
  /// 键盘的粘滞修饰键不会真的把键按住（发的是 COMBO），所以不用担心它卡住；
  /// 真正会卡住主机的是鼠标左键——「按住左键」状态下切走，主机就会一直以为在拖拽。
  void releaseMouseButtons() {
    if (mouseHeld.isEmpty) return;
    mouseHeld.clear();
    unawaited(sendLine(Cmd.mouseRelease, quiet: true));
    _safeNotify();
  }

  void releaseAll() {
    unawaited(sendLine(Cmd.releaseAll));
    unawaited(sendLine(Cmd.mouseRelease));
    mouseHeld.clear();
    clearSticky();
    _addLog('已发送：松开所有键');
  }

  // -------------------------------------------------------------------------
  // 鼠标
  // -------------------------------------------------------------------------
  /// 触控板位移入口：先攒、再按 30Hz 批量发。
  ///
  /// BLE 一次写只有 20~180 字节，手指 60Hz 的位移如果一条一条发，连接间隔会被塞满、
  /// 手感反而发粘；攒 33ms 一次既跟手，也顺手把超过 ±127 的位移拆成多条
  /// （HID 相对报告的 dx/dy 是 int8，超了固件会夹住 = 丢位移）。
  void moveBy(double dx, double dy) {
    _pendingX += dx * mouseSpeed;
    _pendingY += dy * mouseSpeed;
    _drainTimer ??= Timer.periodic(const Duration(milliseconds: 33), (_) => _flushMove());
  }

  void _flushMove() {
    final x = _pendingX.truncate();
    final y = _pendingY.truncate();
    _pendingX -= x;
    _pendingY -= y;

    if (x == 0 && y == 0) {
      // 手指停了就关掉定时器，别白白唤醒 CPU
      if (_pendingX.abs() < 1 && _pendingY.abs() < 1) {
        _drainTimer?.cancel();
        _drainTimer = null;
      }
      return;
    }
    for (final line in Cmd.splitMove(x, y)) {
      unawaited(sendLine(line, quiet: true));
    }
  }

  void wheel(int n) {
    // 一次不要滚太多，主机那边会当甩飞
    unawaited(sendLine(Cmd.mouseWheel(n.clamp(-8, 8))));
  }

  void mouseClick(String button) {
    unawaited(sendLine(Cmd.mouseClick(button)));
    _flash('mouse:$button');
  }

  void mouseDown(String button) {
    mouseHeld.add(button);
    unawaited(sendLine(Cmd.mouseDown(button)));
    _safeNotify();
  }

  void mouseUp(String button) {
    mouseHeld.remove(button);
    unawaited(sendLine(Cmd.mouseUp(button)));
    _safeNotify();
  }

  // -------------------------------------------------------------------------
  // BIOS 引导键
  // -------------------------------------------------------------------------
  void setBootKey(String token) {
    unawaited(sendLine(token == 'off' ? Cmd.bootKeyOff : Cmd.bootKey(token)));
    _addLog(token == 'off' ? '已关闭开机引导键' : '已写入开机引导键：$token');
  }

  void replayBootKey() {
    unawaited(sendLine(Cmd.bootKeyNow));
    _addLog('已让板子重发一轮引导键');
  }

  void queryBootKey() => unawaited(sendLine(Cmd.bootKeyQuery));

  void ping() {
    _pingSentAt = DateTime.now().millisecondsSinceEpoch;
    unawaited(sendLine(Cmd.ping));
  }

  // -------------------------------------------------------------------------
  // 回执
  // -------------------------------------------------------------------------
  void _onLine(String line) {
    final upper = line.toUpperCase();

    if (upper.startsWith('PONG')) {
      if (_pingSentAt != null) {
        rtt = DateTime.now().millisecondsSinceEpoch - _pingSentAt!;
        _pingSentAt = null;
      }
      final m = RegExp(r'leds=(\d+)').firstMatch(line);
      if (m != null) leds = int.tryParse(m.group(1)!) ?? 0;
      _safeNotify();
      return; // 心跳不刷日志，不然一秒一条
    }

    if (upper.startsWith('BOOTKEY-ERR')) {
      _addLog('固件拒绝了这个引导键：${line.split(":").last}', isError: true);
      _safeNotify();
      return;
    }

    if (upper.startsWith('BOOTKEY:')) {
      final v = line.split(':').last.trim();
      bootKey = v;
      _addLog('固件当前引导键：$v');
      _safeNotify();
      return;
    }

    _addLog('固件：$line');
  }

  void _flash(String token) {
    flashing.add(token);
    _safeNotify();
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 110), () {
      flashing.clear();
      _safeNotify();
    });
  }

  void _addLog(String text, {bool isError = false}) {
    log.add(LogItem(text, isError: isError));
    if (log.length > 200) log.removeRange(0, log.length - 200);
  }

  void clearLog() {
    log.clear();
    _safeNotify();
  }

  String _humanize(Object e) {
    final s = e.toString();
    if (s.startsWith('Bad state: ')) return s.substring(11);
    if (s.startsWith('Exception: ')) return s.substring(11);
    if (s.startsWith('FlutterBluePlusException: ')) return s.substring(25);
    return s;
  }

  void _safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    _drainTimer?.cancel();
    _flashTimer?.cancel();
    _incomingSub?.cancel();
    _dropSub?.cancel();
    _scanSub?.cancel();
    _scanningSub?.cancel();
    _adapterSub?.cancel();
    _transport?.close();
    super.dispose();
  }
}
