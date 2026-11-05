// 构建期开关，只用于截图 / 演示，正常打包不用管。
//
//   flutter build ios --simulator --dart-define=START_TAB=1
//   flutter run --dart-define=START_TAB=2 --dart-define=FORCE_LANDSCAPE=true
//
// 手机上没法用脚本点按钮，只能用这种方式把界面停在指定页面来核对。

/// 启动时停在第几个 tab：0 键盘、1 鼠标、2 快捷键、3 设置
const int kStartTab = int.fromEnvironment('START_TAB');

/// 启动后自动弹出连接面板
const bool kOpenConnectSheet = bool.fromEnvironment('OPEN_CONNECT');

/// 强制横屏（检查横屏布局）
const bool kForceLandscape = bool.fromEnvironment('FORCE_LANDSCAPE');
