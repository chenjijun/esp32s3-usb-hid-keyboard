// 固件「引导键命令解析」的离线测试。
//
// tools/test_bootkey_cmd.sh 会把 .ino 里两段代码原样抠出来（连发参数变量/夹取函数、
// notifyBootCfg + pushCommand + handleBootKeyCommand），配上最小的 Arduino 桩，
// 用本机 clang++ 编译并跑一遍。
// 这样即使手边没有板子、也编不了整个固件，至少能确认「参数怎么解析、越界怎么夹、
// 回执长什么样」是对的——这部分恰恰是最容易写错、又最难靠肉眼看出来的。
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

// ============================ Arduino 桩 ====================================

class String {
public:
  String() = default;
  String(const char *s) : s_(s ? s : "") {}
  explicit String(unsigned v) : s_(std::to_string(v)) {}
  explicit String(int v) : s_(std::to_string(v)) {}

  unsigned length() const { return (unsigned)s_.size(); }
  const char *c_str() const { return s_.c_str(); }
  char operator[](unsigned i) const { return i < s_.size() ? s_[i] : '\0'; }

  String substring(unsigned from) const {
    if (from >= s_.size()) return String();
    return String(s_.substr(from).c_str());
  }
  String substring(unsigned from, unsigned to) const {
    if (from >= s_.size() || to <= from) return String();
    return String(s_.substr(from, to - from).c_str());
  }

  bool startsWith(const char *p) const { return s_.rfind(p, 0) == 0; }
  int indexOf(char c) const {
    auto pos = s_.find(c);
    return pos == std::string::npos ? -1 : (int)pos;
  }
  int indexOf(const String &t) const {
    auto pos = s_.find(t.s_);
    return pos == std::string::npos ? -1 : (int)pos;
  }
  long toInt() const { return atol(s_.c_str()); }
  void trim() {
    size_t b = s_.find_first_not_of(" \t\r\n");
    size_t e = s_.find_last_not_of(" \t\r\n");
    s_ = (b == std::string::npos) ? "" : s_.substr(b, e - b + 1);
  }

  String operator+(const String &o) const { return String((s_ + o.s_).c_str()); }
  String operator+(const char *o) const { return String((s_ + o).c_str()); }
  String &operator+=(const String &o) { s_ += o.s_; return *this; }
  bool operator==(const char *o) const { return s_ == o; }
  bool operator==(const String &o) const { return s_ == o.s_; }
  bool operator!=(const char *o) const { return s_ != o; }

private:
  std::string s_;
};

static String operator+(const char *a, const String &b) { return String(a) + b; }

// 固件里的 kt_eq：不区分大小写地比较 n 个字符
static bool kt_eq(const char *p, size_t n, const char *lit) {
  size_t m = strlen(lit);
  if (n != m) return false;
  for (size_t i = 0; i < n; i++) {
    char a = p[i], b = lit[i];
    if (a >= 'A' && a <= 'Z') a += 32;
    if (b >= 'A' && b <= 'Z') b += 32;
    if (a != b) return false;
  }
  return true;
}

struct SerialStub {
  void println(const char *) {}
  void printf(const char *, ...) {}
};
static SerialStub Serial;

static uint32_t millis() { return 0; }

class Preferences {
public:
  void begin(const char *, bool) {}
  void end() {}
  size_t putUShort(const char *k, uint16_t v) { ushorts_[k] = v; return 2; }
  uint16_t getUShort(const char *k, uint16_t d) {
    auto it = ushorts_.find(k);
    return it == ushorts_.end() ? d : it->second;
  }
  bool isKey(const char *k) { return uchars_.count(k) > 0 || ushorts_.count(k) > 0; }
  size_t putUChar(const char *k, uint8_t v) { uchars_[k] = v; return 1; }
  uint8_t getUChar(const char *k, uint8_t d) {
    auto it = uchars_.find(k);
    return it == uchars_.end() ? d : it->second;
  }
  std::map<std::string, uint16_t> ushorts_;
  std::map<std::string, uint8_t> uchars_;
};
static Preferences prefs;

// 收到什么回执都记下来，最后断言用
static std::vector<std::string> g_replies;
static void notifyHost(const String &msg) { g_replies.push_back(msg.c_str()); }

static int g_taps = 0;
static uint8_t g_lastTap = 0;
static void tapCode(uint8_t code, uint16_t) { g_taps++; g_lastTap = code; }
static int kt_resolve_key(const char *name, size_t len) {
  std::string s(name, len);
  if (s == "delete") return 0x2B;
  if (s == "f2") return 0x3B;
  return -1;
}

// 固件里的默认值与范围（和 .ino 顶部保持一致，只用于断言期望值）
#define BOOTKEY_ENABLED 1
#define BOOTKEY_DEFAULT 0x2B
#define BOOTKEY_HOLD_MS 80
#define BOOTKEY_GAP_MS 220
#define BOOTKEY_WINDOW_MS 10000
#define BOOTKEY_START_MS 1500
#define BOOTKEY_WINDOW_MIN_MS 1000
#define BOOTKEY_WINDOW_MAX_MS 60000
#define BOOTKEY_GAP_MIN_MS 60
#define BOOTKEY_GAP_MAX_MS 5000

// 固件里的键名表（完整的在 .ino 里，这里只留测试要用的几个）。
// block_a.inc 里带着真的 bootKeyName()，所以这张表得先摆好。
struct KtNamed {
  const char *name;
  uint8_t code;
};
static const KtNamed KT_NAMED_KEYS[] = {
    {"delete", 0x2B},
    {"f2", 0x3B},
};

#include "block_a.inc"   // 夹取函数 / 开窗关窗 / NVS 存取 / bootKeyName / serviceBootKey

// pushCommand 用到队列（这段代码也一起被抽出来了，顺手给它一套桩）
#include <deque>
static std::deque<String> cmdQueue;
static int queueMutexStorage = 1;
static void *queueMutex = &queueMutexStorage;
#define portMAX_DELAY 0xffffffffu
static void xSemaphoreTake(void *, unsigned) {}
static void xSemaphoreGive(void *) {}

#include "block_b.inc"   // notifyBootCfg + pushCommand + handleBootKeyCommand

// ============================== 测试 ========================================

static int g_fail = 0;
#define CHECK(cond, ...)                        \
  do {                                          \
    if (!(cond)) {                              \
      printf("  FAIL ");                        \
      printf(__VA_ARGS__);                      \
      printf("\n");                             \
      g_fail++;                                 \
    }                                           \
  } while (0)

static void send(const char *line) {
  g_replies.clear();
  handleBootKeyCommand(String(line));
}

static bool hasReply(const char *want) {
  for (auto &r : g_replies) {
    if (r == want) return true;
  }
  return false;
}

static bool hasBootCfg() {
  for (auto &r : g_replies) {
    if (r.rfind("BOOTCFG:", 0) == 0) return true;
  }
  return false;
}

static std::string bootCfg() {
  for (auto &r : g_replies) {
    if (r.rfind("BOOTCFG:", 0) == 0) return r;
  }
  return "";
}

int main() {
  printf("1) 查询：回 BOOTKEY:<键> 和 BOOTCFG: 两条\n");
  send("BOOTKEY:?");
  CHECK(hasReply("BOOTKEY:delete"), "没回 BOOTKEY:delete");
  CHECK(bootCfg() == "BOOTCFG:key=delete,win=10000,gap=220,hold=80",
        "BOOTCFG 内容不对：%s", bootCfg().c_str());

  printf("2) 设键位：写进 NVS，回执同步显示新键\n");
  send("BOOTKEY:f2");
  CHECK(prefs.uchars_["bootkey"] == 0x3B, "NVS 没写 bootkey");
  CHECK(bootCfg().find("key=f2") != std::string::npos, "回执没跟上：%s", bootCfg().c_str());

  printf("3) 连发时长：空格和等号两种写法都认\n");
  send("BOOTKEY:window 8000");
  CHECK(bootKeyWindowMs == 8000, "空格写法没生效（%u）", bootKeyWindowMs);
  CHECK(prefs.ushorts_["bkwin"] == 8000, "NVS 没写 bkwin");
  send("BOOTKEY:window=12000");
  CHECK(bootKeyWindowMs == 12000, "等号写法没生效（%u）", bootKeyWindowMs);

  printf("4) 连发间隔 + 越界夹取\n");
  send("BOOTKEY:gap 300");
  CHECK(bootKeyGapMs == 300, "间隔没生效（%u）", bootKeyGapMs);
  send("BOOTKEY:window 999999");
  CHECK(bootKeyWindowMs == BOOTKEY_WINDOW_MAX_MS, "上限没夹住（%u）", bootKeyWindowMs);
  send("BOOTKEY:window 1");
  CHECK(bootKeyWindowMs == BOOTKEY_WINDOW_MIN_MS, "下限没夹住（%u）", bootKeyWindowMs);
  send("BOOTKEY:gap 99999");
  CHECK(bootKeyGapMs == BOOTKEY_GAP_MAX_MS, "间隔上限没夹住（%u）", bootKeyGapMs);
  send("BOOTKEY:gap 1");
  CHECK(bootKeyGapMs == BOOTKEY_GAP_MIN_MS, "间隔下限没夹住（%u）", bootKeyGapMs);

  printf("5) 立即连发带参数：一次写两个值并开窗口\n");
  send("BOOTKEY:now 5000 150");
  CHECK(bootKeyWindowMs == 5000 && bootKeyGapMs == 150,
        "参数没生效（win=%u gap=%u）", bootKeyWindowMs, bootKeyGapMs);
  CHECK(prefs.ushorts_["bkwin"] == 5000 && prefs.ushorts_["bkgap"] == 150, "NVS 没写全");

  printf("6) 只给一个参数时，另一个保持不变\n");
  send("BOOTKEY:now 6000");
  CHECK(bootKeyWindowMs == 6000 && bootKeyGapMs == 150,
        "不该动间隔（win=%u gap=%u）", bootKeyWindowMs, bootKeyGapMs);

  printf("7) 关闭：回 off，BOOTCFG 里 key=off\n");
  send("BOOTKEY:off");
  CHECK(hasReply("BOOTKEY:off"), "没回 BOOTKEY:off");
  CHECK(bootCfg().find("key=off") != std::string::npos, "回执没显示关闭：%s", bootCfg().c_str());

  printf("8) 不认识的键：回 BOOTKEY-ERR，不动配置\n");
  prefs.uchars_.clear();
  send("BOOTKEY:f13");
  bool err = false;
  for (auto &r : g_replies) {
    if (r.rfind("BOOTKEY-ERR:", 0) == 0) err = true;
  }
  CHECK(err, "没回 BOOTKEY-ERR");

  printf("9) 关闭会真的落盘：NVS 里写的是 0\n");
  prefs.uchars_["bootkey"] = 0xFF;      // 先放个脏值，免得「本来就没写」也算通过
  send("BOOTKEY:off");
  CHECK(prefs.uchars_["bootkey"] == 0, "NVS 里的 bootkey 不是 0（%u）",
        prefs.uchars_["bootkey"]);

  printf("10) 关掉之后重启：恢复成 0，连发窗口根本不开、一下都不敲\n");
  bootKeyCode = BOOTKEY_DEFAULT;        // 模拟上电时 RAM 里的出厂值（delete）
  bootKeyEndAt = 0;
  g_taps = 0;
  bootKeyLoadSaved();                   // 等价于 setup() 里读 NVS
  CHECK(bootKeyCode == 0, "重启后 bootKeyCode=%u，应该被 NVS 里的 0 关掉", bootKeyCode);
  bootKeyBeginWindow(10000);            // 冷启动那条路径
  CHECK(bootKeyEndAt == 0, "关掉状态下不该打开连发窗口");
  serviceBootKey();
  CHECK(g_taps == 0, "关掉之后一开机就敲了 %d 下", g_taps);

  printf("11) 设成 f2 再重启：恢复成 f2，窗口能打开\n");
  send("BOOTKEY:f2");
  bootKeyCode = 0;
  bootKeyLoadSaved();
  CHECK(bootKeyCode == 0x3B, "重启后没恢复成 f2（%u）", bootKeyCode);
  bootKeyBeginWindow(10000);
  CHECK(bootKeyEndAt != 0, "开着引导键却没开连发窗口");

  printf("12) 没写过 NVS 的新板子：回落到出厂默认 delete\n");
  prefs.uchars_.clear();
  bootKeyCode = 0;
  bootKeyLoadSaved();
  CHECK(bootKeyCode == BOOTKEY_DEFAULT, "没记录时该用出厂默认（%u）", bootKeyCode);

  if (g_fail == 0) {
    printf("\n全部通过（12 组断言）\n");
    return 0;
  }
  printf("\n有 %d 项不符合预期\n", g_fail);
  return 1;
}
