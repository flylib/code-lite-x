// web 没有进程:GitHub 功能不可用。
import 'github_models.dart';

Future<List<int>> runGh(String root, List<String> args, {String? stdin}) async =>
    throw GhException('Web 版不支持 GitHub Pull Requests(需要本机 gh 命令行)。', notInstalled: true);

Future<void> openUrl(String url) async {}
