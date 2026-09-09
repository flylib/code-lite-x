import 'package:flutter/widgets.dart';

import '../../features/editor/editor_session_manager.dart';
import 'layout_store.dart';
import 'workspace_store.dart';

/// 把 store 挂到 widget 树上,并且只重建真正读了它的子树。
///
/// 这里刻意不引第三方包:`InheritedNotifier` 在 store 通知时只重建
/// 通过 `dependOnInheritedWidgetOfExactType` 订阅过它的 widget,
/// 这正是我们要的作用域。需要更细的粒度时用 `ListenableBuilder`。
class LayoutScope extends InheritedNotifier<LayoutStore> {
  const LayoutScope({super.key, required LayoutStore super.notifier, required super.child});

  static LayoutStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LayoutScope>();
    assert(scope != null, 'LayoutScope 不在当前 context 之上');
    return scope!.notifier!;
  }

  /// 读取但不订阅 —— 用于回调里改状态,避免无谓重建。
  static LayoutStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<LayoutScope>();
    assert(scope != null, 'LayoutScope 不在当前 context 之上');
    return scope!.notifier!;
  }
}

class WorkspaceScope extends InheritedNotifier<WorkspaceStore> {
  const WorkspaceScope({super.key, required WorkspaceStore super.notifier, required super.child});

  static WorkspaceStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();
    assert(scope != null, 'WorkspaceScope 不在当前 context 之上');
    return scope!.notifier!;
  }

  static WorkspaceStore read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<WorkspaceScope>();
    assert(scope != null, 'WorkspaceScope 不在当前 context 之上');
    return scope!.notifier!;
  }
}

/// 编辑会话单独一层:标签、分屏、每个 buffer 的 controller。
/// 按键只让订阅了这一层(或订阅了具体 controller)的子树重建。
class SessionScope extends InheritedNotifier<EditorSessionManager> {
  const SessionScope({super.key, required EditorSessionManager super.notifier, required super.child});

  static EditorSessionManager of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(scope != null, 'SessionScope 不在当前 context 之上');
    return scope!.notifier!;
  }

  static EditorSessionManager read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<SessionScope>();
    assert(scope != null, 'SessionScope 不在当前 context 之上');
    return scope!.notifier!;
  }
}

extension StoreLookup on BuildContext {
  LayoutStore get layout => LayoutScope.of(this);
  WorkspaceStore get workspace => WorkspaceScope.of(this);
  EditorSessionManager get session => SessionScope.of(this);

  LayoutStore get layoutRead => LayoutScope.read(this);
  WorkspaceStore get workspaceRead => WorkspaceScope.read(this);
  EditorSessionManager get sessionRead => SessionScope.read(this);
}
