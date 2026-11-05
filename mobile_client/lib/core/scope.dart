// 全局状态注入。界面里用 `RemoteScope.of(context)` 拿到 Remote，
// 依赖它就会在 notifyListeners 时自动重建。

import 'package:flutter/widgets.dart';

import 'remote.dart';

class RemoteScope extends InheritedNotifier<Remote> {
  const RemoteScope({super.key, required Remote remote, required super.child})
      : super(notifier: remote);

  static Remote of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<RemoteScope>();
    assert(scope != null, '找不到 RemoteScope，检查 MaterialApp 外层');
    return scope!.notifier!;
  }
}
