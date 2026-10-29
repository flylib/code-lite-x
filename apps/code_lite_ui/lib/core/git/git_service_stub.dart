// web 预览用的桩:与 git_service.dart 同名同签名,所有操作都返回"不可用"。

import '../l10n/l10n.dart';

Map<String, dynamic> get _unavailable => {'status': 'error', 'error': tr('web 预览不支持 Git', 'Git is not supported in the web preview')};

class GitService {
  GitService(this.root);

  final String root;

  Future<String> headFingerprint() async => '';

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async => _unavailable;

  Future<Map<String, dynamic>> status() async => _unavailable;

  Future<Map<String, dynamic>> diff({String? path, bool staged = false}) async => _unavailable;

  Future<Map<String, dynamic>> stage(String path) async => _unavailable;

  Future<Map<String, dynamic>> unstage(String path) async => _unavailable;

  Future<Map<String, dynamic>> commit(String message, {bool amend = false}) async => _unavailable;

  Future<Map<String, dynamic>> fileDiffHunks(String path) async => _unavailable;

  Future<Map<String, dynamic>> revertFile(String path) async => _unavailable;
}
