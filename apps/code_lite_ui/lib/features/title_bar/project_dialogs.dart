import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/platform/workspace_io.dart' as io;
import '../../core/theme/intellij_theme.dart';
import 'project_menu.dart';

const TextStyle _text = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

/// (项目目录, 错误);成功时错误为 null。
typedef ProjectResult = (String?, String?);
typedef ProjectCreator = Future<ProjectResult> Function(String parentDir, String name);
typedef RepositoryCloner = Future<ProjectResult> Function(String url, String parentDir, {String? name});

/// New Project…:在选好的目录下新建一个文件夹并 git init。返回新项目的目录,取消返回 null。
Future<String?> showNewProjectDialog(
  BuildContext context, {
  required String initialLocation,
  String? home,
  ProjectCreator? create,
  Future<String?> Function()? pickDirectory,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ProjectDialog(
      title: tr('新建项目', 'New Project'),
      action: tr('创建', 'Create'),
      busyLabel: tr('正在创建…', 'Creating…'),
      initialLocation: initialLocation,
      home: home,
      pickDirectory: pickDirectory ?? io.pickDirectory,
      fields: [_Field.name('Name', tr('名称', 'Name'), hint: 'my-app')],
      run: (parent, values) => (create ?? io.createProject)(parent, values['Name']!),
    ),
  );
}

/// Clone Repository…:把仓库克隆到选好的目录下。返回克隆出的目录,取消返回 null。
Future<String?> showCloneDialog(
  BuildContext context, {
  required String initialLocation,
  String? home,
  RepositoryCloner? clone,
  Future<String?> Function()? pickDirectory,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ProjectDialog(
      title: tr('克隆存储库', 'Clone Repository'),
      action: tr('克隆', 'Clone'),
      busyLabel: tr('正在克隆…', 'Cloning…'),
      initialLocation: initialLocation,
      home: home,
      pickDirectory: pickDirectory ?? io.pickDirectory,
      fields: [
        _Field.name('URL', 'URL',
            hint: tr('https://github.com/owner/repo.git 或 git@host:owner/repo.git', 'https://github.com/owner/repo.git or git@host:owner/repo.git')),
        _Field.name('Name', tr('名称', 'Name'), hint: tr('默认取地址的最后一段', 'Defaults to the last segment of the URL'), optional: true),
      ],
      run: (parent, values) => (clone ?? io.cloneRepository)(values['URL']!, parent, name: values['Name']),
      // 填了地址、名字还空着时,名字框里提示将要用的目录名
      hintFrom: (values) => values['URL'] == null ? null : io.repositoryNameFromUrl(values['URL']!),
    ),
  );
}

class _Field {
  const _Field.name(this.key, this.label, {this.hint, this.optional = false});

  /// 取值用的固定标识(不随界面语言变)。
  final String key;

  /// 显示的名字。
  final String label;
  final String? hint;
  final bool optional;
}

class _ProjectDialog extends StatefulWidget {
  const _ProjectDialog({
    required this.title,
    required this.action,
    required this.busyLabel,
    required this.initialLocation,
    required this.home,
    required this.pickDirectory,
    required this.fields,
    required this.run,
    this.hintFrom,
  });

  final String title;
  final String action;
  final String busyLabel;
  final String initialLocation;
  final String? home;
  final Future<String?> Function() pickDirectory;
  final List<_Field> fields;
  final Future<ProjectResult> Function(String parent, Map<String, String?> values) run;
  final String? Function(Map<String, String?> values)? hintFrom;

  @override
  State<_ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<_ProjectDialog> {
  late final TextEditingController _location = TextEditingController(text: abbreviatePath(widget.initialLocation, widget.home));
  late final Map<String, TextEditingController> _values = {for (final f in widget.fields) f.key: TextEditingController()};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _location.dispose();
    for (final c in _values.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, String?> get _current => {
        for (final e in _values.entries) e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(),
      };

  Future<void> _choose() async {
    final picked = await widget.pickDirectory();
    if (picked != null && mounted) setState(() => _location.text = abbreviatePath(picked, widget.home));
  }

  Future<void> _submit() async {
    if (_busy) return;
    final values = _current;
    for (final f in widget.fields) {
      if (!f.optional && values[f.key] == null) {
        setState(() => _error = tr('请填写${f.label}', 'Please enter ${f.label}'));
        return;
      }
    }
    final parent = expandHome(_location.text, widget.home);
    if (parent.isEmpty) {
      setState(() => _error = tr('请选择位置', 'Please choose a location'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final (path, error) = await widget.run(parent, values);
    if (!mounted) return;
    if (path != null && error == null) {
      Navigator.pop(context, path);
    } else {
      setState(() {
        _busy = false;
        _error = error ?? tr('失败', 'Failed');
      });
    }
  }

  Widget _labelled(String label, Widget child) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: 72, child: Text(label, style: _muted)),
          Expanded(child: child),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    const decoration = InputDecoration(border: OutlineInputBorder(), isDense: true);
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(widget.title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < widget.fields.length; i++)
              _labelled(
                widget.fields[i].label,
                ListenableBuilder(
                  listenable: Listenable.merge(_values.values.toList()), // 名字框的提示跟着地址框变
                  builder: (context, _) => TextField(
                    controller: _values[widget.fields[i].key],
                    autofocus: i == 0,
                    enabled: !_busy,
                    style: _text,
                    decoration: decoration.copyWith(
                      hintText: (widget.fields[i].optional ? widget.hintFrom?.call(_current) : null) ?? widget.fields[i].hint,
                      hintStyle: _muted,
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ),
            _labelled(
              tr('位置', 'Location'),
              Row(children: [
                Expanded(
                  child: TextField(controller: _location, enabled: !_busy, style: _text, decoration: decoration, onSubmitted: (_) => _submit()),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _busy ? null : _choose, child: Text(tr('选择…', 'Choose…'))),
              ]),
            ),
            if (_busy)
              Row(children: [
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(widget.busyLabel, style: _muted),
              ]),
            if (_error != null) Text(_error!, style: const TextStyle(color: IntelliJTheme.diagError, fontSize: 12)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(tr('取消', 'Cancel'))),
        FilledButton(onPressed: _busy ? null : _submit, child: Text(widget.action)),
      ],
    );
  }
}
