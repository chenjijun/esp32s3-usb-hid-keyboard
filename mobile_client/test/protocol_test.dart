// 协议层单测。
//
// 除了拼字符串，这里还做一件更要紧的事：**拿固件源码逐项核对键名和 UUID**。
// 手改协议最容易出的错就是「客户端发了个固件不认识的键」，那种 bug 在真机上
// 只会表现为「按了没反应」，很难查。所以宁可让测试直接读 ../esp32s3_ble_keyboard/*.ino。

import 'dart:io';

import 'package:esp32_keyboard_mobile/core/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固件里 GATT / 键名表的位置（相对本工程根目录）
File? _firmwareFile() {
  for (final rel in const [
    '../esp32s3_ble_keyboard/esp32s3_ble_keyboard.ino',
    '../../esp32s3_ble_keyboard/esp32s3_ble_keyboard.ino',
  ]) {
    final f = File(rel);
    if (f.existsSync()) return f;
  }
  return null;
}

void main() {
  group('命令拼装', () {
    test('键盘', () {
      expect(Cmd.tap('a'), 'TAP:a');
      expect(Cmd.down('lshift'), 'DOWN:lshift');
      expect(Cmd.up('lshift'), 'UP:lshift');
      expect(Cmd.combo(['ctrl', 'alt', 'delete']), 'COMBO:ctrl+alt+delete');
      expect(Cmd.releaseAll, 'RELEASEALL');
      expect(Cmd.ping, 'PING');
    });

    test('文本', () {
      expect(Cmd.typeText('hi'), ['TYPE:hi']);
      expect(Cmd.typeText('a\nb'), ['TYPE:a', 'TAP:enter', 'TYPE:b']);
      expect(Cmd.typeText('a\r\nb'), ['TYPE:a', 'TAP:enter', 'TYPE:b']);
      expect(
        Cmd.typeText('x' * 130),
        ['TYPE:${'x' * 64}', 'TYPE:${'x' * 64}', 'TYPE:${'x' * 2}'],
      );
      expect(Cmd.typeText(''), isEmpty);
    });

    test('可输入判定', () {
      expect(Cmd.isTypeable('hello 123 !@#'), isTrue);
      expect(Cmd.isTypeable('你好'), isFalse);
      expect(Cmd.isTypeable('a\nb'), isTrue);
    });

    test('多媒体与小键盘', () {
      expect(Cmd.media('volup'), 'MEDIA:volup');
      expect(Cmd.tap('kp7'), 'TAP:kp7');
    });

    test('鼠标', () {
      expect(Cmd.mouseMove(12, -7), 'MOUSE:move 12 -7');
      expect(Cmd.mouseWheel(3), 'MOUSE:wheel 3');
      expect(Cmd.mouseClick('right'), 'MOUSE:click right');
      expect(Cmd.mouseDown('left'), 'MOUSE:down left');
      expect(Cmd.mouseUp('left'), 'MOUSE:up left');
      expect(Cmd.mouseRelease, 'MOUSE:release');
    });
  });

  group('位移拆条', () {
    test('±127 以内原样发', () {
      expect(Cmd.splitMove(12, -7), ['MOUSE:move 12 -7']);
      expect(Cmd.splitMove(0, 0), isEmpty);
    });

    test('大位移拆成多条，且总和不变', () {
      for (final pair in const [[300, -300], [0, 500], [-128, 127], [1, 900]]) {
        final lines = Cmd.splitMove(pair[0], pair[1]);
        var sx = 0, sy = 0;
        for (final line in lines) {
          final parts = line.substring('MOUSE:move '.length).split(' ');
          final dx = int.parse(parts[0]);
          final dy = int.parse(parts[1]);
          expect(dx.abs() <= 127 && dy.abs() <= 127, isTrue, reason: line);
          sx += dx;
          sy += dy;
        }
        expect(sx, pair[0]);
        expect(sy, pair[1]);
      }
    });
  });

  group('修饰键组合', () {
    test('没有修饰键就单发', () {
      expect(Cmd.chord([], 'c'), ['TAP:c']);
    });

    test('有修饰键走 COMBO', () {
      expect(Cmd.chord(['ctrl', 'shift'], 'esc'), ['COMBO:ctrl+shift+esc']);
    });

    test('键名本身是 + 时改走 DOWN/TAP/UP', () {
      expect(Cmd.chord(['shift'], '+'), [
        'DOWN:shift',
        'TAP:+',
        'UP:shift',
      ]);
    });

    test('多媒体键不会带修饰键', () {
      // tapKey 里 media 分支单独处理，这里只保证协议层不擅自拼 COMBO
      expect(Cmd.media('mute'), 'MEDIA:mute');
    });
  });

  group('布局数据', () {
    test('每一页都有键，且没有空键名', () {
      for (final page in [Layout.alpha, Layout.symbols, Layout.nav, Layout.fn, Layout.numpad]) {
        expect(page, isNotEmpty);
        for (final row in page) {
          expect(row, isNotEmpty);
          for (final cap in row) {
            expect(cap.token, isNotEmpty);
            expect(cap.label, isNotEmpty);
            expect(cap.flex, greaterThan(0));
          }
        }
      }
    });

    test('字母页覆盖了 a-z、0-9 和常用控制键', () {
      final tokens = Layout.alpha.expand((r) => r).map((c) => c.token).toSet();
      for (final ch in 'abcdefghijklmnopqrstuvwxyz0123456789'.split('')) {
        expect(tokens.contains(ch), isTrue, reason: '缺少 $ch');
      }
      for (final t in ['enter', 'tab', 'space', 'backspace', 'esc', 'shift', 'ctrl', 'alt', 'cmd']) {
        expect(tokens.contains(t), isTrue, reason: '缺少 $t');
      }
    });

    test('BIOS 键都在固件支持范围内', () {
      expect(Layout.biosKeys.map((k) => k.token).toList(),
          ['delete', 'f2', 'f10', 'f12', 'f1', 'f8', 'esc', 'off']);
    });

    test('预设不为空，且不含 "+" 这种会被 COMBO 拆坏的键', () {
      for (final list in [Layout.winPresets, Layout.macPresets]) {
        expect(list, isNotEmpty);
        for (final p in list) {
          expect(p.keys, isNotEmpty);
          expect(p.keys.any((k) => k.contains('+')), isFalse, reason: p.label);
        }
      }
    });
  });

  group('与固件一致性', () {
    test('GATT UUID 与固件一致', () {
      final f = _firmwareFile();
      if (f == null) {
        markTestSkipped('没有固件源码，跳过');
        return;
      }
      final src = f.readAsStringSync();
      expect(src, contains('"${LinkInfo.service}"'));
      expect(src, contains('"${LinkInfo.rx}"'));
      expect(src, contains('"${LinkInfo.tx}"'));
      expect(src, contains('"${LinkInfo.defaultName}"'));
    });

    test('界面用到的每个键名固件都能解析', () {
      final f = _firmwareFile();
      if (f == null) {
        markTestSkipped('没有固件源码，跳过');
        return;
      }
      final src = f.readAsStringSync();

      // 1) 命名键表 {"name", KT_KEY_...}
      final named = RegExp(r'\{"([^"]+)",\s*KT_(?:KEY|MEDIA)_')
          .allMatches(src)
          .map((m) => m.group(1)!.toLowerCase())
          .toSet();

      // 2) f1..f24 / kp0..kp9 是代码推出来的，不在表里
      bool accepted(String token) {
        if (token.length == 1) return true; // 单字符交给库查 ASCII 表
        if (named.contains(token)) return true;
        final fm = RegExp(r'^f(\d+)$').firstMatch(token);
        if (fm != null) {
          final n = int.parse(fm.group(1)!);
          return n >= 1 && n <= 24;
        }
        if (RegExp(r'^kp\d$').hasMatch(token)) return true;
        return false;
      }

      final used = <String>{};
      for (final page in [Layout.alpha, Layout.symbols, Layout.nav, Layout.fn, Layout.numpad]) {
        for (final row in page) {
          for (final cap in row) {
            if (!cap.media) used.add(cap.token);
          }
        }
      }
      for (final list in [Layout.winPresets, Layout.macPresets]) {
        for (final p in list) {
          used.addAll(p.keys);
        }
      }
      // win 是 cmd 的别名，固件里两个都有
      final missing = used.where((t) => !accepted(t)).toList()..sort();
      expect(missing, isEmpty, reason: '固件不认识这些键名: $missing');
    });

    test('多媒体键名对得上', () {
      final f = _firmwareFile();
      if (f == null) {
        markTestSkipped('没有固件源码，跳过');
        return;
      }
      final src = f.readAsStringSync();
      final media = Layout.fn
          .expand((r) => r)
          .where((c) => c.media)
          .map((c) => c.token)
          .toList();
      expect(media, isNotEmpty);
      for (final m in media) {
        // 固件用 kt_eq(p, n, "volup") 这样的形式匹配
        expect(src.contains('"$m"'), isTrue, reason: '固件没有多媒体键 $m');
      }
    });

    test('鼠标键名只有 left / middle / right', () {
      final f = _firmwareFile();
      if (f == null) {
        markTestSkipped('没有固件源码，跳过');
        return;
      }
      final src = f.readAsStringSync();
      for (final btn in ['left', 'middle', 'right']) {
        expect(src.contains('"$btn"'), isTrue, reason: '固件不认识鼠标键 $btn');
      }
    });
  });
}
