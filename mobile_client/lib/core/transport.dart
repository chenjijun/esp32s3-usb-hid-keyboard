// 链路层：BLE 与 Wi-Fi TCP 对上层是同一套接口（open / write / close / incoming）。
//
// 手机端和电脑端不一样的地方：手机不能抓本机键盘，所以这里只负责「把命令发出去」，
// 不需要 CGEventTap 那一套。BLE 走 GATT 写入，Wi-Fi 走板子开的 TCP 8266。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'protocol.dart';

/// 一条链路的抽象
abstract class Transport {
  /// 建立连接。失败时抛异常，异常信息直接给用户看。
  Future<void> open();

  /// 发送一条已经拼好的命令（不需要带 '\n'）
  Future<void> write(String line);

  /// 关闭
  Future<void> close();

  /// 收固件回执，按行切好
  Stream<String> get incoming;

  /// 连接意外断开时触发（用于界面提示）
  Stream<Object> get onDropped;

  /// 给界面显示的链路描述
  String get label;
}

// ---------------------------------------------------------------------------
// BLE
// ---------------------------------------------------------------------------
class BleTransport implements Transport {
  BleTransport(this.device);

  final BluetoothDevice device;

  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _tx;
  StreamSubscription<List<int>>? _rxSub;
  StreamSubscription<BluetoothConnectionState>? _stateSub;

  final _incoming = StreamController<String>.broadcast();
  final _dropped = StreamController<Object>.broadcast();
  final _buffer = <int>[];

  int _mtu = 23;

  /// 写入串行化：一条长命令（TYPE）会切成多个分片，若两条命令的 await 交叉，
  /// 分片就会互相插队把命令拼坏。所有写入排成一条链。
  Future<void> _writeChain = Future<void>.value();

  @override
  String get label => '蓝牙 · ${device.platformName.isEmpty ? device.remoteId.str : device.platformName}';

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Stream<Object> get onDropped => _dropped.stream;

  @override
  Future<void> open() async {
    // mtu 只在 Android 上生效，iOS 由系统协商；给个大值让长文本一次写完
    await device.connect(timeout: const Duration(seconds: 12), mtu: 185);
    try {
      _mtu = device.mtuNow;
    } catch (_) {
      _mtu = 23;
    }

    final services = await device.discoverServices();
    final service = services.firstWhere(
      (s) => s.uuid.str.toLowerCase() == LinkInfo.service,
      orElse: () => throw StateError(
        '这台设备上没有找到键盘服务（UUID ${LinkInfo.service}）。\n'
        '确认板子是按 BOOT 选到了蓝牙模式（指示灯蓝色 / 紫色）。',
      ),
    );

    for (final c in service.characteristics) {
      final uuid = c.uuid.str.toLowerCase();
      if (uuid == LinkInfo.rx) _rx = c;
      if (uuid == LinkInfo.tx) _tx = c;
    }

    if (_rx == null) {
      await device.disconnect();
      throw StateError('找不到写入特征值，固件版本可能太旧。');
    }

    // 回执：PONG / BOOTKEY:… 都从这里来
    final tx = _tx;
    if (tx != null) {
      await tx.setNotifyValue(true);
      _rxSub = tx.onValueReceived.listen(_onBytes);
    }

    // 掉线要能感知（板子重启、走远、被别的手机抢走）
    _stateSub = device.connectionState.listen((s) {
      if (s == BluetoothConnectionState.disconnected && !_incoming.isClosed) {
        _dropped.add('蓝牙连接已断开');
      }
    });
  }

  void _onBytes(List<int> data) {
    for (final b in data) {
      if (b == 0x0a) {
        if (_buffer.isNotEmpty) {
          final line = utf8.decode(_buffer, allowMalformed: true);
          _buffer.clear();
          if (line.trim().isNotEmpty) _incoming.add(line.trim());
        }
      } else if (b != 0x0d) {
        _buffer.add(b);
        if (_buffer.length > 4096) _buffer.clear(); // 防御：异常数据不要涨内存
      }
    }
  }

  @override
  Future<void> write(String line) {
    final next = _writeChain.then((_) => _writeNow(line));
    // 即使这一条失败，链也要继续往下走，否则后面的命令永远发不出去
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _writeNow(String line) async {
    final rx = _rx;
    if (rx == null) throw StateError('未连接');

    final bytes = utf8.encode('$line\n');

    // 一次写不能超过 MTU-3；长文本（TYPE）就切成若干片。
    // 固件是按字节累积到 '\n' 才执行，所以切片不会把一条命令切坏。
    final chunk = (_mtu - 3).clamp(20, 180);
    for (var i = 0; i < bytes.length; i += chunk) {
      final end = (i + chunk).clamp(0, bytes.length);
      await rx.write(bytes.sublist(i, end), withoutResponse: true);
      // 无回应的写入排太快会被协议栈丢掉，长文本限一下速
      if (bytes.length > chunk) {
        await Future<void>.delayed(const Duration(milliseconds: 12));
      }
    }
  }

  @override
  Future<void> close() async {
    await _rxSub?.cancel();
    _rxSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await device.disconnect();
    } catch (_) {
      // 已经断了就算了
    }
    if (!_incoming.isClosed) await _incoming.close();
    if (!_dropped.isClosed) await _dropped.close();
  }
}

// ---------------------------------------------------------------------------
// Wi-Fi TCP
// ---------------------------------------------------------------------------
class TcpTransport implements Transport {
  TcpTransport(this.host, this.port);

  final String host;
  final int port;

  Socket? _socket;
  StreamSubscription<String>? _lines;
  final _incoming = StreamController<String>.broadcast();
  final _dropped = StreamController<Object>.broadcast();
  bool _closing = false;

  @override
  String get label => 'Wi-Fi · $host:$port';

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  Stream<Object> get onDropped => _dropped.stream;

  @override
  Future<void> open() async {
    try {
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 6));
      socket.setOption(SocketOption.tcpNoDelay, true); // 按键要跟手，别攒包
      _socket = socket;
      _lines = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          final t = line.trim();
          if (t.isNotEmpty) _incoming.add(t);
        },
        onDone: _notifyDrop,
        onError: (Object e) => _notifyDrop(e),
        cancelOnError: true,
      );
    } on SocketException catch (e) {
      throw StateError(
        '连不上 $host:$port（${e.osError?.message ?? e.message}）。\n'
        '手机要先连上板子开的热点「${LinkInfo.apSsid}」，密码 ${LinkInfo.apPassword}。',
      );
    }
  }

  void _notifyDrop([Object? e]) {
    if (_closing || _dropped.isClosed) return;
    _dropped.add(e ?? 'Wi-Fi 连接已断开');
  }

  Future<void> _writeChain = Future<void>.value();

  @override
  Future<void> write(String line) {
    final next = _writeChain.then((_) async {
      final socket = _socket;
      if (socket == null) throw StateError('未连接');
      socket.add(utf8.encode('$line\n'));
      await socket.flush();
    });
    _writeChain = next.catchError((_) {});
    return next;
  }

  @override
  Future<void> close() async {
    _closing = true;
    await _lines?.cancel();
    _lines = null;
    try {
      await _socket?.close();
    } catch (_) {}
    _socket = null;
    if (!_incoming.isClosed) await _incoming.close();
    if (!_dropped.isClosed) await _dropped.close();
  }
}
