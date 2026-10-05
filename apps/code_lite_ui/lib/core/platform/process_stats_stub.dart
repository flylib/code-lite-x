// web:拿不到进程信息。

class ProcessUsage {
  const ProcessUsage({required this.pid, required this.name, required this.memoryBytes, this.cpuPercent});
  final int pid;
  final String name;
  final int memoryBytes;
  final double? cpuPercent;
}

class ResourceSnapshot {
  const ResourceSnapshot(this.processes);
  final List<ProcessUsage> processes;
  int get totalMemoryBytes => processes.fold(0, (s, p) => s + p.memoryBytes);
  double? get totalCpuPercent => null;
}

class ProcessStatsSampler {
  bool get detailed => false;
  ResourceSnapshot sample() => const ResourceSnapshot([]);
}
