#!/usr/bin/env bash
# 界面性能测量:profile 模式驱动真实应用跑几个典型场景(空闲、2 万行文件滚动 / 输入、
# 大仓库文件树、Git 日志),输出帧耗时、CPU 热点、内存。结果在 apps/code_lite_ui/build/perf/。
#
#   bash scripts/measure_ui_perf.sh            # 帧耗时 + CPU 热点 + 内存
#   PERF_TRACE=false bash scripts/measure_ui_perf.sh   # 只量内存(不录时间线,堆统计更干净)
#   PERF_REPO=/path/to/big/repo bash scripts/measure_ui_perf.sh
#
# 注意:
#   * profile / debug 构建默认开着 macOS 沙盒(正式版没开),沙盒里读不到项目目录;
#     这里临时关掉,结束时(包括失败)改回来,并清掉 macOS 构建缓存(Xcode 不允许增量构建
#     时 entitlements 变过)。
#   * 测量会打开项目,写进 ~/.codelitex/recent_projects.json;先备份,结束时还原。
#   * 请先退出正在运行的 CodeLiteX,免得两个实例互相干扰。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/code_lite_ui"
FLUTTER="${FLUTTER:-/Users/dev/development/flutter/bin/flutter}"
ENT="$APP/macos/Runner/DebugProfile.entitlements"
RECENT="$HOME/.codelitex/recent_projects.json"
TMP="$(mktemp -d)"

cp "$ENT" "$TMP/entitlements"
[ -f "$RECENT" ] && cp "$RECENT" "$TMP/recent.json"

restore() {
  cp "$TMP/entitlements" "$ENT"
  if [ -f "$TMP/recent.json" ]; then cp "$TMP/recent.json" "$RECENT"; fi
  rm -rf "$APP/build/macos" "$TMP"
}
trap restore EXIT

/usr/bin/sed -i '' '/com.apple.security.app-sandbox/{n;s#<true/>#<false/>#;}' "$ENT"
rm -rf "$APP/build/macos" "$APP/build/perf"

cd "$APP"
"$FLUTTER" drive --profile -d macos \
  --dart-define=PERF_TRACE="${PERF_TRACE:-true}" \
  ${PERF_REPO:+--dart-define=PERF_REPO="$PERF_REPO"} \
  --driver=test_driver/perf_driver.dart --target=integration_test/perf_test.dart

python3 - "$APP/build/perf" <<'PY'
import json, os, sys
d = sys.argv[1]
order = ['idle_no_project', 'idle_editor_caret', 'editor_scroll', 'editor_typing', 'tree_scroll', 'git_log_scroll', 'idle_git_window']
mem = json.load(open(f'{d}/memory.json'))
if os.path.exists(f'{d}/editor_scroll.timeline_summary.json'):
    print(f"{'场景':18}{'帧数':>6}{'构建均值':>9}{'p90':>7}{'p99':>7}{'最差':>7}{'超时帧':>6} |{'光栅均值':>8}{'最差':>7} | 内存 起/峰/止 MB")
    for s in order:
        t = json.load(open(f'{d}/{s}.timeline_summary.json')); m = mem[s]
        g = lambda k: t.get(k, float('nan'))
        print(f"{s:18}{g('frame_count'):>6}{g('average_frame_build_time_millis'):>9.2f}{g('90th_percentile_frame_build_time_millis'):>7.2f}"
              f"{g('99th_percentile_frame_build_time_millis'):>7.2f}{g('worst_frame_build_time_millis'):>7.2f}{g('missed_frame_build_budget_count'):>6} |"
              f"{g('average_frame_rasterizer_time_millis'):>8.2f}{g('worst_frame_rasterizer_time_millis'):>7.2f} | {m['start_mb']}/{m['peak_mb']}/{m['end_mb']}")
    sc = json.load(open(f'{d}/scenarios.json'))
    for s in ('editor_typing', 'editor_scroll'):
        cpu = sc.get(s, {}).get('cpu')
        if cpu:
            print(f"\n{s} CPU 自身耗时前 5:")
            for r in cpu['top_self'][:5]:
                print(f"  {r['pct']:>5}%  {r['fn']}")
c = json.load(open(f'{d}/census.json'))
traced = os.path.exists(f'{d}/editor_scroll.timeline_summary.json')
print('\nGC 后存活的 Dart 堆' + (':(录了时间线,里面混有测量自己存的时间线数据;要干净的内存数请用 PERF_TRACE=false)' if traced else ':'))
for label, v in c.items():
    if isinstance(v, dict):
        top = ', '.join(f"{r['class'].split(' ')[0]} {r['mb']}MB" for r in v['top'][:3])
        print(f"  {label:28} {v['live_heap_mb']:>6} MB  (footprint {v['footprint_mb']} MB)  {top}")
PY
