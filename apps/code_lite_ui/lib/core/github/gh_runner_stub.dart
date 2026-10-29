// web 没有进程:GitHub 功能不可用。
import '../l10n/l10n.dart';
import 'github_models.dart';

Future<List<int>> runGh(String root, List<String> args, {String? stdin}) async =>
    throw GhException(
      tr('Web 版不支持 GitHub Pull Requests(需要本机 gh 命令行)。', 'GitHub pull requests are not supported in the web version (the gh command line is required).'),
      notInstalled: true,
    );

Future<void> openUrl(String url) async {}
