// 配色与主题。手机端固定走深色：这东西一般在暗处用来远程操作电脑，
// 深色不刺眼，也和 App 图标（黑底霓虹）一致。

import 'package:flutter/material.dart';

class C {
  // 背景层次
  static const bg = Color(0xFF0B0D12);
  static const surface = Color(0xFF141822);
  static const surfaceHi = Color(0xFF1D2330);
  static const surfaceMax = Color(0xFF262D3D);
  static const line = Color(0xFF2B3344);

  // 文字
  static const ink = Color(0xFFEDF1F9);
  static const soft = Color(0xFF8E9AB2);
  static const faint = Color(0xFF5F6A80);

  // 强调色（图标里的霓虹青 + 紫）
  static const accent = Color(0xFF2EE6FF);
  static const accent2 = Color(0xFFA78BFA);
  static const ok = Color(0xFF34D399);
  static const warn = Color(0xFFFBBF24);
  static const danger = Color(0xFFFF5D5D);

  static const accentDim = Color(0x1F2EE6FF);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: C.accent,
    brightness: Brightness.dark,
  ).copyWith(
    primary: C.accent,
    secondary: C.accent2,
    surface: C.surface,
    onSurface: C.ink,
    error: C.danger,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.bg,
    canvasColor: C.bg,
    splashFactory: InkSparkle.splashFactory,
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: C.ink),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: C.ink),
      bodyMedium: TextStyle(fontSize: 14, color: C.ink),
      bodySmall: TextStyle(fontSize: 12, color: C.soft),
      labelSmall: TextStyle(fontSize: 11, color: C.faint, letterSpacing: 0.2),
    ),
    dividerColor: C.line,
    sliderTheme: const SliderThemeData(
      activeTrackColor: C.accent,
      inactiveTrackColor: C.surfaceMax,
      thumbColor: C.accent,
      overlayColor: C.accentDim,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? C.bg : C.soft,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? C.accent : C.surfaceMax,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: C.surfaceMax,
      contentTextStyle: TextStyle(color: C.ink, fontSize: 13),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
