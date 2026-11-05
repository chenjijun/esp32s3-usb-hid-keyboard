// 固件「指令闪灯」逻辑的离线测试（不需要板子）。
//
// tools/test_led_flash.sh 会把 esp32s3_ble_keyboard.ino 里那段闪灯状态机原样抠出来，
// 拼到这个文件里编译运行。所以测的就是固件里真正跑的那份代码，不是另抄一份。
//
// 验证的是：命令长度 -> 闪几下、闪完之后回到底色、亮灭节拍、
// 连续命令时的排队上限、以及「没有命令时灯不许自己动」。
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

// ---- 桩：Arduino 环境的最小替身 ----
static uint32_t g_now = 0;
static uint32_t millis() { return g_now; }

static uint8_t g_rgb[3] = {0, 0, 0};
static int g_writes = 0;
static void rgbLedWrite(int, uint8_t r, uint8_t g, uint8_t b) {
  g_rgb[0] = r; g_rgb[1] = g; g_rgb[2] = b;
  g_writes++;
}

#define LED_USE_RGB 1
#define LED_BRIGHTNESS 255        // 满量程，方便直接比对语义色
#define LED_CMD_FLASH 1
#define LED_CMD_ON_MS 45
#define LED_CMD_GAP_MS 55
#define LED_CMD_MAX_BLINKS 6
static const uint8_t LED_CMD_COLOR[3] = {255, 255, 255};

// ---- 状态灯的底座（固件里在更早的位置定义）----
static uint8_t ledLast[3] = {255, 255, 255};
static uint8_t ledBase[3] = {0, 0, 150};   // 拿 BLE 未连接那个蓝当底色
static const uint8_t LED_OFF[3] = {0, 0, 0};

static inline uint8_t ledDim(uint8_t v) { return v; }

static void ledSet(const uint8_t c[3]) {
  if (c[0] == ledLast[0] && c[1] == ledLast[1] && c[2] == ledLast[2]) return;
  ledLast[0] = c[0]; ledLast[1] = c[1]; ledLast[2] = c[2];
  rgbLedWrite(48, ledDim(c[0]), ledDim(c[1]), ledDim(c[2]));
}

#include "flash_block.inc"        // ← 由脚本从 .ino 里抽出来的真代码

// ---- 测试脚手架 ----
static int g_fail = 0;
#define CHECK(cond, ...)                       \
  do {                                         \
    if (!(cond)) {                             \
      printf("  FAIL ");                       \
      printf(__VA_ARGS__);                     \
      printf("\n");                            \
      g_fail++;                                \
    }                                          \
  } while (0)

static bool isWhite() { return g_rgb[0] == 255 && g_rgb[1] == 255 && g_rgb[2] == 255; }
static bool isBase()  { return g_rgb[0] == ledBase[0] && g_rgb[1] == ledBase[1] && g_rgb[2] == ledBase[2]; }

// 跑 ms 毫秒（每 2ms 一拍，和固件 loop 里 delay(2) 的节奏一致），数「由暗变亮」的次数
static int run(unsigned ms) {
  int blinks = 0;
  static bool wasWhite = false;
  for (unsigned t = 0; t < ms; t += 2) {
    g_now += 2;
    ledFlashTick();
    bool w = isWhite();
    if (w && !wasWhite) blinks++;
    wasWhite = w;
  }
  return blinks;
}

static void reset() {
  run(3000);
  flashLeft = 0;
  flashLit = false;
  ledSet(ledBase);
}

int main() {
  printf("1) 长度 -> 闪烁次数（阈值 8 / 32 / 128 / 512 / 1024）\n");
  struct { size_t len; int want; } cases[] = {
      {1, 1}, {8, 1}, {9, 2}, {32, 2}, {33, 3}, {128, 3},
      {129, 4}, {200, 4}, {512, 4}, {513, 5}, {1024, 5}, {1025, 6}, {9999, 6},
  };
  for (auto &c : cases) {
    reset();
    ledFlashCommand(c.len);
    int got = run(3000);
    CHECK(got == c.want, "len=%zu 期望 %d 下，实际 %d 下", c.len, c.want, got);
  }

  printf("2) 闪完之后要回到链路底色，不能停在灭灯状态\n");
  reset();
  ledFlashCommand(200);
  run(3000);
  CHECK(isBase(), "结束后是 %d,%d,%d，不是底色 %d,%d,%d",
        g_rgb[0], g_rgb[1], g_rgb[2], ledBase[0], ledBase[1], ledBase[2]);

  printf("3) 单次闪灯时长：亮 45ms\n");
  reset();
  ledFlashCommand(1);
  int onMs = 0;
  for (unsigned t = 0; t < 1000; t += 2) {
    g_now += 2;
    ledFlashTick();
    if (isWhite()) onMs += 2;
  }
  CHECK(onMs >= 44 && onMs <= 48, "亮灯总时长 %dms（应约 45ms）", onMs);

  printf("4) 连续 20 条短命令：排队但不超过 LED_CMD_MAX_BLINKS 上限\n");
  reset();
  for (int i = 0; i < 20; i++) ledFlashCommand(3);
  CHECK(flashLeft <= LED_CMD_MAX_BLINKS, "队列 %d 超过上限 %d", flashLeft, LED_CMD_MAX_BLINKS);
  int got = run(3000);
  CHECK(got == LED_CMD_MAX_BLINKS, "连发后闪了 %d 下（上限 %d）", got, LED_CMD_MAX_BLINKS);

  printf("5) 没有命令时，灯必须一直是底色（鼠标 30Hz 流靠调用方不发）\n");
  reset();
  bool stayedBase = true;
  for (int i = 0; i < 100; i++) {
    g_now += 33;
    ledFlashTick();
    if (!isBase()) stayedBase = false;
  }
  CHECK(stayedBase, "没有命令时灯被改动了");

  printf("6) 闪到一半又来一条：不打断当前这闪，只往后排\n");
  reset();
  ledFlashCommand(1);
  run(20);                         // 还在亮的这 45ms 内
  bool litBefore = isWhite();
  ledFlashCommand(1);
  CHECK(litBefore && isWhite(), "第二条命令把当前这一下打断了");
  int total = run(3000);
  CHECK(total >= 1, "后续没闪（%d）", total);

  if (g_fail == 0) {
    printf("\n全部通过（6 组断言）\n");
    return 0;
  }
  printf("\n有 %d 项不符合预期\n", g_fail);
  return 1;
}
