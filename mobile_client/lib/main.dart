import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/remote.dart';
import 'debug_flags.dart';
import 'core/scope.dart';
import 'ui/home.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 横屏时也能用（手机横过来键盘更宽，操作电脑更顺）
  SystemChrome.setPreferredOrientations(
    kForceLandscape
        ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ],
  );

  // 整个 App 是深色的：状态栏/导航栏的图标要亮色，不然在深色背景上看不见
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: Color(0xFF0B0D12),
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  runApp(const Esp32KeyboardApp());
}

class Esp32KeyboardApp extends StatefulWidget {
  const Esp32KeyboardApp({super.key});

  @override
  State<Esp32KeyboardApp> createState() => _Esp32KeyboardAppState();
}

class _Esp32KeyboardAppState extends State<Esp32KeyboardApp> {
  late final Remote _remote;

  @override
  void initState() {
    super.initState();
    _remote = Remote();
    _remote.init();
  }

  @override
  void dispose() {
    _remote.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RemoteScope(
      remote: _remote,
      child: MaterialApp(
        title: 'ESP32 无线键盘',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const HomePage(),
      ),
    );
  }
}
