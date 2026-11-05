// 协议层 —— 只负责「把动作拼成固件认识的字符串」，不碰蓝牙、不碰界面。
//
// 固件 esp32s3_ble_keyboard.ino 里的命令格式：
//   TAP:<键> / DOWN:<键> / UP:<键> / TYPE:<文本> / COMBO:<键>+<键> / RELEASEALL
//   MEDIA:<名称> / PING / BOOTKEY:<键|off|now|?>
//   MOUSE:move <dx> <dy> / MOUSE:wheel <n> / MOUSE:down|up|click <left|middle|right>
//
// 键名与 firmware 的 KT_NAMED_KEYS 表一致（单元测试会去 .ino 里逐项核对）。

library;

/// BLE 的 GATT 标识，必须与固件常量一致
class LinkInfo {
  static const String service = '12345678-1234-5678-1234-56789abcdef0';
  static const String rx = '12345678-1234-5678-1234-56789abcdef1'; // 写命令
  static const String tx = '12345678-1234-5678-1234-56789abcdef2'; // 通知回执

  static const String defaultName = 'ESP32-Keyboard';

  /// Wi-Fi 链路：板子开的热点，手机连上后连这个地址
  static const String defaultHost = '192.168.4.1';
  static const int defaultPort = 8266;

  /// 板子热点的 SSID / 密码（固件里写死）
  static const String apSsid = 'ESP32-Keyboard';
  static const String apPassword = 'esp32keyboard';
}

/// 命令拼装。所有方法都是纯函数，方便单测。
class Cmd {
  static String tap(String token) => 'TAP:$token';
  static String down(String token) => 'DOWN:$token';
  static String up(String token) => 'UP:$token';

  /// 组合键：固件按顺序按下、再逆序松开。
  static String combo(List<String> keys) => 'COMBO:${keys.join('+')}';

  static const String releaseAll = 'RELEASEALL';
  static const String ping = 'PING';

  static String bootKey(String token) => 'BOOTKEY:$token';
  static const String bootKeyQuery = 'BOOTKEY:?';
  static const String bootKeyNow = 'BOOTKEY:now';
  static const String bootKeyOff = 'BOOTKEY:off';

  static String media(String name) => 'MEDIA:$name';

  /// 带修饰键地按一个键。
  ///
  /// 一般用 COMBO 最稳（固件按下后逆序松开，不会残留）。
  /// 但 COMBO 用 '+' 分隔键名，所以键名自己就是 '+' 时得改用 DOWN/TAP/UP 序列。
  static List<String> chord(List<String> mods, String token) {
    if (mods.isEmpty) return [tap(token)];
    if (token.contains('+')) {
      return [
        for (final m in mods) down(m),
        tap(token),
        for (final m in mods.reversed) up(m),
      ];
    }
    return [combo([...mods, token])];
  }

  /// 相对位移。dx/dy 必须落在 ±127（HID 相对报告是 int8），
  /// 超出时请用 [splitMove] 拆条 —— 固件会夹值，夹了就丢位移。
  static String mouseMove(int dx, int dy) => 'MOUSE:move $dx $dy';
  static String mouseWheel(int n) => 'MOUSE:wheel $n';
  static String mouseDown(String btn) => 'MOUSE:down $btn';
  static String mouseUp(String btn) => 'MOUSE:up $btn';
  static String mouseClick(String btn) => 'MOUSE:click $btn';
  static const String mouseRelease = 'MOUSE:release';

  /// 把一次大位移拆成若干条合法的 move 命令。
  static List<String> splitMove(int dx, int dy) {
    final out = <String>[];
    var x = dx, y = dy;
    while (x != 0 || y != 0) {
      final sx = x.clamp(-127, 127);
      final sy = y.clamp(-127, 127);
      out.add(mouseMove(sx, sy));
      x -= sx;
      y -= sy;
    }
    return out;
  }

  /// TYPE 命令按行拆开：协议一条命令以 '\n' 结尾，文本里的换行只能变成回车键。
  /// 返回的是完整的命令序列（含换行处补的 TAP:enter）。
  static List<String> typeText(String text, {int chunk = 64}) {
    final out = <String>[];
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      for (var start = 0; start < line.length; start += chunk) {
        final end = (start + chunk).clamp(0, line.length);
        out.add('TYPE:${line.substring(start, end)}');
      }
      if (i != lines.length - 1) out.add(tap('enter'));
    }
    return out;
  }

  /// 文本能否被固件「按字符」敲出来：只支持能映射到 HID 键码的 ASCII。
  static bool isTypeable(String text) =>
      text.runes.every((r) => r == 10 || r == 13 || (r >= 0x20 && r <= 0x7e));
}

/// 一个键帽
class KeyCap {
  /// 显示文字
  final String label;
  /// 协议键名
  final String token;
  /// 宽度倍数（1 = 一个标准键）
  final double flex;
  /// 是否是修饰键（点击后变成「粘滞」，不直接发 TAP）
  final bool modifier;
  /// 是否是多媒体键（发 MEDIA: 而不是 TAP:）
  final bool media;

  const KeyCap(
    this.label,
    this.token, {
    this.flex = 1,
    this.modifier = false,
    this.media = false,
  });
}

/// 快捷键预设
class Preset {
  final String label;
  final List<String> keys;
  const Preset(this.label, this.keys);
}

/// 屏幕键盘布局。手机上横向空间有限，字母区按 11 键一行排，
/// 功能键 / 编辑键 / 小键盘各占一个分页，避免一屏塞 60 个键。
class Layout {
  static const KeyCap _shift = KeyCap('⇧', 'shift', modifier: true);
  static const KeyCap _ctrl = KeyCap('⌃', 'ctrl', modifier: true);
  static const KeyCap _alt = KeyCap('⌥', 'alt', modifier: true);
  static const KeyCap _win = KeyCap('⊞', 'cmd', modifier: true);

  /// 修饰键行固定放在键盘上方，永远可点
  static const List<KeyCap> modifiers = [_shift, _ctrl, _alt, _win];

  static const List<List<KeyCap>> alpha = [
    [
      KeyCap('esc', 'esc'),
      KeyCap('1', '1'), KeyCap('2', '2'), KeyCap('3', '3'), KeyCap('4', '4'),
      KeyCap('5', '5'), KeyCap('6', '6'), KeyCap('7', '7'), KeyCap('8', '8'),
      KeyCap('9', '9'), KeyCap('0', '0'),
    ],
    [
      KeyCap('tab', 'tab'),
      KeyCap('q', 'q'), KeyCap('w', 'w'), KeyCap('e', 'e'), KeyCap('r', 'r'),
      KeyCap('t', 't'), KeyCap('y', 'y'), KeyCap('u', 'u'), KeyCap('i', 'i'),
      KeyCap('o', 'o'), KeyCap('p', 'p'),
    ],
    [
      KeyCap('caps', 'capslock'),
      KeyCap('a', 'a'), KeyCap('s', 's'), KeyCap('d', 'd'), KeyCap('f', 'f'),
      KeyCap('g', 'g'), KeyCap('h', 'h'), KeyCap('j', 'j'), KeyCap('k', 'k'),
      KeyCap('l', 'l'), KeyCap('⌫', 'backspace'),
    ],
    [
      KeyCap('⇧', 'shift', modifier: true),
      KeyCap('z', 'z'), KeyCap('x', 'x'), KeyCap('c', 'c'), KeyCap('v', 'v'),
      KeyCap('b', 'b'), KeyCap('n', 'n'), KeyCap('m', 'm'),
      KeyCap(',', ','), KeyCap('.', '.'), KeyCap('/', '/'),
    ],
    [
      KeyCap('-', '-'), KeyCap('=', '='), KeyCap('[', '['), KeyCap(']', ']'),
      KeyCap('\\', '\\'), KeyCap(';', ';'), KeyCap("'", "'"), KeyCap('`', '`'),
      KeyCap('⏎', 'enter', flex: 1.6),
    ],
    [
      KeyCap('⌃', 'ctrl', modifier: true, flex: 1.2),
      KeyCap('⌥', 'alt', modifier: true, flex: 1.2),
      KeyCap('⊞', 'cmd', modifier: true, flex: 1.2),
      KeyCap('space', 'space', flex: 4),
      KeyCap('←', 'left'), KeyCap('↑', 'up'),
      KeyCap('↓', 'down'), KeyCap('→', 'right'),
    ],
  ];

  /// 编辑 / 导航键
  static const List<List<KeyCap>> nav = [    [
      KeyCap('ins', 'insert'), KeyCap('home', 'home'), KeyCap('pgup', 'pageup'),
      KeyCap('prtsc', 'printscreen'),
    ],
    [
      KeyCap('del', 'delete'), KeyCap('end', 'end'), KeyCap('pgdn', 'pagedown'),
      KeyCap('menu', 'menu'),
    ],
    [
      KeyCap('←', 'left'), KeyCap('↑', 'up'), KeyCap('↓', 'down'),
      KeyCap('→', 'right'),
    ],
  ];

  /// 横屏用：横向够宽，把竖屏的 6 行并成 5 行，每行 13~14 个键。
  /// 竖屏那套在横屏里行高只剩 20 多 pt，字都糊在一起。
  static const List<List<KeyCap>> alphaWide = [
    [
      KeyCap('esc', 'esc'),
      KeyCap('1', '1'), KeyCap('2', '2'), KeyCap('3', '3'), KeyCap('4', '4'),
      KeyCap('5', '5'), KeyCap('6', '6'), KeyCap('7', '7'), KeyCap('8', '8'),
      KeyCap('9', '9'), KeyCap('0', '0'), KeyCap('-', '-'), KeyCap('=', '='),
      KeyCap('⌫', 'backspace'),
    ],
    [
      KeyCap('tab', 'tab'),
      KeyCap('q', 'q'), KeyCap('w', 'w'), KeyCap('e', 'e'), KeyCap('r', 'r'),
      KeyCap('t', 't'), KeyCap('y', 'y'), KeyCap('u', 'u'), KeyCap('i', 'i'),
      KeyCap('o', 'o'), KeyCap('p', 'p'), KeyCap('[', '['), KeyCap(']', ']'),
      KeyCap('\\', '\\'),
    ],
    [
      KeyCap('caps', 'capslock'),
      KeyCap('a', 'a'), KeyCap('s', 's'), KeyCap('d', 'd'), KeyCap('f', 'f'),
      KeyCap('g', 'g'), KeyCap('h', 'h'), KeyCap('j', 'j'), KeyCap('k', 'k'),
      KeyCap('l', 'l'), KeyCap(';', ';'), KeyCap("'", "'"),
      KeyCap('⏎', 'enter'),
    ],
    [
      KeyCap('⇧', 'shift', modifier: true),
      KeyCap('z', 'z'), KeyCap('x', 'x'), KeyCap('c', 'c'), KeyCap('v', 'v'),
      KeyCap('b', 'b'), KeyCap('n', 'n'), KeyCap('m', 'm'),
      KeyCap(',', ','), KeyCap('.', '.'), KeyCap('/', '/'), KeyCap('`', '`'),
    ],
    [
      KeyCap('⌃', 'ctrl', modifier: true),
      KeyCap('⌥', 'alt', modifier: true),
      KeyCap('⊞', 'cmd', modifier: true),
      KeyCap('space', 'space', flex: 5),
      KeyCap('←', 'left'), KeyCap('↑', 'up'),
      KeyCap('↓', 'down'), KeyCap('→', 'right'),
    ],
  ];

  /// 符号页。单字符键名固件会交给库自动补 Shift，所以 '!' 直接写 '!'，
  /// 不需要客户端自己拼 shift+1。
  static const List<List<KeyCap>> symbols = [
    [
      KeyCap('!', '!'), KeyCap('@', '@'), KeyCap('#', '#'), KeyCap('\$', '\$'),
      KeyCap('%', '%'), KeyCap('^', '^'), KeyCap('&', '&'), KeyCap('*', '*'),
      KeyCap('(', '('), KeyCap(')', ')'),
    ],
    [
      KeyCap('-', '-'), KeyCap('_', '_'), KeyCap('=', '='), KeyCap('+', '+'),
      KeyCap('[', '['), KeyCap(']', ']'), KeyCap('{', '{'), KeyCap('}', '}'),
      KeyCap('\\', '\\'), KeyCap('|', '|'),
    ],
    [
      KeyCap(';', ';'), KeyCap(':', ':'), KeyCap("'", "'"), KeyCap('"', '"'),
      KeyCap(',', ','), KeyCap('.', '.'), KeyCap('/', '/'), KeyCap('?', '?'),
      KeyCap('~', '~'), KeyCap('`', '`'),
    ],
    [
      KeyCap('esc', 'esc', flex: 1.2), KeyCap('tab', 'tab', flex: 1.2),
      KeyCap('⌫', 'backspace', flex: 1.6), KeyCap('⏎', 'enter', flex: 1.6),
    ],
  ];

  /// 功能键 + 多媒体键
  static const List<List<KeyCap>> fn = [
    [
      KeyCap('F1', 'f1'), KeyCap('F2', 'f2'), KeyCap('F3', 'f3'),
      KeyCap('F4', 'f4'), KeyCap('F5', 'f5'), KeyCap('F6', 'f6'),
    ],
    [
      KeyCap('F7', 'f7'), KeyCap('F8', 'f8'), KeyCap('F9', 'f9'),
      KeyCap('F10', 'f10'), KeyCap('F11', 'f11'), KeyCap('F12', 'f12'),
    ],
    [
      KeyCap('⏮', 'prev', media: true), KeyCap('⏯', 'playpause', media: true),
      KeyCap('⏭', 'next', media: true), KeyCap('🔇', 'mute', media: true),
    ],
    [
      KeyCap('音量−', 'voldown', media: true),
      KeyCap('音量＋', 'volup', media: true),
      KeyCap('亮度−', 'brightnessdown', media: true),
      KeyCap('亮度＋', 'brightnessup', media: true),
    ],
  ];

  /// 小键盘
  static const List<List<KeyCap>> numpad = [
    [KeyCap('⌫', 'backspace', flex: 2), KeyCap('tab', 'tab'), KeyCap('⏎', 'kpenter')],
    [KeyCap('7', 'kp7'), KeyCap('8', 'kp8'), KeyCap('9', 'kp9'), KeyCap('−', 'kpminus')],
    [KeyCap('4', 'kp4'), KeyCap('5', 'kp5'), KeyCap('6', 'kp6'), KeyCap('+', 'kpplus')],
    [KeyCap('1', 'kp1'), KeyCap('2', 'kp2'), KeyCap('3', 'kp3'), KeyCap('×', 'kpasterisk')],
    [KeyCap('0', 'kp0', flex: 2), KeyCap('.', 'kpdot'), KeyCap('/', 'kpslash')],
  ];

  /// Windows 上的常用快捷键。cmd(⊞) 在主机侧就是 Win 键，
  /// 所以 ⊞+space 发过去正是 Win+Space（Win11 默认的输入法切换）。
  static const List<Preset> winPresets = [
    Preset('切换输入法', ['win', 'space']),
    Preset('中英切换', ['ctrl', 'space']),
    Preset('Shift 中英', ['shift']),
    Preset('布局切换', ['ctrl', 'shift']),
    Preset('复制', ['ctrl', 'c']),
    Preset('粘贴', ['ctrl', 'v']),
    Preset('剪切', ['ctrl', 'x']),
    Preset('撤销', ['ctrl', 'z']),
    Preset('全选', ['ctrl', 'a']),
    Preset('保存', ['ctrl', 's']),
    Preset('切换窗口', ['alt', 'tab']),
    Preset('关闭窗口', ['alt', 'f4']),
    Preset('任务管理器', ['ctrl', 'shift', 'esc']),
    Preset('显示桌面', ['win', 'd']),
    Preset('资源管理器', ['win', 'e']),
    Preset('运行', ['win', 'r']),
    Preset('设置', ['win', 'i']),
    Preset('锁定', ['win', 'l']),
    Preset('搜索', ['win', 's']),
    Preset('截图', ['win', 'shift', 's']),
    Preset('表情符号', ['win', '.']),
    Preset('锁屏', ['ctrl', 'alt', 'delete']),
  ];

  static const List<Preset> macPresets = [
    Preset('复制', ['cmd', 'c']),
    Preset('粘贴', ['cmd', 'v']),
    Preset('剪切', ['cmd', 'x']),
    Preset('撤销', ['cmd', 'z']),
    Preset('全选', ['cmd', 'a']),
    Preset('保存', ['cmd', 's']),
    Preset('查找', ['cmd', 'f']),
    Preset('新建', ['cmd', 'n']),
    Preset('关闭窗口', ['cmd', 'w']),
    Preset('切换窗口', ['cmd', 'tab']),
    Preset('聚焦搜索', ['cmd', 'space']),
    Preset('区域截图', ['cmd', 'shift', '4']),
    Preset('全屏截图', ['cmd', 'shift', '3']),
    Preset('锁屏', ['ctrl', 'cmd', 'q']),
  ];

  /// BIOS / UEFI 启动键：写进固件后，板子上电时自己连发，不依赖手机
  static const List<KeyCap> biosKeys = [
    KeyCap('Del', 'delete'),
    KeyCap('F2', 'f2'),
    KeyCap('F10', 'f10'),
    KeyCap('F12', 'f12'),
    KeyCap('F1', 'f1'),
    KeyCap('F8', 'f8'),
    KeyCap('Esc', 'esc'),
    KeyCap('关闭', 'off'),
  ];
}
