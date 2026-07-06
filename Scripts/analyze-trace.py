#!/usr/bin/env python3
"""Parse xctrace Time Profiler export, summarize hotspots, and suggest optimizations."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

APP_PREFIXES = (
    "bilibili",
    "gaoxipeng.bilibili",
    "VideoCover",
    "RemoteCover",
    "FeedVideo",
    "FeedCard",
    "FeedScroll",
    "HomeFeed",
    "BiliSVGPath",
    "BiliRaster",
    "LayerBacked",
)

SWIFTUI_MARKERS = (
    "SwiftUI",
    "NSHostingView",
    "ViewGraph",
    "AttributeGraph",
    "AG::",
    "LayoutEngine",
    "updateNSView",
)

GPU_MARKERS = (
    "CALayer",
    "CoreAnimation",
    "CA::",
    "render",
    "draw",
    "CGImage",
    "ImageIO",
    "vImage",
)

RECOMMENDATIONS = {
    "NSHostingView": "Feed 封面仍有 NSHostingView 嵌套；确认已使用 FeedVideoCoverHover。",
    "updateNSView": "Representable updateNSView 频繁；在 Coordinator 中跳过未变化的属性。",
    "AttributeGraph": "SwiftUI 属性图更新偏多；减少 @Published/@State 在滚动时的写入。",
    "ViewGraph": "SwiftUI 视图图重建；检查 LazyVGrid identity 与 hover binding。",
    "CALayer": "Core Animation 层操作；确认 hover 用 GPU transform 而非 SwiftUI scaleEffect。",
    "CGImageSource": "图片解码热点；确认 downsample maxPixelLength 与磁盘缓存命中。",
    "HoverSync": "滚动 hover 同步；检查 syncHoverToMouse 候选数量（应 < 10）。",
    "BiliSVGPathParser": "SVG 路径重复解析；已加 CGPath 缓存，确认热点是否下降。",
    "SVGAttributeMap": "Asset Catalog 矢量图标在滚动时重栅格化；BiliIconView 已改为位图缓存。",
}


def find_xctrace() -> str:
    candidates = [
        Path("/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xctrace"),
        Path("/Applications/Xcode.app/Contents/Developer/usr/bin/xctrace"),
    ]
    for path in candidates:
        if path.is_file():
            return str(path)
    found = subprocess.run(["which", "xctrace"], capture_output=True, text=True)
    if found.returncode == 0 and found.stdout.strip():
        return found.stdout.strip()
    raise SystemExit("xctrace not found. Install Xcode and set DEVELOPER_DIR.")


def export_toc(xctrace: str, trace_path: Path, out_path: Path) -> None:
    subprocess.run(
        [xctrace, "export", "--input", str(trace_path), "--toc", "--output", str(out_path)],
        check=True,
        capture_output=True,
        text=True,
    )


def export_table(xctrace: str, trace_path: Path, xpath: str, out_path: Path) -> bool:
    result = subprocess.run(
        [
            xctrace,
            "export",
            "--input",
            str(trace_path),
            "--xpath",
            xpath,
            "--output",
            str(out_path),
        ],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0 and out_path.exists() and out_path.stat().st_size > 0


def discover_schemas(toc_path: Path) -> list[tuple[str, str]]:
    tree = ET.parse(toc_path)
    root = tree.getroot()
    schemas: list[tuple[str, str]] = []
    for run in root.findall(".//run"):
        run_number = run.attrib.get("number", "1")
        data = run.find("data")
        if data is None:
            continue
        for table in data.findall("table"):
            schema = table.attrib.get("schema")
            if not schema:
                continue
            xpath = f'/trace-toc/run[@number="{run_number}"]/data/table[@schema="{schema}"]'
            schemas.append((schema, xpath))
    seen: set[str] = set()
    unique: list[tuple[str, str]] = []
    for schema, xpath in schemas:
        if schema in seen:
            continue
        seen.add(schema)
        unique.append((schema, xpath))
    return unique


def summarize_time_profile_frames(table_path: Path, top_n: int) -> list[tuple[str, float, int]]:
    tree = ET.parse(table_path)
    root = tree.getroot()
    counts: dict[str, int] = defaultdict(int)

    for row in root.findall(".//row"):
        backtrace = row.find("tagged-backtrace")
        if backtrace is None:
            continue
        seen: set[str] = set()
        for frame in backtrace.findall("frame"):
            name = frame.attrib.get("name", "")
            if not name or name in seen:
                continue
            seen.add(name)
            counts[name] += 1

    ranked = sorted(counts.items(), key=lambda item: item[1], reverse=True)
    return [(symbol, float(count), count) for symbol, count in ranked[:top_n]]


def summarize_hitches(table_path: Path) -> list[str]:
    if not table_path.exists():
        return []
    tree = ET.parse(table_path)
    root = tree.getroot()
    durations: list[float] = []
    reasons: dict[str, int] = defaultdict(int)
    for row in root.findall(".//row"):
        dur = row.find("duration")
        fmt = dur.attrib.get("fmt", "") if dur is not None else ""
        ms = 0.0
        if "ms" in fmt:
            ms = float(fmt.replace("ms", "").strip())
        durations.append(ms)
        strings = [s.attrib.get("fmt", "") for s in row.findall("string")]
        reason = strings[-1] if strings else ""
        reasons[reason or "(frame hitch)"] += 1

    if not durations:
        return []

    lines = ["=== Animation Hitches ==="]
    lines.append(f"  count: {len(durations)}")
    lines.append(f"  total: {sum(durations):.1f} ms")
    lines.append(f"  avg:   {sum(durations) / len(durations):.2f} ms")
    lines.append(f"  max:   {max(durations):.2f} ms")
    p95 = sorted(durations)[int(len(durations) * 0.95)]
    lines.append(f"  p95:   {p95:.2f} ms")
    lines.append("  reasons:")
    for reason, count in sorted(reasons.items(), key=lambda item: item[1], reverse=True)[:6]:
        lines.append(f"    {count:4d}  {reason}")
    lines.append("")
    return lines


def parse_weight(value: str | None) -> float:
    if not value:
        return 0.0
    text = value.strip()
    match = re.match(r"([0-9]+(?:\.[0-9]+)?)\s*(s|ms|us|µs|ns)?", text)
    if not match:
        return 0.0
    amount = float(match.group(1))
    unit = match.group(2) or "s"
    if unit == "ms":
        return amount / 1000
    if unit in {"us", "µs"}:
        return amount / 1_000_000
    if unit == "ns":
        return amount / 1_000_000_000
    return amount


def summarize_time_profile(table_path: Path, top_n: int) -> list[tuple[str, float, int]]:
    tree = ET.parse(table_path)
    root = tree.getroot()
    rows = root.findall(".//row")
    if not rows:
        return []

    sample = rows[0]
    columns = [col.attrib.get("id", "") for col in sample.findall("sentinel") + sample.findall("cell")]

    symbol_idx = None
    weight_idx = None
    for idx, col_id in enumerate(columns):
        lowered = col_id.lower()
        if symbol_idx is None and any(k in lowered for k in ("symbol", "function", "name")):
            symbol_idx = idx
        if weight_idx is None and any(k in lowered for k in ("weight", "time", "self")):
            weight_idx = idx

    totals: dict[str, float] = defaultdict(float)
    counts: dict[str, int] = defaultdict(int)

    for row in rows:
        cells = row.findall("sent")
        if not cells:
            cells = [c.text or "" for c in row.findall("cell")]
        else:
            cells = [c.text or "" for c in cells]

        if not cells:
            continue

        symbol = cells[symbol_idx or 0].strip() if symbol_idx is not None else cells[0].strip()
        weight_text = cells[weight_idx or min(1, len(cells) - 1)] if cells else ""
        weight = parse_weight(weight_text if isinstance(weight_text, str) else str(weight_text))
        if not symbol or weight <= 0:
            continue
        totals[symbol] += weight
        counts[symbol] += 1

    ranked = sorted(totals.items(), key=lambda item: item[1], reverse=True)
    return [(symbol, weight, counts[symbol]) for symbol, weight in ranked[:top_n]]


def classify_symbol(symbol: str) -> str:
    lowered = symbol.lower()
    if any(marker.lower() in lowered for marker in APP_PREFIXES):
        return "app"
    if any(marker.lower() in lowered for marker in SWIFTUI_MARKERS):
        return "swiftui"
    if any(marker.lower() in lowered for marker in GPU_MARKERS):
        return "gpu"
    return "system"


def bucket_summary(ranked: list[tuple[str, float, int]]) -> dict[str, float]:
    buckets: dict[str, float] = defaultdict(float)
    for symbol, weight, _ in ranked:
        buckets[classify_symbol(symbol)] += weight
    return buckets


def recommendations_for(ranked: list[tuple[str, float, int]]) -> list[str]:
    tips: list[str] = []
    seen: set[str] = set()
    for symbol, _, _ in ranked:
        for key, tip in RECOMMENDATIONS.items():
            if key in symbol and key not in seen:
                tips.append(tip)
                seen.add(key)
    if not tips:
        tips.append("未发现明显模板热点；在 Instruments 中查看 Hitches 轨道对比 home vs scrollTest。")
    return tips


def analyze_trace(trace_path: Path, out_dir: Path, top_n: int, section: str | None) -> str:
    xctrace = find_xctrace()
    out_dir.mkdir(parents=True, exist_ok=True)
    toc_path = out_dir / "toc.xml"
    export_toc(xctrace, trace_path, toc_path)

    schemas = discover_schemas(toc_path)
    preferred = ["time-profile", "hitches", "time-profile-call-tree", "time-profile-flat", "ktrace"]
    ordered = sorted(
        schemas,
        key=lambda item: (
            next((i for i, p in enumerate(preferred) if p in item[0]), len(preferred)),
            item[0],
        ),
    )

    lines: list[str] = []
    lines.append(f"Trace: {trace_path}")
    if section:
        lines.append(f"Section: {section}")
    lines.append("")

    best_ranked: list[tuple[str, float, int]] = []
    for schema, xpath in ordered:
        table_path = out_dir / f"{schema}.xml"
        if not export_table(xctrace, trace_path, xpath, table_path):
            continue
        if schema == "hitches":
            lines.extend(summarize_hitches(table_path))
            continue

        ranked = summarize_time_profile(table_path, top_n)
        if schema == "time-profile" and not ranked:
            ranked = summarize_time_profile_frames(table_path, top_n)

        if not ranked:
            continue
        if len(ranked) > len(best_ranked):
            best_ranked = ranked
        lines.append(f"=== {schema} (top {top_n}) ===")
        for idx, (symbol, weight, count) in enumerate(ranked, start=1):
            tag = classify_symbol(symbol)
            if schema == "time-profile":
                lines.append(f"{idx:2d}. [{tag:7s}] {weight:8.0f} smp  x{count:<4d}  {symbol}")
            else:
                lines.append(f"{idx:2d}. [{tag:7s}] {weight * 1000:8.2f} ms  x{count:<4d}  {symbol}")
        lines.append("")

    if best_ranked:
        buckets = bucket_summary(best_ranked)
        total = sum(buckets.values()) or 1
        lines.append("=== Category breakdown (sample counts) ===")
        for name in ("app", "swiftui", "gpu", "system"):
            if name in buckets:
                pct = buckets[name] / total * 100
                lines.append(f"  {name:8s}: {buckets[name]:8.0f} smp  ({pct:5.1f}%)")
        lines.append("")
        lines.append("=== Suggested next steps ===")
        for tip in recommendations_for(best_ranked):
            lines.append(f"  • {tip}")

    if not best_ranked:
        lines.append("No exportable time-profile tables found.")
        for schema, _ in schemas:
            lines.append(f"  schema: {schema}")

    return "\n".join(lines)


def load_profile_ranked(out_dir: Path, top_n: int) -> list[tuple[str, float, int]]:
    table_path = out_dir / "time-profile.xml"
    if table_path.exists():
        ranked = summarize_time_profile_frames(table_path, top_n)
        if ranked:
            return ranked
        ranked = summarize_time_profile(table_path, top_n)
        if ranked:
            return ranked
    table_path = out_dir / "time-profile-flat.xml"
    if table_path.exists():
        return summarize_time_profile(table_path, top_n)
    return []


def hitch_summary_lines(table_path: Path) -> list[str]:
    return summarize_hitches(table_path) if table_path.exists() else []


def compare_traces(baseline: Path, candidate: Path, out_dir: Path, top_n: int) -> str:
    out_dir.mkdir(parents=True, exist_ok=True)
    base_dir = out_dir / "baseline"
    cand_dir = out_dir / "candidate"
    base_report = analyze_trace(baseline, base_dir, top_n, "home")
    cand_report = analyze_trace(candidate, cand_dir, top_n, "scrollTest")

    base_ranked = load_profile_ranked(base_dir, top_n)
    cand_ranked = load_profile_ranked(cand_dir, top_n)

    base_map = {symbol: weight for symbol, weight, _ in base_ranked}
    cand_map = {symbol: weight for symbol, weight, _ in cand_ranked}

    lines: list[str] = []
    lines.append("=== Home vs ScrollTest comparison ===")
    lines.append("")
    lines.extend(hitch_summary_lines(base_dir / "hitches.xml"))
    if hitch_summary_lines(cand_dir / "hitches.xml"):
        lines.append("--- scrollTest hitches ---")
        lines.extend(hitch_summary_lines(cand_dir / "hitches.xml"))

    lines.append(f"{'Symbol':<60s}  {'Home smp':>10s}  {'Test smp':>10s}  {'Delta':>10s}")
    all_symbols = sorted(
        set(base_map) | set(cand_map),
        key=lambda s: max(base_map.get(s, 0), cand_map.get(s, 0)),
        reverse=True,
    )
    for symbol in all_symbols[:top_n]:
        base_count = base_map.get(symbol, 0)
        cand_count = cand_map.get(symbol, 0)
        delta = cand_count - base_count
        lines.append(f"{symbol[:60]:<60s}  {base_count:10.0f}  {cand_count:10.0f}  {delta:+10.0f}")

    home_swiftui = sum(w for s, w, _ in base_ranked if classify_symbol(s) == "swiftui")
    test_swiftui = sum(w for s, w, _ in cand_ranked if classify_symbol(s) == "swiftui")
    lines.append("")
    lines.append(f"SwiftUI/AG samples: home={home_swiftui:.0f}  scrollTest={test_swiftui:.0f}  delta={test_swiftui - home_swiftui:+.0f}")
    lines.append("")
    lines.append("Interpretation:")
    if home_swiftui > test_swiftui * 1.2:
        lines.append("  • SwiftUI/AttributeGraph 在 home 更高 → feed metadata/hover 仍是主要差异")
    else:
        lines.append("  • SwiftUI 采样接近，home 额外开销主要来自封面/metadata 组合而非 AG 本身")
    lines.append("  • Hitch 对比见上方 Animation Hitches 区块")

    report = "\n".join(lines)
    (out_dir / "comparison.txt").write_text(report + "\n\n" + base_report + "\n\n" + cand_report, encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description="Summarize xctrace Time Profiler recording")
    parser.add_argument("trace", nargs="?", type=Path, help="Path to .trace directory")
    parser.add_argument("--top", type=int, default=40, help="Top N symbols to show")
    parser.add_argument("--out-dir", type=Path, help="Directory for exported XML (default: trace dir)")
    parser.add_argument("--section", type=str, help="Profiled app section label")
    parser.add_argument("--compare", nargs=2, metavar=("BASELINE", "CANDIDATE"), type=Path)
    args = parser.parse_args()

    if args.compare:
        out_dir = (args.out_dir or Path("perf-traces/compare")).resolve()
        report = compare_traces(args.compare[0].resolve(), args.compare[1].resolve(), out_dir, args.top)
        print(report)
        print(f"\nWrote {out_dir / 'comparison.txt'}")
        return

    if not args.trace:
        parser.error("trace path required unless --compare is used")

    trace_path = args.trace.resolve()
    out_dir = (args.out_dir or trace_path.parent).resolve()
    report = analyze_trace(trace_path, out_dir, args.top, args.section)
    summary_path = out_dir / "hotspots.txt"
    summary_path.write_text(report, encoding="utf-8")
    print(report)
    print(f"\nWrote {summary_path}")


if __name__ == "__main__":
    main()
