/// 一个有冲突的文件。路径相对仓库根。
class ConflictFile {
  const ConflictFile({required this.path, required this.yours, required this.theirs});

  factory ConflictFile.fromJson(Map<String, dynamic> j) => ConflictFile(
        path: j['path'] as String,
        yours: j['yours'] as String? ?? 'Modified',
        theirs: j['theirs'] as String? ?? 'Modified',
      );

  final String path;

  /// 自己这一侧对这个文件做了什么:Modified / Added / Deleted,或 `—`(没有这个文件)。
  final String yours;
  final String theirs;

  String get name => path.split('/').last;

  /// 所在目录;在仓库根时为空。
  String get dir {
    final i = path.lastIndexOf('/');
    return i < 0 ? '' : path.substring(0, i);
  }
}

/// 仓库里进行中的合并 / 变基 / cherry-pick / revert。标题栏据此显示「Merging kdev」和冲突按钮。
class RepoOperation {
  const RepoOperation({required this.kind, this.branch, this.incoming, this.onto, this.conflicts = const []});

  /// `merge` / `rebase` / `cherry-pick` / `revert`;冲突不是来自这四种(比如 stash apply)时为 null。
  final String? kind;

  /// 当前分支(变基时是被变基的分支)。
  final String? branch;

  /// 合并时被合进来的分支,cherry-pick / revert 时是那个提交。
  final String? incoming;

  /// 变基到哪里。
  final String? onto;
  final List<ConflictFile> conflicts;

  static RepoOperation? fromJson(Map<String, dynamic> j) {
    final kind = j['operation'] as String?;
    final conflicts = [
      for (final c in (j['conflicts'] as List? ?? const [])) ConflictFile.fromJson(Map<String, dynamic>.from(c as Map)),
    ];
    if (kind == null && conflicts.isEmpty) return null;
    return RepoOperation(
      kind: kind,
      branch: j['branch'] as String?,
      incoming: j['incoming'] as String?,
      onto: j['onto'] as String?,
      conflicts: conflicts,
    );
  }

  bool get hasConflicts => conflicts.isNotEmpty;

  /// 标题栏上的进行时:Merging / Rebasing / Cherry-picking / Reverting。
  String get verb => switch (kind) {
        'merge' => 'Merging',
        'rebase' => 'Rebasing',
        'cherry-pick' => 'Cherry-picking',
        'revert' => 'Reverting',
        _ => 'Conflicts',
      };

  /// 放弃 / 完成按钮上的名字:Merge / Rebase / Cherry-pick / Revert。
  String get noun => switch (kind) {
        'merge' => 'Merge',
        'rebase' => 'Rebase',
        'cherry-pick' => 'Cherry-pick',
        'revert' => 'Revert',
        _ => 'Operation',
      };

  /// 可以放弃:有明确的进行中操作才能 `--abort`(只有冲突没有操作时不行)。
  bool get canAbort => kind != null;

  /// 对话框第一行的说明,按 (文字, 是否粗体) 分段。
  List<(String, bool)> describe(String? currentBranch) {
    final name = branch ?? currentBranch;
    return switch (kind) {
      'merge' => [
          ('Merging branch ', false),
          (incoming ?? '?', true),
          (' into branch ', false),
          (name ?? 'HEAD', true),
        ],
      'rebase' => [
          ('Rebasing branch ', false),
          (name ?? 'HEAD', true),
          if (onto != null) ...[(' onto ', false), (onto!, true)],
        ],
      'cherry-pick' || 'revert' => [
          (kind == 'revert' ? 'Reverting commit ' : 'Cherry-picking commit ', false),
          (incoming ?? '?', true),
          (' on branch ', false),
          (name ?? 'HEAD', true),
        ],
      _ => [('These files have unresolved conflicts', false)],
    };
  }
}
