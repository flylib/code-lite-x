// IDE 自身及其子进程(语言服务器、git……)的内存与 CPU 占用,状态栏显示用。
//
// macOS:proc_pid_rusage 取 phys_footprint —— 与「活动监视器」的「内存」一列同一口径
// (含 GPU 缓冲等,RSS 会严重低估 Flutter 应用);CPU 按两次采样间的用户 + 系统时间增量计算。
// 子进程用 proc_listchildpids 递归找到。都是系统调用,不需要启动 ps。
// 其它平台退回 ProcessInfo.currentRss(只统计 IDE 本身,没有 CPU)。

import 'dart:ffi';
import 'dart:io';


class ProcessUsage {
  const ProcessUsage({required this.pid, required this.name, required this.memoryBytes, this.cpuPercent});

  final int pid;
  final String name;
  final int memoryBytes;

  /// 两次采样之间的平均 CPU(100 = 占满一个核);第一次采样时为 null。
  final double? cpuPercent;
}

class ResourceSnapshot {
  const ResourceSnapshot(this.processes);

  /// 第一个是 IDE 本身,其后是子进程。
  final List<ProcessUsage> processes;

  int get totalMemoryBytes => processes.fold(0, (s, p) => s + p.memoryBytes);

  double? get totalCpuPercent {
    if (processes.any((p) => p.cpuPercent == null)) return null;
    return processes.fold<double>(0, (s, p) => s + p.cpuPercent!);
  }
}

typedef _RusageC = Int32 Function(Int32 pid, Int32 flavor, Pointer<Uint8> buffer);
typedef _RusageDart = int Function(int pid, int flavor, Pointer<Uint8> buffer);
typedef _ChildPidsC = Int32 Function(Int32 pid, Pointer<Int32> buffer, Int32 size);
typedef _ChildPidsDart = int Function(int pid, Pointer<Int32> buffer, int size);
typedef _NameC = Int32 Function(Int32 pid, Pointer<Uint8> buffer, Uint32 size);
typedef _NameDart = int Function(int pid, Pointer<Uint8> buffer, int size);
typedef _TimebaseC = Int32 Function(Pointer<Uint32> info);
typedef _TimebaseDart = int Function(Pointer<Uint32> info);
typedef _CallocC = Pointer<Void> Function(IntPtr count, IntPtr size);
typedef _CallocDart = Pointer<Void> Function(int count, int size);
typedef _FreeC = Void Function(Pointer<Void> p);
typedef _FreeDart = void Function(Pointer<Void> p);

/// libc 的 calloc / free(不为这几个缓冲区引入 package:ffi)。
class _Mem {
  _Mem(DynamicLibrary lib)
      : _calloc = lib.lookupFunction<_CallocC, _CallocDart>('calloc'),
        _free = lib.lookupFunction<_FreeC, _FreeDart>('free');

  final _CallocDart _calloc;
  final _FreeDart _free;

  Pointer<T> alloc<T extends NativeType>(int bytes) => _calloc(1, bytes).cast<T>();
  void free(Pointer p) => _free(p.cast());
}

class ProcessStatsSampler {
  ProcessStatsSampler() {
    if (Platform.isMacOS) {
      try {
        final lib = DynamicLibrary.process();
        _mem = _Mem(lib);
        _rusage = lib.lookupFunction<_RusageC, _RusageDart>('proc_pid_rusage');
        _childPids = lib.lookupFunction<_ChildPidsC, _ChildPidsDart>('proc_listchildpids');
        _name = lib.lookupFunction<_NameC, _NameDart>('proc_name');
        final timebase = lib.lookupFunction<_TimebaseC, _TimebaseDart>('mach_timebase_info');
        final info = _mem!.alloc<Uint32>(8);
        try {
          if (timebase(info) == 0 && info[1] != 0) _nanosPerTick = info[0] / info[1];
        } finally {
          _mem!.free(info);
        }
      } catch (_) {
        _rusage = null;
      }
    }
  }

  _Mem? _mem;
  _RusageDart? _rusage;
  _ChildPidsDart? _childPids;
  _NameDart? _name;
  double _nanosPerTick = 1;

  /// pid → (上次的 CPU 时间 ns, 采样时刻 µs)
  final Map<int, (int, int)> _last = {};

  bool get detailed => _rusage != null;

  ResourceSnapshot sample() {
    final rusage = _rusage;
    if (rusage == null) {
      return ResourceSnapshot([ProcessUsage(pid: pid, name: 'CodeLiteX', memoryBytes: ProcessInfo.currentRss)]);
    }
    final now = DateTime.now().microsecondsSinceEpoch;
    final pids = [pid, ..._descendants(pid)];
    final out = <ProcessUsage>[];
    final mem = _mem!;
    final buf = mem.alloc<Uint8>(256); // rusage_info_v0:16 字节 uuid 之后是一串 uint64
    try {
      for (final p in pids) {
        if (rusage(p, 0, buf) != 0) continue; // 进程已退出或无权限
        final words = buf.cast<Uint64>();
        // uuid 占 2 个 uint64;之后:user_time, system_time, pkg_idle_wkups, interrupt_wkups,
        // pageins, wired_size, resident_size, phys_footprint, ...
        final cpuNanos = ((words[2] + words[3]) * _nanosPerTick).round();
        final footprint = words[9];
        double? cpu;
        final last = _last[p];
        if (last != null && now > last.$2) {
          cpu = ((cpuNanos - last.$1) / 1000) / (now - last.$2) * 100;
          if (cpu < 0) cpu = 0;
        }
        _last[p] = (cpuNanos, now);
        out.add(ProcessUsage(pid: p, name: p == pid ? 'CodeLiteX' : _nameOf(p), memoryBytes: footprint, cpuPercent: cpu));
      }
    } finally {
      mem.free(buf);
    }
    _last.removeWhere((p, _) => !pids.contains(p));
    return ResourceSnapshot(out);
  }

  List<int> _descendants(int root) {
    final list = _childPids;
    if (list == null) return const [];
    final out = <int>[];
    final queue = [root];
    final mem = _mem!;
    final buf = mem.alloc<Int32>(256 * 4);
    try {
      while (queue.isNotEmpty && out.length < 200) {
        final p = queue.removeLast();
        final n = list(p, buf, 256 * 4);
        for (var i = 0; i < n && i < 256; i++) {
          final c = buf[i];
          if (c > 0 && !out.contains(c)) {
            out.add(c);
            queue.add(c);
          }
        }
      }
    } finally {
      mem.free(buf);
    }
    return out;
  }

  String _nameOf(int p) {
    final name = _name;
    if (name == null) return '$p';
    final mem = _mem!;
    final buf = mem.alloc<Uint8>(256);
    try {
      final n = name(p, buf, 256);
      if (n <= 0) return '$p';
      return String.fromCharCodes(buf.asTypedList(n));
    } finally {
      mem.free(buf);
    }
  }
}
