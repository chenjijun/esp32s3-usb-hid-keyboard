// 手机端端到端测试：真的把界面点一遍，看命令是不是按协议发了出去。
//
// 没有硬件也能跑：本机起一个假的 TCP 服务端冒充固件（手机端走 Wi-Fi 链路时
// 就是往 127.0.0.1:18266 写行），界面上的点击 → Remote → socket → 服务端收到的
// 字符串，全链路都覆盖到了。BLE 那半截没法这么测（需要真蓝牙），
// 但它和 Wi-Fi 走的是同一个 Remote，只换了 Transport 实现。
//
// 跑法：
//   flutter test integration_test -d <已启动的模拟器/真机>

import 'dart:convert';
import 'dart:io';

import 'package:esp32_keyboard_mobile/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const int _port = 18266;

/// 等一个条件成立（测试环境里定时器是真实时间，不能只用 pumpAndSettle）
Future<void> _waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail(reason ?? '等待超时');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ServerSocket server;
  final lines = <String>[];
  final clients = <Socket>[];

  setUp(() async {
    lines.clear();
    clients.clear();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, _port);
    server.listen((socket) {
      clients.add(socket);
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(lines.add);
    });
  });

  tearDown(() async {
    for (final c in clients) {
      await c.close();
    }
    await server.close();
  });

  testWidgets('Wi-Fi 链路：连接、点键、粘滞修饰键、鼠标位移、文本输入', (tester) async {
    app.main();
    await tester.pump(const Duration(milliseconds: 600));

    // ---- 1. 打开连接面板，切到 Wi-Fi，填地址 ----
    await tester.tap(find.byTooltip('连接设备'));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Wi-Fi'));
    await tester.pump(const Duration(milliseconds: 300));

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2), reason: 'Wi-Fi 面板应该有主机和端口两个输入框');
    await tester.enterText(fields.at(0), '127.0.0.1');
    await tester.enterText(fields.at(1), '$_port');
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('连接'));
    await _waitFor(tester, () => clients.isNotEmpty, reason: '没有连上假服务端');

    // 连上后客户端会主动发心跳和引导键查询
    await _waitFor(tester, () => lines.contains('PING'), reason: '没收到 PING');
    expect(lines, contains('BOOTKEY:?'));

    // ---- 2. 关掉面板（面板上有一个 × ）----
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('q'), findsWidgets, reason: '应该回到屏幕键盘');

    // ---- 3. 单键 ----
    lines.clear();
    await tester.tap(find.text('q'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(lines, contains('TAP:q'));

    // ---- 4. 粘滞 Shift + 键 = COMBO ----
    lines.clear();
    await tester.tap(find.text('⇧').first);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('q'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(lines, contains('COMBO:shift+q'), reason: '粘滞修饰键没拼成 COMBO');

    // 用完即弃：再点一个键应该是干净的 TAP
    lines.clear();
    await tester.tap(find.text('w'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(lines, contains('TAP:w'));
    expect(lines.any((l) => l.startsWith('COMBO:')), isFalse);

    // ---- 5. 鼠标位移 ----
    await tester.tap(find.text('鼠标'));
    await tester.pump(const Duration(milliseconds: 400));

    lines.clear();
    await tester.drag(find.byKey(const ValueKey('trackpad')), const Offset(140, 70));
    // 位移是 30Hz 攒批发的，等它冲出去
    await tester.pump(const Duration(milliseconds: 300));
    final moves = lines.where((l) => l.startsWith('MOUSE:move ')).toList();
    expect(moves, isNotEmpty, reason: '触控板拖动没有产生 MOUSE:move');
    // 拆包后每条都不能超过 ±127（HID 相对报告是 int8）
    for (final line in moves) {
      final parts = line.substring(11).split(' ');
      expect(int.parse(parts[0]).abs() <= 127, isTrue, reason: line);
      expect(int.parse(parts[1]).abs() <= 127, isTrue, reason: line);
    }

    // ---- 6. 鼠标按键 ----
    lines.clear();
    await tester.tap(find.text('右键'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(lines, contains('MOUSE:click right'));

    // ---- 7. 文本输入（TYPE）----
    await tester.tap(find.text('键盘'));
    await tester.pump(const Duration(milliseconds: 400));

    lines.clear();
    await tester.tap(find.textContaining('输入文本'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField).last, 'hi there');
    await tester.tap(find.text('发送'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(lines, contains('TYPE:hi there'));

    // ---- 8. 固件回执：假的 PONG / BOOTKEY 应该被解析 ----
    clients.last.write('PONG:12345,leds=3\n');
    clients.last.write('BOOTKEY:f2\n');
    await tester.pump(const Duration(milliseconds: 500));
    // 顶部状态条和键盘页的连接卡上都会出现 CAPS 标记
    expect(find.text('CAPS'), findsWidgets, reason: 'PONG 里的 leds 没更新到界面');
  });
}
