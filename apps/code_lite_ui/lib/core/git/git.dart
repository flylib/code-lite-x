// web 没有 dart:io(也就跑不了 git 进程):拿桩,原生拿真实现。两者类名与签名一致。
export 'git_service_stub.dart' if (dart.library.io) 'git_service.dart';
