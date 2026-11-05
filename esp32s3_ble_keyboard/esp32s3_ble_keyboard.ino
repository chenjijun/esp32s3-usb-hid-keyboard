/*
 * ============================================================================
 *  ESP32-S3 无线键盘桥（BLE 接收 -> USB HID 输出）
 * ----------------------------------------------------------------------------
 *  数据流：
 *    MacBook  --BLE(自定义 GATT)-->  ESP32-S3  --USB OTG(原生 HID)-->  主机
 *
 *  ESP32-S3 同时扮演两个角色：
 *    1) BLE 外设：对外广播 "ESP32-Keyboard"，提供一个可写入的特征用于收命令
 *    2) USB HID 键盘：插在主机上，把收到的命令变成真实按键
 *
 *  板载 RGB 灯（默认 GPIO48）有两层意思：
 *    底色  = 链路状态：蓝/紫 = BLE 未连/已连，绿/黄 = Wi-Fi 未连/已连
 *    白闪  = 指令回执：每执行完一条命令闪一下，闪几下由命令长度决定
 *            （短按 1 下、长文本 6 下，阈值见 LED_CMD_* 宏）
 *
 *  Arduino IDE 板卡设置（必须）：
 *    开发板        : ESP32S3 Dev Module
 *    USB Mode      : USB-OTG (TinyUSB)     <-- 关键，否则 USBHIDKeyboard 不可用
 *    USB CDC On Boot: Enabled              <-- 让 Serial 还能从 USB 看日志
 *    Flash Size    : 按你的模组选（如 16MB）
 *    PSRAM         : 按你的模组选（可选）
 *
 *  接线：
 *    ESP32-S3 的 "USB"（原生 USB，GPIO19=D- / GPIO20=D+）接主机
 *    供电也走这个口；若板子有单独的 UART 口，日志也可以从 UART 看
 *
 *  文件说明：
 *    本文件为自包含的单文件 sketch，不再依赖其它 .h。
 *    开头一段是「协议解析 + 键名映射」（纯 C++，不依赖 Arduino），
 *    之后是「BLE 收发 + USB HID 输出」。
 * ============================================================================
 */

#include <deque>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#include <WiFi.h>
#include <Preferences.h>
#include <esp_system.h>   // esp_reset_reason()：判断是不是真的冷启动

#include "USB.h"
#include "USBHIDKeyboard.h"
#include "USBHIDConsumerControl.h"
#include "USBHIDMouse.h"

/* ===========================================================================
 *  第一部分：协议解析与键名映射
 * ----------------------------------------------------------------------------
 *  职责：把 BLE 收到的文本协议（TAP: / COMBO: / TYPE: ...）翻译成 HID 键码，
 *        供下面的固件代码调用 Keyboard / ConsumerControl 发出按键。
 *
 *  纯 C/C++，不依赖 Arduino 和硬件，只用标准头就能编译；
 *  改键名或加新命令时只需要改这一段，不必碰 BLE 和 USB 的代码。
 * ===========================================================================
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

// 组合键最多同时按下的键数（HID 报告本身支持 6 键 + 8 修饰键）
#define KT_MAX_COMBO 10

// ---------------------------------------------------------------------------
// 键码：与 Arduino ESP32 核心 USBHIDKeyboard.h 里的 KEY_* 完全一致。
// 固件里用 static_assert 交叉校验，核心升级后若改了编码，编译期就会报错。
// ---------------------------------------------------------------------------
enum {
  KT_KEY_LEFT_CTRL = 0x80,
  KT_KEY_LEFT_SHIFT = 0x81,
  KT_KEY_LEFT_ALT = 0x82,
  KT_KEY_LEFT_GUI = 0x83,
  KT_KEY_RIGHT_CTRL = 0x84,
  KT_KEY_RIGHT_SHIFT = 0x85,
  KT_KEY_RIGHT_ALT = 0x86,
  KT_KEY_RIGHT_GUI = 0x87,

  KT_KEY_SPACE = 0x20,
  KT_KEY_RETURN = 0xB0,
  KT_KEY_ESC = 0xB1,
  KT_KEY_BACKSPACE = 0xB2,
  KT_KEY_TAB = 0xB3,
  KT_KEY_CAPS_LOCK = 0xC1,
  KT_KEY_F1 = 0xC2,
  KT_KEY_F2 = 0xC3,
  KT_KEY_F3 = 0xC4,
  KT_KEY_F4 = 0xC5,
  KT_KEY_F5 = 0xC6,
  KT_KEY_F6 = 0xC7,
  KT_KEY_F7 = 0xC8,
  KT_KEY_F8 = 0xC9,
  KT_KEY_F9 = 0xCA,
  KT_KEY_F10 = 0xCB,
  KT_KEY_F11 = 0xCC,
  KT_KEY_F12 = 0xCD,
  KT_KEY_PRINT_SCREEN = 0xCE,
  KT_KEY_SCROLL_LOCK = 0xCF,
  KT_KEY_PAUSE = 0xD0,
  KT_KEY_INSERT = 0xD1,
  KT_KEY_HOME = 0xD2,
  KT_KEY_PAGE_UP = 0xD3,
  KT_KEY_DELETE = 0xD4,
  KT_KEY_END = 0xD5,
  KT_KEY_PAGE_DOWN = 0xD6,
  KT_KEY_RIGHT_ARROW = 0xD7,
  KT_KEY_LEFT_ARROW = 0xD8,
  KT_KEY_DOWN_ARROW = 0xD9,
  KT_KEY_UP_ARROW = 0xDA,
  KT_KEY_NUM_LOCK = 0xDB,
  KT_KEY_KP_SLASH = 0xDC,
  KT_KEY_KP_ASTERISK = 0xDD,
  KT_KEY_KP_MINUS = 0xDE,
  KT_KEY_KP_PLUS = 0xDF,
  KT_KEY_KP_ENTER = 0xE0,
  // 注意：小键盘数字不是顺序排列的，1..9 是 0xE1..0xE9，0 在最后 0xEA。
  KT_KEY_KP_1 = 0xE1,
  KT_KEY_KP_2 = 0xE2,
  KT_KEY_KP_3 = 0xE3,
  KT_KEY_KP_4 = 0xE4,
  KT_KEY_KP_5 = 0xE5,
  KT_KEY_KP_6 = 0xE6,
  KT_KEY_KP_7 = 0xE7,
  KT_KEY_KP_8 = 0xE8,
  KT_KEY_KP_9 = 0xE9,
  KT_KEY_KP_0 = 0xEA,
  KT_KEY_KP_DOT = 0xEB,
  KT_KEY_MENU = 0xED,
};

// 多媒体键码：与 USBHIDConsumerControl.h 一致
enum {
  KT_MEDIA_VOLUME_INCREMENT = 0x00E9,
  KT_MEDIA_VOLUME_DECREMENT = 0x00EA,
  KT_MEDIA_MUTE = 0x00E2,
  KT_MEDIA_PLAY_PAUSE = 0x00CD,
  KT_MEDIA_SCAN_NEXT = 0x00B5,
  KT_MEDIA_SCAN_PREVIOUS = 0x00B6,
  KT_MEDIA_BRIGHTNESS_INCREMENT = 0x006F,
  KT_MEDIA_BRIGHTNESS_DECREMENT = 0x0070,
};

// ---------------------------------------------------------------------------
// 命令类型
// ---------------------------------------------------------------------------
enum KtAction {
  KT_NONE = 0,   // 空行
  KT_TAP,        // TAP:key
  KT_DOWN,       // DOWN:key
  KT_UP,         // UP:key
  KT_TYPE,       // TYPE:text
  KT_COMBO,      // COMBO:cmd+shift+4
  KT_MEDIA,      // MEDIA:volup
  KT_RELEASEALL, // RELEASEALL
  KT_PING,       // PING
  KT_UNKNOWN,    // 解析失败
};

struct KtPlan {
  uint8_t action;              // KtAction
  uint8_t key;                 // TAP / DOWN / UP 用
  uint8_t keys[KT_MAX_COMBO];  // COMBO 用，按顺序按下
  uint8_t keyCount;
  const char *text;            // TYPE 用，指向传入行内部，不做拷贝
  size_t textLen;
  uint16_t media;              // MEDIA 用
};

// ---------------------------------------------------------------------------
// 键名 -> 键码；找不到返回 -1。
// 支持：单字符、"enter" 这类名字、"f1".."f12"、"kp0".."kp9"（大小写不敏感）
// ---------------------------------------------------------------------------
static const uint8_t KT_KP_DIGITS[10] = {
    0xEA, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9,
};

struct KtNamed {
  const char *name;
  uint8_t code;
};

static const KtNamed KT_NAMED_KEYS[] = {
    // 修饰键
    {"ctrl", KT_KEY_LEFT_CTRL},
    {"control", KT_KEY_LEFT_CTRL},
    {"lctrl", KT_KEY_LEFT_CTRL},
    {"rctrl", KT_KEY_RIGHT_CTRL},
    {"shift", KT_KEY_LEFT_SHIFT},
    {"lshift", KT_KEY_LEFT_SHIFT},
    {"rshift", KT_KEY_RIGHT_SHIFT},
    {"alt", KT_KEY_LEFT_ALT},
    {"option", KT_KEY_LEFT_ALT},
    {"lalt", KT_KEY_LEFT_ALT},
    {"ralt", KT_KEY_RIGHT_ALT},
    {"cmd", KT_KEY_LEFT_GUI},
    {"command", KT_KEY_LEFT_GUI},
    {"gui", KT_KEY_LEFT_GUI},
    {"win", KT_KEY_LEFT_GUI},
    {"lwin", KT_KEY_LEFT_GUI},
    {"lgui", KT_KEY_LEFT_GUI},
    {"lcmd", KT_KEY_LEFT_GUI},
    {"rcmd", KT_KEY_RIGHT_GUI},
    {"rwin", KT_KEY_RIGHT_GUI},
    {"rgui", KT_KEY_RIGHT_GUI},
    // 编辑 / 导航
    {"enter", KT_KEY_RETURN},
    {"return", KT_KEY_RETURN},
    {"esc", KT_KEY_ESC},
    {"escape", KT_KEY_ESC},
    {"tab", KT_KEY_TAB},
    {"space", KT_KEY_SPACE},
    {"backspace", KT_KEY_BACKSPACE},
    {"delete", KT_KEY_DELETE},
    {"del", KT_KEY_DELETE},
    {"insert", KT_KEY_INSERT},
    {"ins", KT_KEY_INSERT},
    {"home", KT_KEY_HOME},
    {"end", KT_KEY_END},
    {"pageup", KT_KEY_PAGE_UP},
    {"pgup", KT_KEY_PAGE_UP},
    {"pagedown", KT_KEY_PAGE_DOWN},
    {"pgdn", KT_KEY_PAGE_DOWN},
    {"up", KT_KEY_UP_ARROW},
    {"down", KT_KEY_DOWN_ARROW},
    {"left", KT_KEY_LEFT_ARROW},
    {"right", KT_KEY_RIGHT_ARROW},
    {"capslock", KT_KEY_CAPS_LOCK},
    {"caps", KT_KEY_CAPS_LOCK},
    {"menu", KT_KEY_MENU},
    {"apps", KT_KEY_MENU},
    {"printscreen", KT_KEY_PRINT_SCREEN},
    {"scrolllock", KT_KEY_SCROLL_LOCK},
    {"pause", KT_KEY_PAUSE},
    {"numlock", KT_KEY_NUM_LOCK},
    // 小键盘符号
    {"kpenter", KT_KEY_KP_ENTER},
    {"kpplus", KT_KEY_KP_PLUS},
    {"kpminus", KT_KEY_KP_MINUS},
    {"kpslash", KT_KEY_KP_SLASH},
    {"kpasterisk", KT_KEY_KP_ASTERISK},
    {"kpdot", KT_KEY_KP_DOT},
};

static inline int kt_lc(int c) {
  return (c >= 'A' && c <= 'Z') ? c + 32 : c;
}

static inline bool kt_isspace(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

// 去掉首尾空白，原地调整指针和长度
static inline void kt_trim(const char **p, size_t *n) {
  while (*n > 0 && kt_isspace(**p)) {
    (*p)++;
    (*n)--;
  }
  while (*n > 0 && kt_isspace((*p)[*n - 1])) {
    (*n)--;
  }
}

// token 与 name 大小写不敏感比较；token 不要求以 '\0' 结尾
static inline bool kt_eq(const char *p, size_t n, const char *name) {
  size_t i = 0;
  for (; i < n; i++) {
    char a = name[i];
    if (a == '\0') {
      return false;
    }
    if (kt_lc((unsigned char)p[i]) != kt_lc((unsigned char)a)) {
      return false;
    }
  }
  return name[i] == '\0';
}

static inline int kt_resolve_key(const char *tok, size_t len) {
  const char *p = tok;
  size_t n = len;
  kt_trim(&p, &n);
  if (n == 0) {
    return -1;
  }
  // 单字符：交给库自己查 ASCII -> HID 表（它会自动补 Shift）
  if (n == 1) {
    return (int)(unsigned char)p[0];
  }

  // f1..f12
  if (kt_lc((unsigned char)p[0]) == 'f') {
    bool allDigits = true;
    for (size_t i = 1; i < n; i++) {
      if (p[i] < '0' || p[i] > '9') {
        allDigits = false;
        break;
      }
    }
    if (allDigits && n <= 4) {
      int idx = 0;
      for (size_t i = 1; i < n; i++) {
        idx = idx * 10 + (p[i] - '0');
      }
      // HID 里 F1..F12 是 usage 0x3A..0x45，F13..F24 是 0x68..0x73（中间有空档），
      // 所以不能线性推。KT 编码规则是 0x88 + usage，这里直接按 usage 算。
      if (idx >= 1 && idx <= 12) {
        return 0x88 + 0x3A + (idx - 1);
      }
      if (idx >= 13 && idx <= 24) {
        return 0x88 + 0x68 + (idx - 13);
      }
      return -1;
    }
  }

  // kp0..kp9（必须查表，编码不是连续的）
  if (n == 3 && kt_lc((unsigned char)p[0]) == 'k' && kt_lc((unsigned char)p[1]) == 'p' &&
      p[2] >= '0' && p[2] <= '9') {
    return KT_KP_DIGITS[p[2] - '0'];
  }

  for (size_t i = 0; i < sizeof(KT_NAMED_KEYS) / sizeof(KT_NAMED_KEYS[0]); i++) {
    if (kt_eq(p, n, KT_NAMED_KEYS[i].name)) {
      return KT_NAMED_KEYS[i].code;
    }
  }
  return -1;
}

// 多媒体键名 -> 码；找不到返回 0
static inline uint16_t kt_resolve_media(const char *arg, size_t len) {
  const char *p = arg;
  size_t n = len;
  kt_trim(&p, &n);
  if (n == 0) {
    return 0;
  }
  if (kt_eq(p, n, "volup") || kt_eq(p, n, "volumeup") || kt_eq(p, n, "volume_increment")) {
    return KT_MEDIA_VOLUME_INCREMENT;
  }
  if (kt_eq(p, n, "voldown") || kt_eq(p, n, "volumedown") || kt_eq(p, n, "volume_decrement")) {
    return KT_MEDIA_VOLUME_DECREMENT;
  }
  if (kt_eq(p, n, "mute")) {
    return KT_MEDIA_MUTE;
  }
  if (kt_eq(p, n, "playpause") || kt_eq(p, n, "play")) {
    return KT_MEDIA_PLAY_PAUSE;
  }
  if (kt_eq(p, n, "next") || kt_eq(p, n, "media_next")) {
    return KT_MEDIA_SCAN_NEXT;
  }
  if (kt_eq(p, n, "prev") || kt_eq(p, n, "media_prev")) {
    return KT_MEDIA_SCAN_PREVIOUS;
  }
  if (kt_eq(p, n, "brightnessup")) {
    return KT_MEDIA_BRIGHTNESS_INCREMENT;
  }
  if (kt_eq(p, n, "brightnessdown")) {
    return KT_MEDIA_BRIGHTNESS_DECREMENT;
  }
  return 0;
}

// 写错误信息（截断保护）
static inline void kt_err(char *err, size_t errLen, const char *prefix, const char *tok, size_t tokLen) {
  if (err == NULL || errLen == 0) {
    return;
  }
  size_t w = 0;
  for (const char *s = prefix; *s != '\0' && w + 1 < errLen; s++) {
    err[w++] = *s;
  }
  for (size_t i = 0; i < tokLen && w + 1 < errLen; i++) {
    err[w++] = tok[i];
  }
  err[w] = '\0';
}

// ---------------------------------------------------------------------------
// 解析一行协议。返回 false 表示这条命令无法执行（plan->action 为 KT_UNKNOWN）。
// err 里可能只有警告（部分组合键无效），此时仍返回 true。
// ---------------------------------------------------------------------------
static inline bool kt_parse(const char *line, KtPlan *plan, char *err, size_t errLen) {
  if (err != NULL && errLen > 0) {
    err[0] = '\0';
  }
  if (plan == NULL) {
    return false;
  }
  memset(plan, 0, sizeof(*plan));
  plan->action = KT_NONE;
  if (line == NULL) {
    return false;
  }

  const char *p = line;
  size_t n = strlen(line);
  kt_trim(&p, &n);
  if (n == 0) {
    return true;  // 空行，什么都不做
  }

  const char *colon = NULL;
  for (size_t i = 0; i < n; i++) {
    if (p[i] == ':') {
      colon = p + i;
      break;
    }
  }

  const char *cmd = p;
  size_t cmdLen = (colon != NULL) ? (size_t)(colon - p) : n;
  // 参数部分不 trim：TYPE 需要精确保留空格
  const char *arg = (colon != NULL) ? colon + 1 : (p + n);
  size_t argLen = (colon != NULL) ? (size_t)((p + n) - arg) : 0;

  kt_trim(&cmd, &cmdLen);

  if (kt_eq(cmd, cmdLen, "tap") || kt_eq(cmd, cmdLen, "down") || kt_eq(cmd, cmdLen, "up")) {
    int code = kt_resolve_key(arg, argLen);
    if (code < 0) {
      plan->action = KT_UNKNOWN;
      kt_err(err, errLen, "unknown key: ", arg, argLen);
      return false;
    }
    plan->key = (uint8_t)code;
    plan->action = kt_eq(cmd, cmdLen, "tap") ? KT_TAP
                   : kt_eq(cmd, cmdLen, "down") ? KT_DOWN
                                                : KT_UP;
    return true;
  }

  if (kt_eq(cmd, cmdLen, "type")) {
    plan->action = KT_TYPE;
    plan->text = arg;
    plan->textLen = argLen;
    return true;
  }

  if (kt_eq(cmd, cmdLen, "combo")) {
    size_t start = 0;
    while (start <= argLen) {
      size_t end = start;
      while (end < argLen && arg[end] != '+') {
        end++;
      }
      const char *tp = arg + start;
      size_t tn = end - start;
      kt_trim(&tp, &tn);
      if (tn > 0) {
        int code = kt_resolve_key(tp, tn);
        if (code < 0) {
          if (err != NULL && err[0] == '\0') {
            kt_err(err, errLen, "combo skip: ", tp, tn);
          }
        } else if (plan->keyCount < KT_MAX_COMBO) {
          plan->keys[plan->keyCount++] = (uint8_t)code;
        } else if (err != NULL && err[0] == '\0') {
          kt_err(err, errLen, "combo too long", "", 0);
        }
      }
      if (end >= argLen) {
        break;
      }
      start = end + 1;  // 跳过 '+'
    }
    if (plan->keyCount == 0) {
      plan->action = KT_UNKNOWN;
      if (err != NULL) {
        kt_err(err, errLen, "empty combo", "", 0);
      }
      return false;
    }
    plan->action = KT_COMBO;
    return true;
  }

  if (kt_eq(cmd, cmdLen, "media")) {
    uint16_t code = kt_resolve_media(arg, argLen);
    if (code == 0) {
      plan->action = KT_UNKNOWN;
      kt_err(err, errLen, "unknown media: ", arg, argLen);
      return false;
    }
    plan->media = code;
    plan->action = KT_MEDIA;
    return true;
  }

  if (kt_eq(cmd, cmdLen, "releaseall")) {
    plan->action = KT_RELEASEALL;
    return true;
  }

  if (kt_eq(cmd, cmdLen, "ping")) {
    plan->action = KT_PING;
    return true;
  }

  plan->action = KT_UNKNOWN;
  kt_err(err, errLen, "unknown command: ", cmd, cmdLen);
  return false;
}

// ============================ 键名映射结束 =================================

// ---------------------------- 用户配置 --------------------------------------
#define DEVICE_NAME "ESP32-Keyboard"   // Mac 端按这个名字搜索

// 自定义 GATT UUID（客户端必须一致）
static const char *SERVICE_UUID = "12345678-1234-5678-1234-56789abcdef0";
static const char *CHAR_RX_UUID = "12345678-1234-5678-1234-56789abcdef1";  // 写入命令
static const char *CHAR_TX_UUID = "12345678-1234-5678-1234-56789abcdef2";  // 通知/状态

// ---------------------------- 双链路配置 ------------------------------------
// 两种链路二选一，短按板载 BOOT 键切换（会断开当前连接），选择记在 NVS 里，掉电不丢：
//   BLE  : 蓝牙 GATT，客户端按设备名扫描连接（原来的方式）
//   WiFi : 板子开热点（AP），电脑连上热点后用 IP:端口 连进来
// 两种模式跑的是同一套文本协议（TAP:/TYPE:/COMBO:...），客户端只换传输层。
#define MODE_BUTTON_PIN 0               // 板载 BOOT 键（低电平有效）
#define AP_SSID         "ESP32-Keyboard"  // 热点名（和蓝牙设备名一致，方便记）
#define AP_PASS         "esp32keyboard"   // 热点密码，至少 8 位；写 "" 就是开放热点
#define TCP_PORT        8266              // 客户端连的端口

// 板载 RGB 灯（WS2812）。ESP32-S3-DevKitC-1 / DevKitM-1 是 GPIO48，
// 有些板子是 38 / 21 / 45——灯不亮就改这里。没有 RGB 灯就把 LED_USE_RGB 设 0。
#define LED_USE_RGB     1
#define LED_RGB_PIN     48

// 灯太亮刺眼时调这里：0~255 的满量程系数，255 = 全亮。
// WS2812 三个通道的亮度是线性的，三个通道乘同一个系数就不会偏色
// （蓝还是蓝，只是暗下去），所以下面那组语义颜色保持原值不动。
//   128 ≈ 50%（当前）    64 ≈ 25%    16 ≈ 6%    0 = 全灭
#define LED_BRIGHTNESS  128

// 状态灯颜色约定（与 README、客户端一致）：
//   BLE  未连接 = 蓝   连接成功 = 紫
//   WiFi 未连接 = 绿   连接成功 = 黄
static const uint8_t LED_BLE_IDLE[3]   = {0, 0, 150};
static const uint8_t LED_BLE_READY[3]  = {150, 0, 255};
static const uint8_t LED_WIFI_IDLE[3]  = {0, 170, 0};
static const uint8_t LED_WIFI_READY[3] = {255, 170, 0};

// 指令闪灯：每执行完一条协议命令白闪一下，闪几下由命令长度决定。
// 用途是「不看屏幕也知道命令进去了没有、这一条有多大」——尤其是手机端发长文本、
// 或者主机画面被全屏盖住的时候，灯是唯一还看得见的反馈。
//   1~8 字节    1 下   TAP:q / RELEASEALL
//   9~32 字节   2 下   MOUSE:click right / BOOTKEY:f2
//   33~128 字节 3 下   TYPE:hi there
//   129~512 字节 4 下  一句话
//   513~1024 字节 5 下 一段话
//   > 1024 字节 6 下   一次粘一大坨
// 白闪和蓝/紫/绿/黄四种状态色都不撞，闪的时候不会误认成链路状态变了。
// PING 心跳不闪（客户端每 10 秒一次，闪起来像故障）；MOUSE:move / MOUSE:wheel 也不闪，
// 那是 30Hz 攒批发的流，同样会闪成坏灯。想彻底关掉就把 LED_CMD_FLASH 设 0。
#define LED_CMD_FLASH       1
#define LED_CMD_ON_MS       45     // 每下亮多久
#define LED_CMD_GAP_MS      55     // 两下之间灭多久（灭的时候露出链路底色，闪起来才像「闪」）
#define LED_CMD_MAX_BLINKS  6      // 一次最多连闪几下，长文本别闪成迪斯科
static const uint8_t LED_CMD_COLOR[3] = {255, 255, 255};

// 按键保持时间。
// USB HID 键盘一般 8~10ms 轮询一次，Windows 收到 15ms 的按下-抬起没问题；
// 但 BIOS/UEFI 的轮询更慢（有的到 16ms），太短会整次按键都采不到，
// 所以单键保持在 24ms，BIOS 引导键用更长的 80ms。
static const uint16_t KEY_HOLD_MS = 24;
static const uint16_t TYPE_HOLD_MS = 10;
static const uint16_t TYPE_GAP_MS  = 5;
// 组合键：按下每键之间的间隔、全部按下后的停留、松开每键之间的间隔。
// Windows 的输入法热键（Ctrl+Space / Win+Space）对过短的组合不敏感，这里给足。
static const uint16_t COMBO_GAP_MS  = 10;
static const uint16_t COMBO_HOLD_MS = 40;

// ---------------------------- 开机引导键 ------------------------------------
// 用途：主机开机自检时 BLE/WiFi 一条都还没连上，客户端根本发不出按键，
//       于是「按 Del / F2 进 BIOS」永远差那 1~2 秒的窗口。
//       固件自己在 USB 枚举完成后连发这个键，完全不依赖链路。
// 配置方式：
//   · 改这里的 BOOTKEY_DEFAULT（默认 delete，也就是 BIOS 里那个 Del）
//   · 或者发 BOOTKEY:f2 / BOOTKEY:off 命令，会写进 NVS，掉电保持
//   · BOOTKEY:now 立即重来一轮（客户端上的「立即连发」）
//   · BOOTKEY:window <ms> / BOOTKEY:gap <ms> 改连发时长和间隔，同样写 NVS
//     （客户端上那两个输入框就是发这个；下面两个宏只是出厂默认值）
#define BOOTKEY_DEFAULT     KT_KEY_DELETE
#define BOOTKEY_ENABLED     1
#define BOOTKEY_HOLD_MS     80      // 单次按下保持，给 UEFI 的慢轮询留余量
#define BOOTKEY_GAP_MS      220     // 两次连发之间的默认间隔
#define BOOTKEY_WINDOW_MS   10000   // 开机后连发多久的默认值（覆盖 POST 的 "按 Del 进设置" 窗口）
#define BOOTKEY_START_MS    1500    // 上电后等 USB 枚举完成再开始

// 运行时可调范围。给上下限是为了挡住手抖和脚本 bug：
// 窗口 1~60 秒、间隔 60~5000ms；间隔再小会变成一直按着不放，
// 主机那边反而采不到；再大就错过 POST 窗口了。
#define BOOTKEY_WINDOW_MIN_MS   1000
#define BOOTKEY_WINDOW_MAX_MS   60000
#define BOOTKEY_GAP_MIN_MS      60
#define BOOTKEY_GAP_MAX_MS      5000
// 只在上电（冷启动）时连发。重新烧录、按板子上的复位键都不触发，
// 免得连着正在跑的 Windows 时突然刷一串 Del 把人家文档删了。
// 判断依据是 esp_reset_reason()：只有真断电再来电才是 ESP_RST_POWERON。

// ---------------------------- 编译期检查 ------------------------------------
// 说明：esp32 核心的板卡菜单里 USB Mode 有两档，对应编译宏 ARDUINO_USB_MODE：
//   'USB-OTG (TinyUSB)'      -> usb_mode=0，ARDUINO_USB_MODE=0，有 TinyUSB，能出 HID
//   'Hardware CDC and JTAG'  -> usb_mode=1，ARDUINO_USB_MODE=1，USB 口只做硬件串口，
//                               没有 TinyUSB 栈，USBHIDKeyboard 根本链接不出来
// 所以这档必须报错停下，不能让它编到链接阶段再抛一堆看不懂的 undefined reference。
#if defined(ARDUINO_USB_MODE) && (ARDUINO_USB_MODE == 1)
#error "USB Mode 现在是 'Hardware CDC and JTAG'：这档只把 USB 口当硬件串口用，没有 TinyUSB 栈，USB HID 出不来。改法：工具 -> USB Mode -> 'USB-OTG (TinyUSB)'。注意 ESP32S3 Dev Module 的默认值就是 Hardware CDC，必须手动改一次。想看串口日志再单独把 工具 -> USB CDC On Boot 设为 Enabled（两项互不影响）。"
#endif

#ifndef CONFIG_TINYUSB_HID_ENABLED
#error "没编进 TinyUSB HID。确认 工具 -> 开发板 选的是 ESP32S3 Dev Module，且 工具 -> USB Mode 是 'USB-OTG (TinyUSB)'。"
#endif

// 上面第一部分里的 KT_KEY_* 是独立定义的键码表（不依赖 Arduino 头文件），
// 这里用编译期断言把它和库里的 KEY_* 钉在一起：核心库哪天改了编码，编译就会失败。
static_assert(KT_KEY_LEFT_CTRL == KEY_LEFT_CTRL, "键码不一致: ctrl");
static_assert(KT_KEY_LEFT_GUI == KEY_LEFT_GUI, "键码不一致: cmd");
static_assert(KT_KEY_RETURN == KEY_RETURN, "键码不一致: enter");
static_assert(KT_KEY_ESC == KEY_ESC, "键码不一致: esc");
static_assert(KT_KEY_F1 == KEY_F1, "键码不一致: f1");
static_assert(KT_KEY_F12 == KEY_F12, "键码不一致: f12");
static_assert(KT_KEY_KP_0 == KEY_KP_0, "键码不一致: kp0");
static_assert(KT_KEY_KP_1 == KEY_KP_1, "键码不一致: kp1");
static_assert(KT_KEY_UP_ARROW == KEY_UP_ARROW, "键码不一致: up");
static_assert(KT_MEDIA_VOLUME_INCREMENT == CONSUMER_CONTROL_VOLUME_INCREMENT, "多媒体键码不一致");

// ---------------------------- 全局对象 --------------------------------------
// 三个 HID 设备共用一个 USB HID 接口，靠 report ID 区分
// （键盘 = 1，鼠标 = 2，多媒体 = 4，见 USBHID.h 的 HID_REPORT_ID_*）。
// 主机那边会看到「键盘 + 鼠标」两个 HID 集合，插一根线两样都能用。
USBHIDKeyboard Keyboard;
USBHIDConsumerControl Consumer;
USBHIDMouse Mouse;

// 当前链路模式
enum LinkMode : uint8_t { MODE_BLE = 0, MODE_WIFI = 1 };
LinkMode linkMode = MODE_BLE;
Preferences prefs;

BLEServer *pServer = nullptr;
BLECharacteristic *pTx = nullptr;

// WiFi 侧：AP 模式的热点 + 一个 TCP 服务端（只服务一个客户端）
WiFiServer *tcpServer = nullptr;
WiFiClient tcpClient;
String tcpRxLine;

// 「有客户端连上」的统一标志，两种模式共用
volatile bool deviceConnected = false;
volatile bool wasConnected = false;
volatile bool pendingReleaseAll = false;

// BLE 回调 / WiFi 收包都跑在别的任务里，命令统一丢进队列，由 loop() 执行，
// 避免在这些上下文里直接操作 USB，也避免长文本阻塞协议栈。
std::deque<String> cmdQueue;
SemaphoreHandle_t queueMutex = nullptr;

String rxLine;  // BLE 的收包缓冲，只在 BLE 任务中访问

// ---------------------------- 状态灯 ----------------------------------------
static uint8_t ledLast[3] = {255, 255, 255};
static uint8_t ledBase[3] = {0, 0, 0};      // 链路状态色，指令闪灯熄灭时回落到这里
static const uint8_t LED_OFF[3] = {0, 0, 0};  // 全灭

// 按 LED_BRIGHTNESS 缩放单个通道（四舍五入）。
// 所有真正写灯的地方都过一遍这里，改亮度只要改上面那一个宏。
static inline uint8_t ledDim(uint8_t v) {
  return (uint8_t)(((uint16_t)v * (uint16_t)LED_BRIGHTNESS + 127) / 255);
}

static void ledSet(const uint8_t c[3]) {
#if LED_USE_RGB
  if (c[0] == ledLast[0] && c[1] == ledLast[1] && c[2] == ledLast[2]) {
    return;  // 颜色没变就不重复刷，避免每帧都占用 RMT
  }
  ledLast[0] = c[0];
  ledLast[1] = c[1];
  ledLast[2] = c[2];
  // 去重比较用的是语义色（未缩放），写灯时再乘亮度系数
  rgbLedWrite(LED_RGB_PIN, ledDim(c[0]), ledDim(c[1]), ledDim(c[2]));
#else
  (void)c;
#endif
}

// ---- 指令闪灯（非阻塞状态机）-----------------------------------------------
// 为什么不直接在 processCommand 里 delay 着闪：那条路径上有大段 delay（按键保持
// 24ms、逐字输入的字间隔、鼠标 click 的 40ms、连发引导键的 220ms），在里面再
// 阻塞闪灯，命令会越排越后，鼠标都会变卡。所以只在这里改状态，由 loop() 每
// 2ms 调一次 ledFlashTick() 推进。
static uint8_t  flashLeft = 0;   // 还要闪几下（当前正亮着的那一下算在内）
static bool     flashLit  = false;
static uint32_t flashAt   = 0;   // 下一次切换颜色的时刻

static inline bool ledFlashActive() {
  return flashLit || flashLeft > 0;
}

// 命令长度 -> 闪烁次数
static inline uint8_t ledFlashBlinks(size_t bytes) {
  if (bytes > 1024) return 6;
  if (bytes > 512)  return 5;
  if (bytes > 128)  return 4;
  if (bytes > 32)   return 3;
  if (bytes > 8)    return 2;
  return 1;
}

// 每执行完一条命令调用一次。连续来的命令不打断当前这一下，而是往后排队
// （有 LED_CMD_MAX_BLINKS 上限），所以按住方向键连发时看到的是「有节奏地一直闪」，
// 而不是被压成常亮或者闪得看不清。
static void ledFlashCommand(size_t bytes) {
#if LED_CMD_FLASH && LED_USE_RGB
  uint16_t want = (uint16_t)flashLeft + (uint16_t)ledFlashBlinks(bytes);
  flashLeft = (want > LED_CMD_MAX_BLINKS) ? (uint8_t)LED_CMD_MAX_BLINKS : (uint8_t)want;
  if (!flashLit) {
    flashLit = true;
    flashAt = millis() + LED_CMD_ON_MS;
    ledSet(LED_CMD_COLOR);
  }
#else
  (void)bytes;
#endif
}

// 推进闪灯。必须在 loop() 里勤着调，但也别在 delay 里调（会跟主循环抢时序）。
static void ledFlashTick() {
#if LED_CMD_FLASH && LED_USE_RGB
  if (!ledFlashActive()) {
    return;
  }
  uint32_t now = millis();
  // 用有符号差值比较，millis() 49 天回绕也不会卡死
  if ((int32_t)(now - flashAt) < 0) {
    return;  // 还没到切换点
  }

  if (flashLit) {
    flashLit = false;
    if (flashLeft > 0) {
      flashLeft--;
    }
    if (flashLeft == 0) {
      ledSet(ledBase);  // 闪完了，回到底色
    } else {
      ledSet(LED_OFF);  // 灭一下，这一明一暗才算「闪」
      flashAt = now + LED_CMD_GAP_MS;
    }
  } else {
    flashLit = true;
    ledSet(LED_CMD_COLOR);
    flashAt = now + LED_CMD_ON_MS;
  }
#endif
}

// 蓝/紫 = 蓝牙模式，绿/黄 = WiFi 模式，亮/暗（紫、黄）= 未连接/已连接
// 这里只更新「底色」：正在闪灯时不抢写，等闪完由 ledFlashTick() 自己回到底色。
static void ledRefresh() {
  const uint8_t *want = (linkMode == MODE_BLE)
                            ? (deviceConnected ? LED_BLE_READY : LED_BLE_IDLE)
                            : (deviceConnected ? LED_WIFI_READY : LED_WIFI_IDLE);
  memcpy(ledBase, want, 3);
  if (!ledFlashActive()) {
    ledSet(ledBase);
  }
}

// 启动自检：红、绿、蓝各亮一下，确认板子真的有 RGB 灯
static void ledSelfTest() {
#if LED_USE_RGB
  const uint8_t r[3] = {60, 0, 0}, g[3] = {0, 60, 0}, b[3] = {0, 0, 60};
  ledSet(r); delay(220);
  ledSet(g); delay(220);
  ledSet(b); delay(220);
  ledLast[0] = 255;  // 强制下一次刷新生效
#endif
}

// 主机下发回来的 LED 状态（键盘上那三颗小灯）。
// 真键盘会跟着主机同步 NumLock/CapsLock/ScrollLock，我们这里只记录，供回执上报。
volatile uint8_t hostLeds = 0;

static void onHostLedEvent(void *arg, esp_event_base_t base, int32_t id, void *data) {
  if (id == ARDUINO_USB_HID_KEYBOARD_LED_EVENT && data != nullptr) {
    hostLeds = ((arduino_usb_hid_keyboard_event_data_t *)data)->leds;
  }
}

// ---------------------------- 按键动作 --------------------------------------
// KT_* 键码用的是 Arduino 的编码约定：
//   0x80..0x87 -> 8 个修饰键     >= 0x88 -> 非打印键（键值 = 0x88 + HID usage）
//   < 0x80     -> ASCII，交给库自己查表（大写/符号会自动补 Shift）
// 前两类我们直接算成 HID usage 走 pressRaw/releaseRaw，避开 press()/release() 的
// 一个副作用：release() 遇到大写字母或符号会把左 Shift 位一起清掉。
// 客户端现在会单独发 DOWN:shift / UP:shift，如果还走 press()/release()，
// 松开任意一个需要 Shift 的字符就会把用户正按着的 Shift 吃掉。
static inline bool kt_is_modifier(uint8_t code) {
  return code >= 0x80 && code < 0x88;
}

static inline uint8_t kt_usage(uint8_t code) {
  return (code >= 0x88) ? (uint8_t)(code - 0x88) : (uint8_t)(0xE0 + (code - 0x80));
}

static void hwPress(uint8_t code) {
  if (code >= 0x80) {
    Keyboard.pressRaw(kt_usage(code));
  } else if (code != 0) {
    Keyboard.press(code);
  }
}

static void hwRelease(uint8_t code) {
  if (code >= 0x80) {
    Keyboard.releaseRaw(kt_usage(code));
  } else if (code != 0) {
    Keyboard.release(code);
  }
}

static void tapCode(uint8_t code, uint16_t holdMs) {
  if (code == 0) {
    return;
  }
  hwPress(code);
  delay(holdMs);
  hwRelease(code);
}

// TYPE:hello world  -> 逐字符输入，\n / \t 转成回车 / Tab
static void typeText(const char *text, size_t len) {
  for (size_t i = 0; i < len; i++) {
    uint8_t c = (uint8_t)text[i];
    if (c == '\n' || c == '\r') {
      tapCode(KEY_RETURN, TYPE_HOLD_MS);
    } else if (c == '\t') {
      tapCode(KEY_TAB, TYPE_HOLD_MS);
    } else if (c >= 0x20 && c < 0x7F) {
      tapCode(c, TYPE_HOLD_MS);
    }
    // 非 ASCII（中文等）直接跳过：HID 只发键位，汉字要靠主机输入法
    delay(TYPE_GAP_MS);
  }
}

// COMBO:cmd+shift+4 -> 按顺序按下，再逆序松开
static void doCombo(const KtPlan &plan) {
  if (plan.keyCount == 0) {
    return;
  }
  // 修饰键必须先进报告、后进键码，主机才认成组合键（真实键盘也是这个顺序）。
  // 客户端拼 COMBO 时已经把修饰键排前面了，这里再稳一点：先按修饰键，停一下，
  // 再按普通键，最后统一逆序松开。
  uint8_t mods[8];
  uint8_t normal[KT_MAX_COMBO];
  uint8_t modCount = 0, normalCount = 0;
  for (uint8_t i = 0; i < plan.keyCount; i++) {
    uint8_t k = plan.keys[i];
    if (kt_is_modifier(k)) {
      if (modCount < 8) {
        mods[modCount++] = k;
      }
    } else if (normalCount < KT_MAX_COMBO) {
      normal[normalCount++] = k;
    }
  }

  for (uint8_t i = 0; i < modCount; i++) {
    hwPress(mods[i]);
    delay(COMBO_GAP_MS);
  }
  for (uint8_t i = 0; i < normalCount; i++) {
    hwPress(normal[i]);
    delay(COMBO_GAP_MS);
  }
  delay(COMBO_HOLD_MS);
  for (int i = (int)normalCount - 1; i >= 0; i--) {
    hwRelease(normal[i]);
    delay(COMBO_GAP_MS);
  }
  for (int i = (int)modCount - 1; i >= 0; i--) {
    hwRelease(mods[i]);
    delay(COMBO_GAP_MS);
  }
}

// MEDIA:volup / voldown / mute / playpause / next / prev / brightnessup ...
static void doMedia(uint16_t code) {
  if (code == 0) {
    return;
  }
  Consumer.press(code);
  delay(25);
  Consumer.release();
}

// ---------------------------- 开机引导键 ------------------------------------
// 见文件顶部 BOOTKEY_* 的说明：这一段让固件在没有任何链路的情况下自己敲键，
// 解决「开机时按 F2 / Del 进 BIOS」的时序问题。
static uint8_t bootKeyCode = BOOTKEY_ENABLED ? (uint8_t)BOOTKEY_DEFAULT : 0;
static uint32_t bootKeyNextAt = 0;   // 下一次该按的时间点
static uint32_t bootKeyEndAt = 0;    // 连发窗口的截止时间，0 表示没在跑

// 连发时长 / 间隔：出厂用宏，客户端可以改（存 NVS，掉电保持）
static uint16_t bootKeyWindowMs = BOOTKEY_WINDOW_MS;
static uint16_t bootKeyGapMs = BOOTKEY_GAP_MS;

static uint16_t bootKeyClampWindow(long v) {
  if (v < BOOTKEY_WINDOW_MIN_MS) return BOOTKEY_WINDOW_MIN_MS;
  if (v > BOOTKEY_WINDOW_MAX_MS) return BOOTKEY_WINDOW_MAX_MS;
  return (uint16_t)v;
}

static uint16_t bootKeyClampGap(long v) {
  if (v < BOOTKEY_GAP_MIN_MS) return BOOTKEY_GAP_MIN_MS;
  if (v > BOOTKEY_GAP_MAX_MS) return BOOTKEY_GAP_MAX_MS;
  return (uint16_t)v;
}

static void bootKeyBeginWindow(uint32_t windowMs) {
  if (bootKeyCode == 0) {
    bootKeyEndAt = 0;
    return;
  }
  bootKeyNextAt = millis() + BOOTKEY_START_MS;
  bootKeyEndAt = bootKeyNextAt + windowMs;
}

static void bootKeyStop() {
  bootKeyEndAt = 0;
}

// 前置声明：下面恢复/保存要打日志，用到 bootKeyName()
static const char *bootKeyName();

// 把引导键写进 NVS，写完立刻回读比对。
//
// 为什么要这么较真：NVS 写失败（分区满、只读、掉电时序）在串口里几乎看不出来，
// 表现却是最难查的那种——「设了关闭，下次开机照样敲键」。与其让用户对着界面
// 猜，不如写完就验一次，不一致直接把话挑明。
static bool bootKeySaveCode(uint8_t code) {
  prefs.begin("kbd", false);
  prefs.putUChar("bootkey", code);
  uint8_t back = prefs.getUChar("bootkey", 0xFF);
  prefs.end();
  return back == code;
}

// 开机从 NVS 恢复引导键设置。
//
// isKey 用来区分「从没设置过」和「设置成关闭（0）」：前者按出厂宏走 delete，
// 后者是真的关掉，开机一下都不许敲。这两件事一旦混在一起（比如用 -1 当默认值），
// 就会出现「关了还在敲」或者「没设过却不敲」。顺手把时长/间隔也夹一次范围，
// 万一 NVS 里是脏值，别让连发跑飞。
static void bootKeyLoadSaved() {
  prefs.begin("kbd", true);
  bool hasBoot = prefs.isKey("bootkey");
  uint8_t savedBoot = hasBoot ? prefs.getUChar("bootkey", 0) : 0;
  uint16_t savedWin = prefs.getUShort("bkwin", BOOTKEY_WINDOW_MS);
  uint16_t savedGap = prefs.getUShort("bkgap", BOOTKEY_GAP_MS);
  prefs.end();

  if (hasBoot) {
    bootKeyCode = savedBoot;
  } else {
    bootKeyCode = BOOTKEY_ENABLED ? (uint8_t)BOOTKEY_DEFAULT : 0;
  }
  bootKeyWindowMs = bootKeyClampWindow(savedWin);
  bootKeyGapMs = bootKeyClampGap(savedGap);

  Serial.printf("[BOOTKEY] NVS 恢复：%s（%s），时长 %u ms、间隔 %u ms\n",
                bootKeyName(), hasBoot ? "有记录" : "没记录，用出厂默认",
                (unsigned)bootKeyWindowMs, (unsigned)bootKeyGapMs);
}

// 返回当前引导键的名字，用于回执
static const char *bootKeyName() {
  if (bootKeyCode == 0) {
    return "off";
  }
  for (size_t i = 0; i < sizeof(KT_NAMED_KEYS) / sizeof(KT_NAMED_KEYS[0]); i++) {
    if (KT_NAMED_KEYS[i].code == bootKeyCode) {
      return KT_NAMED_KEYS[i].name;
    }
  }
  return "?";
}

static void serviceBootKey() {
  if (bootKeyEndAt == 0 || bootKeyCode == 0) {
    return;
  }
  uint32_t now = millis();
  if ((int32_t)(now - bootKeyEndAt) >= 0) {
    bootKeyEndAt = 0;
    Serial.println("[BOOTKEY] 连发窗口结束");
    return;
  }
  if ((int32_t)(now - bootKeyNextAt) < 0) {
    return;
  }
  bootKeyNextAt = now + bootKeyGapMs;
  tapCode(bootKeyCode, BOOTKEY_HOLD_MS);
}

// ---------------------------- 命令分发 --------------------------------------
// 回执统一出口：BLE 走 notify，WiFi 走 TCP 写。客户端两边都能看到同样的文本。
static void notifyHost(const String &msg) {
  if (linkMode == MODE_BLE) {
    if (!deviceConnected || pTx == nullptr) {
      return;
    }
    pTx->setValue(msg);
    pTx->notify();
  } else {
    if (tcpClient && tcpClient.connected()) {
      tcpClient.println(msg);
    }
  }
}

// 引导键的完整状态回执。为什么单独一条而不是塞进 BOOTKEY:：
// 老客户端把 "BOOTKEY:" 后面整段都当键名（Flutter / Python 都是这么解析的），
// 多几个字段就会显示成乱码。所以另开一条 BOOTCFG:，老客户端只会把它当未知回执。
//   BOOTCFG:key=delete,win=10000,gap=220,hold=80
static void notifyBootCfg() {
  String msg = String("BOOTCFG:key=") + bootKeyName() +
               ",win=" + String((unsigned)bootKeyWindowMs) +
               ",gap=" + String((unsigned)bootKeyGapMs) +
               ",hold=" + String((unsigned)BOOTKEY_HOLD_MS);
  notifyHost(msg);
}

// 把一行协议文本塞进执行队列（BLE 回调、WiFi 收包共用）
static void pushCommand(const String &line) {
  if (line.length() == 0) {
    return;
  }
  if (queueMutex == nullptr) {
    return;
  }
  xSemaphoreTake(queueMutex, portMAX_DELAY);
  if (cmdQueue.size() < 256) {
    cmdQueue.push_back(line);
  }
  xSemaphoreGive(queueMutex);
}

// BOOTKEY / BOOTKEY?              查询（回 BOOTKEY:<键> + BOOTCFG: 完整参数）
// BOOTKEY:off                     关掉开机连发
// BOOTKEY:delete / f2 / f10 …     设置并写入 NVS（掉电保持）
// BOOTKEY:now [win] [gap]         立刻重来一轮；可顺手带上新参数
// BOOTKEY:window <ms>             连发时长（1000~60000），写 NVS
// BOOTKEY:gap <ms>                连发间隔（60~5000），写 NVS
//
// 参数两种写法都收：`BOOTKEY:window 8000` 和 `BOOTKEY:window=8000`。
static void handleBootKeyCommand(const String &line) {
  String arg = line.substring(7);
  if (arg.startsWith(":")) {
    arg = arg.substring(1);
  }
  arg.trim();

  // 拆出「动词 + 参数」：动词之后可能跟空格，也可能跟等号
  String verb = arg;
  String rest;
  int sep = -1;
  for (size_t i = 0; i < arg.length(); i++) {
    char ch = arg[i];
    if (ch == ' ' || ch == '=') {
      sep = (int)i;
      break;
    }
  }
  if (sep >= 0) {
    verb = arg.substring(0, (unsigned)sep);
    rest = arg.substring((unsigned)sep + 1);
    rest.trim();
  }

  if (verb.length() == 0 || verb == "?") {
    notifyHost(String("BOOTKEY:") + bootKeyName());
    notifyBootCfg();
    return;
  }

  // ---- 连发参数 ----
  if (kt_eq(verb.c_str(), verb.length(), "window") || kt_eq(verb.c_str(), verb.length(), "win") ||
      kt_eq(verb.c_str(), verb.length(), "duration")) {
    if (rest.length() == 0) {
      notifyBootCfg();
      return;
    }
    uint16_t want = bootKeyClampWindow(rest.toInt());
    bootKeyWindowMs = want;
    prefs.begin("kbd", false);
    prefs.putUShort("bkwin", want);
    prefs.end();
    Serial.printf("[BOOTKEY] 连发时长 %u ms\n", (unsigned)want);
    notifyBootCfg();
    return;
  }

  if (kt_eq(verb.c_str(), verb.length(), "gap") || kt_eq(verb.c_str(), verb.length(), "interval")) {
    if (rest.length() == 0) {
      notifyBootCfg();
      return;
    }
    uint16_t want = bootKeyClampGap(rest.toInt());
    bootKeyGapMs = want;
    prefs.begin("kbd", false);
    prefs.putUShort("bkgap", want);
    prefs.end();
    Serial.printf("[BOOTKEY] 连发间隔 %u ms\n", (unsigned)want);
    notifyBootCfg();
    return;
  }

  // ---- 立即连发：可以带 `now 8000 200` 顺手改参数 ----
  if (kt_eq(verb.c_str(), verb.length(), "now")) {
    if (rest.length() > 0) {
      int sp = rest.indexOf(' ');
      String w = sp < 0 ? rest : rest.substring(0, (unsigned)sp);
      String g = sp < 0 ? String() : rest.substring((unsigned)sp + 1);
      w.trim();
      g.trim();
      prefs.begin("kbd", false);
      if (w.length() > 0) {
        bootKeyWindowMs = bootKeyClampWindow(w.toInt());
        prefs.putUShort("bkwin", bootKeyWindowMs);
      }
      if (g.length() > 0) {
        bootKeyGapMs = bootKeyClampGap(g.toInt());
        prefs.putUShort("bkgap", bootKeyGapMs);
      }
      prefs.end();
    }
    bootKeyBeginWindow(bootKeyWindowMs);
    Serial.printf("[BOOTKEY] 立即连发 %s，时长 %u ms、间隔 %u ms\n", bootKeyName(),
                  (unsigned)bootKeyWindowMs, (unsigned)bootKeyGapMs);
    notifyHost(String("BOOTKEY:") + bootKeyName());
    notifyBootCfg();
    return;
  }

  if (kt_eq(arg.c_str(), arg.length(), "off") || kt_eq(arg.c_str(), arg.length(), "none") ||
      kt_eq(arg.c_str(), arg.length(), "0")) {
    bootKeyCode = 0;
    bootKeyStop();
    bool saved = bootKeySaveCode(0);
    Serial.printf("[BOOTKEY] 已关闭（NVS %s）\n", saved ? "已保存" : "写入失败");
    if (!saved) {
      notifyHost("[WARN] 引导键没写进 NVS（分区满或只读），重启后可能还会连发");
    }
    notifyHost("BOOTKEY:off");
    notifyBootCfg();
    return;
  }

  int code = kt_resolve_key(arg.c_str(), arg.length());
  if (code < 0) {
    notifyHost(String("BOOTKEY-ERR:") + arg);
    return;
  }
  bootKeyCode = (uint8_t)code;
  bool saved = bootKeySaveCode(bootKeyCode);
  bootKeyBeginWindow(bootKeyWindowMs);
  Serial.printf("[BOOTKEY] 设为 %s（NVS %s）\n", bootKeyName(),
                saved ? "已保存" : "写入失败");
  if (!saved) {
    notifyHost("[WARN] 引导键没写进 NVS（分区满或只读），重启后可能回到旧设置");
  }
  notifyHost(String("BOOTKEY:") + bootKeyName());
  notifyBootCfg();
}

// ---------------------------- 鼠标 ------------------------------------------
// 命令（和按键命令并列，都走同一行协议）：
//   MOUSE:move  <dx> <dy>                相对位移；单次 ±127（HID 相对报告是 int8），
//                                        超了客户端自己拆成多条，固件也会夹一次
//   MOUSE:wheel <n>                      滚轮，正数 = 向上，一格约 3
//   MOUSE:down  <left|right|middle>      按下（要配合拖拽做框选时用）
//   MOUSE:up    <left|right|middle>      松开
//   MOUSE:click <left|right|middle>      固件自己按下 40ms 再松开
//   MOUSE:release                        松开全部（切模式 / 掉线 / 停捕获时兜底）
//
// 注意：USBHIDRelativeMouse 的 press/release 只在状态真的变化时才发报文，
// 所以「按下不动 5 秒」不会持续刷 USB，主机那边看到的是「一直按着」。
static uint8_t mouseHeld = 0;  // 当前按着的按钮位图，用来兜底松开
#define MOUSE_CLICK_MS 40      // 主机按 10ms 轮询，按住太短会整个 click 都采不到

static uint8_t mouseButton(const String &name) {
  const char *p = name.c_str();
  size_t n = name.length();
  if (kt_eq(p, n, "left") || kt_eq(p, n, "l") || kt_eq(p, n, "1")) {
    return MOUSE_LEFT;
  }
  if (kt_eq(p, n, "right") || kt_eq(p, n, "r") || kt_eq(p, n, "2")) {
    return MOUSE_RIGHT;
  }
  if (kt_eq(p, n, "middle") || kt_eq(p, n, "m") || kt_eq(p, n, "center")) {
    return MOUSE_MIDDLE;
  }
  return 0;
}

// HID 相对鼠标的 dx/dy/wheel 都是 int8，超范围会翻符号（+200 变成 -56）
static inline int8_t mouseClamp(long v) {
  if (v > 127) return 127;
  if (v < -127) return -127;
  return (int8_t)v;
}

static void mouseReleaseAll() {
  if (mouseHeld != 0) {
    Mouse.release(MOUSE_ALL);
    mouseHeld = 0;
  }
}

static void handleMouseCommand(const String &line) {
  String arg = line.substring(6);  // 去掉 "MOUSE:"
  arg.trim();

  int sp = arg.indexOf(' ');
  String verb = sp < 0 ? arg : arg.substring(0, sp);
  String rest = sp < 0 ? String() : arg.substring(sp + 1);
  rest.trim();

  const char *v = verb.c_str();
  size_t vl = verb.length();

  if (kt_eq(v, vl, "move") || kt_eq(v, vl, "m")) {
    int sp2 = rest.indexOf(' ');
    long dx = (sp2 < 0 ? rest : rest.substring(0, sp2)).toInt();
    long dy = sp2 < 0 ? 0 : rest.substring(sp2 + 1).toInt();
    if (dx == 0 && dy == 0) {
      return;
    }
    Mouse.move(mouseClamp(dx), mouseClamp(dy));
    return;
  }

  if (kt_eq(v, vl, "wheel") || kt_eq(v, vl, "scroll")) {
    long n = rest.toInt();
    if (n != 0) {
      Mouse.move(0, 0, mouseClamp(n));
    }
    return;
  }

  if (kt_eq(v, vl, "down")) {
    uint8_t b = mouseButton(rest);
    if (b) {
      mouseHeld |= b;
      Mouse.press(b);
      ledFlashCommand(line.length());  // 鼠标键也闪：盲操时能确认「按下去了」
    }
    return;
  }

  if (kt_eq(v, vl, "up")) {
    uint8_t b = mouseButton(rest);
    if (b) {
      mouseHeld &= (uint8_t)~b;
      Mouse.release(b);
      ledFlashCommand(line.length());
    }
    return;
  }

  if (kt_eq(v, vl, "click")) {
    uint8_t b = mouseButton(rest);
    if (b) {
      Mouse.press(b);
      delay(MOUSE_CLICK_MS);
      Mouse.release(b);
      ledFlashCommand(line.length());
    }
    return;
  }

  if (kt_eq(v, vl, "release") || kt_eq(v, vl, "releaseall")) {
    mouseReleaseAll();
    ledFlashCommand(line.length());
    return;
  }

  Serial.printf("[warn] 未知鼠标命令: %s\n", line.c_str());
}

static void processCommand(const String &line) {
  KtPlan plan;
  char err[64];

  // 有命令进来 = 主机已经在跑系统、用户正拿着客户端操作，
  // 这时不该再往主机里灌引导键（否则等于持续按 Del）。
  bootKeyStop();

  // BOOTKEY 不属于按键协议（它改的是固件自己的配置），先截下来自己处理
  if (line.length() >= 7 && kt_eq(line.c_str(), 7, "bootkey")) {
    handleBootKeyCommand(line);
    ledFlashCommand(line.length());
    return;
  }

  // 鼠标命令同理：它不是键码，走自己的解析（前缀 6 个字符 "MOUSE:"）
  // 位移/滚轮不做指令闪灯（客户端 30Hz 攒批发，闪起来像坏灯），
  // 只有按下/松开/单击/全松这种「一下是一下」的按键事件才闪，见 handleMouseCommand。
  if (line.length() >= 6 && kt_eq(line.c_str(), 6, "mouse:")) {
    handleMouseCommand(line);
    return;
  }

  bool ok = kt_parse(line.c_str(), &plan, err, sizeof(err));
  if (err[0] != '\0') {
    // 可能只是「组合键里有无效键」的警告，仍然会执行有效的部分
    Serial.printf("[warn] %s\n", err);
  }
  if (!ok) {
    Serial.printf("[warn] 丢弃命令: %s\n", line.c_str());
    return;
  }

  switch (plan.action) {
    case KT_TAP:
      tapCode(plan.key, KEY_HOLD_MS);
      break;
    case KT_DOWN:
      hwPress(plan.key);
      break;
    case KT_UP:
      hwRelease(plan.key);
      break;
    case KT_TYPE:
      typeText(plan.text, plan.textLen);
      break;
    case KT_COMBO:
      doCombo(plan);
      break;
    case KT_MEDIA:
      doMedia(plan.media);
      break;
    case KT_RELEASEALL:
      Keyboard.releaseAll();
      mouseReleaseAll();  // 鼠标键也一起松，否则主机会留一个「一直按着左键」
      break;
    case KT_PING:
      // 回执带上主机的 LED 状态，客户端可以显示 NumLock/CapsLock
      notifyHost(String("PONG:") + String(millis()) + ",leds=" + String((unsigned)hostLeds));
      break;
    default:
      break;
  }

  // 指令执行完闪一下：长度决定闪几下（见文件顶部 LED_CMD_* 的说明）。
  // 放在执行之后，因为闪灯是「这条命令已经出去了」的回执，不是「收到了」；
  // 闪灯本身不阻塞，长文本打字期间它会被拖后，但节奏不乱。
  // PING 是心跳（客户端每 10 秒一次），不算「指令」，不闪——否则灯会莫名其妙定期亮，
  // 看起来像故障。
  if (plan.action != KT_PING) {
    ledFlashCommand(line.length());
  }
}

// ---------------------------- BLE 回调 --------------------------------------
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) {
    deviceConnected = true;
    ledRefresh();
    Serial.println("[BLE] 客户端已连接");
  }

  void onDisconnect(BLEServer *server) {
    deviceConnected = false;
    pendingReleaseAll = true;  // 防止断开时按键卡住
    ledRefresh();
    Serial.println("[BLE] 客户端已断开");
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *characteristic) {
    uint8_t *data = characteristic->getData();
    size_t len = characteristic->getLength();

    for (size_t i = 0; i < len; i++) {
      char ch = (char)data[i];
      if (ch == '\n') {
        if (rxLine.length() > 0) {
          pushCommand(rxLine);
          rxLine = "";
        }
      } else if (ch != '\r') {
        if (rxLine.length() < 2048) {
          rxLine += ch;
        }
      }
    }
  }
};

// ============================================================================
//  链路一：BLE（GATT 外设）
// ============================================================================
static bool bleInited = false;

static void startBLE() {
  BLEDevice::init(DEVICE_NAME);
  BLEDevice::setMTU(517);
  bleInited = true;

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());

  BLEService *service = pServer->createService(SERVICE_UUID);

  // TX：ESP32 -> 客户端（通知），用于状态/回执
  pTx = service->createCharacteristic(
      CHAR_TX_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pTx->addDescriptor(new BLE2902());
  pTx->setValue("READY");

  // RX：客户端 -> ESP32（写入），命令入口
  BLECharacteristic *rx = service->createCharacteristic(
      CHAR_RX_UUID, BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxCallbacks());

  service->start();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);  // 改善部分手机/电脑的连接兼容性
  adv->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  deviceConnected = false;
  wasConnected = false;
  rxLine = "";
  Serial.printf("[BLE] 广播中，设备名: %s\n", DEVICE_NAME);
}

static void stopBLE() {
  // 先把指针摘掉，回调里就不会再碰已经释放的对象
  pServer = nullptr;
  pTx = nullptr;
  deviceConnected = false;
  wasConnected = false;
  rxLine = "";

  if (bleInited) {
    BLEDevice::deinit(true);  // 释放蓝牙占用的内存和射频，留给 WiFi
    bleInited = false;
    Serial.println("[BLE] 已关闭");
  }
}

// ============================================================================
//  链路二：WiFi AP + TCP
//  ESP32 自己开热点，电脑连上热点后向 192.168.4.1:8266 建 TCP 连接，
//  之后的文本协议和 BLE 完全一样（一行一条命令，\n 结尾）。
// ============================================================================
static void startWiFi() {
  WiFi.persistent(false);
  WiFi.mode(WIFI_AP);

  bool ok = (strlen(AP_PASS) >= 8) ? WiFi.softAP(AP_SSID, AP_PASS) : WiFi.softAP(AP_SSID);
  delay(150);  // 等 DHCP 服务起来，客户端才能拿到 IP

  tcpServer = new WiFiServer(TCP_PORT);
  tcpServer->begin();
  tcpServer->setNoDelay(true);

  deviceConnected = false;
  wasConnected = false;
  tcpRxLine = "";

  if (!ok) {
    Serial.println("[WiFi] 热点开启失败");
    return;
  }
  Serial.printf("[WiFi] 热点: %s  密码: %s\n", AP_SSID,
                strlen(AP_PASS) >= 8 ? AP_PASS : "(开放)");
  Serial.printf("[WiFi] 客户端请连 %s:%d\n", WiFi.softAPIP().toString().c_str(), TCP_PORT);
}

static void stopWiFi() {
  if (tcpClient) {
    tcpClient.stop();
  }
  if (tcpServer != nullptr) {
    tcpServer->end();
    delete tcpServer;
    tcpServer = nullptr;
  }
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_OFF);
  delay(60);
  deviceConnected = false;
  wasConnected = false;
  Serial.println("[WiFi] 已关闭");
}

// 收新连接、按行切包、检测掉线。必须频繁调用（loop 里每轮一次）。
static void serviceWiFi() {
  if (tcpServer == nullptr) {
    return;
  }

  WiFiClient incoming = tcpServer->accept();
  if (incoming) {
    if (tcpClient && tcpClient.connected()) {
      tcpClient.stop();
      Serial.println("[WiFi] 旧连接被新连接顶掉");
    }
    tcpClient = incoming;
    tcpClient.setNoDelay(true);
    tcpRxLine = "";
    deviceConnected = true;
    ledRefresh();
    Serial.printf("[WiFi] 客户端已连接: %s\n", tcpClient.remoteIP().toString().c_str());
    tcpClient.println("READY");
  }

  if (tcpClient && tcpClient.connected()) {
    while (tcpClient.available() > 0) {
      char ch = (char)tcpClient.read();
      if (ch == '\n') {
        if (tcpRxLine.length() > 0) {
          pushCommand(tcpRxLine);
          tcpRxLine = "";
        }
      } else if (ch != '\r') {
        if (tcpRxLine.length() < 2048) {
          tcpRxLine += ch;
        }
      }
    }
  } else if (tcpClient) {
    tcpClient.stop();
    tcpRxLine = "";
    deviceConnected = false;
    pendingReleaseAll = true;
    ledRefresh();
    Serial.println("[WiFi] 客户端已断开");
  }
}

// ============================================================================
//  模式切换
// ============================================================================
// 注意：参数用 uint8_t 而不是 LinkMode。Arduino IDE 会把函数原型插到文件最前面，
// 而那时 enum LinkMode 还没定义，签名里写枚举类型会报「not declared in this scope」。
static void setMode(uint8_t mode, bool save) {
  bool running = (mode == MODE_BLE) ? (pServer != nullptr) : (tcpServer != nullptr);
  if (mode == linkMode && running) {
    return;  // 已经在这个模式跑着了
  }

  Serial.printf("[MODE] 切换到 %s\n", mode == MODE_BLE ? "蓝牙 BLE" : "WiFi AP");

  Keyboard.releaseAll();  // 切模式别把按键卡在按下状态
  mouseReleaseAll();      // 鼠标键同理
  deviceConnected = false;
  wasConnected = false;
  if (queueMutex != nullptr) {
    xSemaphoreTake(queueMutex, portMAX_DELAY);
    cmdQueue.clear();
    xSemaphoreGive(queueMutex);
  }

  if (mode == MODE_BLE) {
    stopWiFi();
    startBLE();
  } else {
    stopBLE();
    startWiFi();
  }

  linkMode = (LinkMode)mode;
  ledRefresh();

  if (save) {
    prefs.begin("kbd", false);
    prefs.putUChar("mode", (uint8_t)mode);
    prefs.end();
  }
}

// ---------------------------- 板载按键 --------------------------------------
// BOOT 键短按 = 切换模式。25ms 消抖，松开后才触发，避免一次按下切两次。
static void pollButton() {
  static bool lastPressed = false;
  static uint32_t lastChangeMs = 0;
  static uint32_t pressAtMs = 0;

  bool pressed = (digitalRead(MODE_BUTTON_PIN) == LOW);
  uint32_t now = millis();

  if (pressed != lastPressed && (now - lastChangeMs) > 25) {
    lastChangeMs = now;
    lastPressed = pressed;
    if (pressed) {
      pressAtMs = now;
    } else if ((now - pressAtMs) > 40) {
      setMode(linkMode == MODE_BLE ? MODE_WIFI : MODE_BLE, true);
    }
  }
}

// ---------------------------- 初始化 ----------------------------------------
void setup() {
  // USB 必须第一个站起来：主机（特别是 BIOS/UEFI 的自检阶段）只在开机最初那
  // 一两秒里扫一次 USB，晚一步就得重启才能被认到。所以这里先把 HID 挂上去，
  // 串口日志、NVS、蓝牙/WiFi 全部排在后面。
  Keyboard.begin();
  Consumer.begin();
  Mouse.begin();   // 同一个 HID 接口下的第二个 report（鼠标），和键盘互不影响
  USB.begin();

  Serial.begin(115200);
  Serial.println();
  Serial.println("=== ESP32-S3 无线键盘桥启动 ===");

  pinMode(MODE_BUTTON_PIN, INPUT_PULLUP);

  // 记下主机的 LED 状态（CapsLock / NumLock / ScrollLock），
  // PING 回执里会带上，客户端就能显示主机现在的锁定键状态。
  Keyboard.onEvent(ARDUINO_USB_HID_KEYBOARD_LED_EVENT, onHostLedEvent);

  queueMutex = xSemaphoreCreateMutex();
  if (queueMutex == nullptr) {
    Serial.println("[fatal] 创建互斥锁失败");
  }

  ledSelfTest();

  // NVS：上次用的模式 + 开机引导键 + 连发时长/间隔
  prefs.begin("kbd", true);
  uint8_t saved = prefs.getUChar("mode", (uint8_t)MODE_BLE);
  prefs.end();
  linkMode = (saved == (uint8_t)MODE_WIFI) ? MODE_WIFI : MODE_BLE;
  // 引导键一律以 NVS 为准：0 = 明确关闭（开机不敲），没有记录 = 出厂默认
  bootKeyLoadSaved();
  Serial.printf("[MODE] 启动模式: %s（短按 BOOT 键切换）\n",
                linkMode == MODE_BLE ? "BLE 蓝牙" : "WiFi 热点");
  Serial.printf("[BOOTKEY] 开机连发: %s，时长 %u ms、间隔 %u ms（BOOTKEY:off 可关）\n",
                bootKeyName(), (unsigned)bootKeyWindowMs, (unsigned)bootKeyGapMs);

  setMode(linkMode, false);

  // 冷启动才开连发窗口：POST 阶段没有链路，只能靠固件自己敲键
  esp_reset_reason_t reason = esp_reset_reason();
  bool coldBoot = (reason == ESP_RST_POWERON || reason == ESP_RST_UNKNOWN);
  if (coldBoot && bootKeyCode != 0) {
    bootKeyBeginWindow(bootKeyWindowMs);
    Serial.printf("[BOOTKEY] 冷启动，开始连发 %s（约 %u 秒）\n", bootKeyName(),
                  (unsigned)(bootKeyWindowMs / 1000));
  } else if (coldBoot) {
    Serial.println("[BOOTKEY] 引导键是「关闭」，冷启动也不敲键");
  } else {
    Serial.printf("[BOOTKEY] 非冷启动（reset_reason=%d），不连发\n", (int)reason);
  }

  Serial.println("[USB] HID 键盘就绪，插到主机上应能被识别为键盘");
#if LED_USE_RGB
  Serial.printf("[LED] RGB 指示灯已启用，GPIO%d\n", LED_RGB_PIN);
#else
  Serial.println("[LED] RGB 指示灯已关闭（LED_USE_RGB=0）");
#endif
}

// ---------------------------- 主循环 ----------------------------------------
void loop() {
  pollButton();
  serviceBootKey();  // 开机引导键连发（不需要任何链路）

  if (linkMode == MODE_BLE) {
    // 断开后重新广播
    if (wasConnected && !deviceConnected) {
      wasConnected = false;
      delay(400);
      if (pServer != nullptr) {
        BLEDevice::startAdvertising();
        Serial.println("[BLE] 重新开始广播");
      }
    }
    if (deviceConnected && !wasConnected) {
      wasConnected = true;
    }
  } else {
    serviceWiFi();
  }

  if (pendingReleaseAll) {
    pendingReleaseAll = false;
    Keyboard.releaseAll();
    mouseReleaseAll();  // 掉线时鼠标键也要松开，不然主机会以为左键一直被按着
  }

  // 取一条命令执行
  bool hasCommand = false;
  String line;
  if (queueMutex != nullptr) {
    xSemaphoreTake(queueMutex, portMAX_DELAY);
    if (!cmdQueue.empty()) {
      line = cmdQueue.front();
      cmdQueue.pop_front();
      hasCommand = true;
    }
    xSemaphoreGive(queueMutex);
  }

  if (hasCommand) {
    processCommand(line);
  }

  ledFlashTick();  // 推进「指令闪灯」，没在闪的时候是空操作
  ledRefresh();    // 颜色没变时是空操作
  delay(2);
}
