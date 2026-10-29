#!/usr/bin/env python3
"""Retarget Metal shaders to the MetalBridge A9/MSL 1.2-safe subset.

The bridge compiles its own shaders with `-std=ios-metal1.2` for the Apple A9
baseline (iOS GPU family 3). Game shaders written against Metal 2/3/4-era MSL
use constructs that either fail to compile or silently misbehave on that
subset. This tool scans `.metal` sources and reports every construct outside
the subset, and applies the two mechanical rewrites the project has validated
on the host toolchain:

- MSL2-TPG  `[[threads_per_grid]]`        -> reserved buffer(29)
- MSL2-TGPG `[[threadgroups_per_grid]]`   -> reserved buffer(30)
- MSL2-TPTG `[[threads_per_threadgroup]]` -> reserved buffer(31)

The rewrite reuses the shader's own parameter name for the prologue value, so
the kernel body is never touched. The host must bind an 8-byte `uint2` buffer
at the reserved slot with the same value it passed to `dispatchThreads`. See
docs/COMPAT_SHADER.md for the contract and the padded-grid pitfall that
motivated the rewrite.

Usage:
    python3 Tools/metal_retarget.py PATH [PATH ...] [--strict] [--json] [--stdout]
    python3 Tools/metal_retarget.py --selftest

PATH may be a `.metal` file or a directory (scanned recursively). Each file
with rewrites gets a sibling `<stem>.compat.metal`. Findings are printed as
`path:line: [severity] rule: message`. Exit code is 1 with --strict when any
unsupported or partial finding exists.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------

SEVERITY_ORDER = {"rewrite": 0, "partial": 1, "unsupported": 2}

# Report-only rules. (rule id, severity, compiled regex, message)
REPORT_RULES = [
    ("MSL3-RT", "unsupported",
     re.compile(r"\bmetal::raytracing\b|\bray_data\b|\bintersector\b|\bacceleration_structure\b|\[\[intersection\]\]"),
     "Ray tracing needs Metal 3 hardware; not available on the A9 baseline."),
    ("MSL3-MESH", "unsupported",
     re.compile(r"\[\[mesh\]\]|\bmesh\s*<|\bobject\s+void\b|\bmetal::mesh\b"),
     "Mesh and object shaders need Metal 3; not available on the A9 baseline."),
    ("MSL2-FC", "unsupported",
     re.compile(r"\[\[function_constant\("),
     "Function constants need Metal 2; specialize at build time instead."),
    ("MSL2-MTPT", "unsupported",
     re.compile(r"\[\[max_total_threads_per_threadgroup\("),
     "This launch bound needs Metal 2; state the bound in the Swift host."),
    ("MSL2-TGMEM", "unsupported",
     re.compile(r"\[\[threadgroup\(\d+\)\]\]"),
     "Threadgroup-memory kernel parameters need Metal 2; use a threadgroup_local declaration instead."),
    ("MSL2-ARG", "unsupported",
     re.compile(r"\[\[argument\]\]"),
     "Argument-buffer structs need Metal 2; use explicit buffer/texture indices. "
     "MetalBridgeKit's ArgumentReplayEncoder covers the host side."),
    ("MSL2-ROG", "unsupported",
     re.compile(r"\[\[raster_order_group\(\d+\)\]\]"),
     "Raster-order groups need imageblocks (Apple GPU family 7); unsupported on A9."),
    ("MSL2-EFT", "unsupported",
     re.compile(r"\[\[early_fragment_tests\]\]"),
     "Early fragment tests need Metal 2; declare the test behavior in the pipeline descriptor."),
    ("MSL3-ATOM64", "unsupported",
     re.compile(r"\batomic_(?:u?long|u?int64_t|u?int64|int64)\b"),
     "64-bit atomics need Metal 3; restructure around 32-bit atomics or a per-cell spin buffer."),
    ("MSL2-SIMD", "partial",
     re.compile(r"\[\[thread_index_in_simdgroup\]\]|\[\[simdgroups_in_threadgroup\]\]"
                r"|\bsimd_(?:shuffle|sum|product|max|min|and|or|xor|all|any|prefix"
                r"|exclusive|inclusive|ballot|vote)\b"),
     "SIMD-group operations are not guaranteed on the A9 baseline; gate on runtime capabilities."),
    ("MSL3-FP16", "partial",
     re.compile(r"\bfloat16_t\b"),
     "FP16 arithmetic needs Apple GPU family 7; on A9 use half only as a storage format."),
    ("MSL2-RWTEX", "partial",
     re.compile(r"access::read_write"),
     "Read-write textures are a tier-2 feature; confirm at runtime through BridgeCapabilities."),
]

# Metal-2 grid attributes that compile under -std=ios-metal1.2 but are unsafe.
# `[[threads_per_grid]]` was observed returning the *padded* dispatch grid on
# the host toolchain (dispatchThreads rounds up to whole threadgroups), so the
# only correct path is an explicit uniform. Reserved buffer slots:
GRID_ATTRIBUTES = [
    ("MSL2-TPG", "threads_per_grid", 29),
    ("MSL2-TGPG", "threadgroups_per_grid", 30),
    ("MSL2-TPTG", "threads_per_threadgroup", 31),
]

# Strippable Metal namespaces. Sub-namespaces map onto global builtins, so the
# full chain is stripped (`metal::math::floor` -> `floor`). `metal::raytracing`
# is caught by MSL3-RT and never stripped.
NAMESPACE_SUBNS = re.compile(r"\bmetal::(?:math|geometric|common)::")
NAMESPACE_STRIP = re.compile(r"\bmetal::(?!raytracing\b)")


# ---------------------------------------------------------------------------
# Findings and rewrites
# ---------------------------------------------------------------------------

class Finding:
    __slots__ = ("path", "line", "severity", "rule", "message")

    def __init__(self, path, line, severity, rule, message):
        self.path = path
        self.line = line
        self.severity = severity
        self.rule = rule
        self.message = message

    def as_line(self):
        return f"{self.path}:{self.line}: [{self.severity}] {self.rule}: {self.message}"


def _line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def mask_comments(text):
    """Replace comment interiors with spaces, preserving every offset.

    Attributes inside comments must not trigger rules; the shipped shaders
    deliberately document the padded-grid pitfall inside comments.
    """
    out = list(text)
    index = 0
    length = len(text)
    in_block = False
    while index < length:
        if in_block:
            if text.startswith("*/", index):
                out[index] = " "
                out[index + 1] = " "
                index += 2
                in_block = False
            else:
                if text[index] != "\n":
                    out[index] = " "
                index += 1
        elif text.startswith("//", index):
            while index < length and text[index] != "\n":
                out[index] = " "
                index += 1
        elif text.startswith("/*", index):
            out[index] = " "
            out[index + 1] = " "
            index += 2
            in_block = True
        elif text.startswith('"', index):
            index += 1
            while index < length and text[index] != '"':
                if text[index] == "\\":
                    index += 1
                index += 1
            index += 1
        else:
            index += 1
    return "".join(out)


def scan(text, path="<text>"):
    findings = []
    masked = mask_comments(text)
    for rule_id, severity, pattern, message in REPORT_RULES:
        for match in pattern.finditer(text):
            findings.append(Finding(path, _line_of(text, match.start()),
                                    severity, rule_id, message))
    for rule_id, attribute, _slot in GRID_ATTRIBUTES:
        for match in re.finditer(r"\[\[" + attribute + r"\]\]", masked):
            findings.append(Finding(path, _line_of(text, match.start()),
                                    "rewrite", rule_id,
                                    f"[[{attribute}]] is a Metal-2 attribute; "
                                    f"rewritten to a reserved uniform (see the report's rewrite count)."))
    return findings


def _balanced_paren_end(text, open_index):
    depth = 0
    for index in range(open_index, len(text)):
        char = text[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    return None


def rewrite(text):
    """Apply the grid-attribute rewrites. Returns (new_text, applied, notes, stripped)."""
    applied = 0
    notes = []
    new_text = text
    for rule_id, attribute, slot in GRID_ATTRIBUTES:
        pattern = re.compile(r"([\w:]+(?:\s*[*&])?)\s+(\w+)\s*\[\[" + attribute + r"\]\]")
        while True:
            # Match on a comment-masked copy; edit the original text. Both
            # strings have identical lengths, so offsets line up.
            masked = mask_comments(new_text)
            match = pattern.search(masked)
            if not match:
                break
            type_name, param_name = match.group(1), match.group(2)
            span_start, span_end = match.start(), match.end()
            # Remove the attributed parameter.
            new_text = new_text[:span_start] + new_text[span_end:]
            # Collapse a doubled separator comma.
            if new_text[span_start] == ",":
                new_text = new_text[:span_start] + new_text[span_start + 1:]
            # Find the enclosing parameter list.
            open_paren = new_text.rfind("(", 0, span_start)
            if open_paren == -1:
                break
            close_paren = _balanced_paren_end(new_text, open_paren)
            if close_paren is None:
                break
            # Insert the uniform. Skip the leading comma when the list is
            # empty or already comma-terminated by the previous parameter.
            head = new_text[:close_paren].rstrip()
            uniform = f"constant uint2& mb_{attribute} [[buffer({slot})]]"
            if head.endswith(","):
                insertion = uniform
            elif head.endswith("("):
                insertion = " " + uniform
            else:
                insertion = ", " + uniform
            new_text = new_text[:close_paren] + insertion + new_text[close_paren:]
            close_paren = _balanced_paren_end(new_text, open_paren)
            # Insert the prologue after the body's opening brace.
            body_brace = new_text.find("{", close_paren)
            if body_brace == -1:
                break
            prologue = f"\n    {type_name} {param_name} = mb_{attribute};"
            new_text = new_text[:body_brace + 1] + prologue + new_text[body_brace + 1:]
            applied += 1
            notes.append((rule_id, attribute, slot, param_name))
    # Namespace strip.
    stripped_count = len(NAMESPACE_SUBNS.findall(new_text))
    new_text = NAMESPACE_SUBNS.sub("", new_text)
    stripped_count += len(NAMESPACE_STRIP.findall(new_text))
    if stripped_count:
        new_text = NAMESPACE_STRIP.sub("", new_text)
    return new_text, applied, notes, stripped_count


# ---------------------------------------------------------------------------
# File handling
# ---------------------------------------------------------------------------

def collect_metal_files(paths, include_headers=False):
    extensions = {".metal"} | ({".h"} if include_headers else set())
    files = []
    for path_text in paths:
        path = Path(path_text)
        if path.is_dir():
            for extension in sorted(extensions):
                files.extend(sorted(path.rglob(f"*{extension}")))
        elif path.suffix in extensions:
            files.append(path)
        else:
            raise SystemExit(f"Not a .metal file or directory: {path}")
    return files


def retarget_file(path, write_output, emit_json):
    text = path.read_text(errors="replace")
    findings = scan(text, path=path)
    new_text, applied, notes, stripped = rewrite(text)
    if applied or stripped:
        if write_output:
            out_path = path.with_name(path.stem + ".compat.metal")
            out_path.write_text(new_text)
    if applied or stripped or findings:
        return findings, applied, notes, stripped
    return findings, 0, [], 0


# ---------------------------------------------------------------------------
# Self test
# ---------------------------------------------------------------------------

CASE_TPG = """kernel void shade(uint2 tid [[thread_position_in_grid]],
                       uint2 grid [[threads_per_grid]]) {
    if (tid.x >= 10) { return; }
}
"""
CASE_TPG_EXPECTED = """kernel void shade(uint2 tid [[thread_position_in_grid]],
                       constant uint2& mb_threads_per_grid [[buffer(29)]]) {
    uint2 grid = mb_threads_per_grid;
    if (tid.x >= 10) { return; }
}
"""
CASE_GRID_FIRST = """kernel void lead(uint2 g [[threads_per_grid]], uint2 tid [[thread_position_in_grid]]) { int x = 1; }
"""
CASE_GRID_ONLY = """kernel void solo(uint2 g [[threads_per_grid]]) { int x = 1; }
"""
CASE_TPG_NEG = CASE_TPG.replace("grid [[threads_per_grid]]", "grid")
CASE_MULTI = """kernel void a(uint2 tid [[thread_position_in_grid]], uint2 g [[threads_per_grid]], uint2 t [[threads_per_threadgroup]]) { int x = 1; }
kernel void b(uint2 tid [[thread_position_in_grid]], uint2 tg [[threadgroups_per_grid]]) { int y = 2; }
"""
CASE_NS = """#include <metal_stdlib>
using namespace metal;
kernel void f(uint2 tid [[thread_position_in_grid]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    float4 c = tex.sample(s, metal::math::floor(float2(0.5)));
    float2 a = metal::abs(float2(1.0)) + metal::geometric::reflect(float2(1), float2(0));
}
"""
CASE_RT = """#include <metal_raytracing>
using namespace metal::raytracing;
intersector<instancing> its;
"""
CASE_UNSUPPORTED = """kernel void g(constant uint& x [[buffer(0)]]) {
    atomic_fetch_add_explicit((device atomic_uint64_t*)x, 1u, metal::memory_order_relaxed);
    float16_t h = 1;
}
"""
CASE_SIMD = """kernel void s(uint i [[thread_index_in_simdgroup]]) {
    float total = simd_sum(float(i));
}
"""


def selftest():
    failures = []

    def expect(condition, label):
        if not condition:
            failures.append(label)

    # 1. Rewrite reuses the author's parameter name and produces valid MSL.
    new, applied, notes, stripped = rewrite(CASE_TPG)
    expect(applied == 1, f"tpg applied {applied}")
    expect(new == CASE_TPG_EXPECTED, f"tpg exact output:\n{new}")
    expect("uint2 grid = mb_threads_per_grid;" in new, "prologue reuses 'grid'")
    # The negative case (no attribute) must be untouched.
    neg_new, neg_applied, _, _ = rewrite(CASE_TPG_NEG)
    expect(neg_applied == 0 and neg_new == CASE_TPG_NEG, "no-attribute file untouched")
    # Grid parameter first in the list: no doubled separator comma.
    new, applied, _, _ = rewrite(CASE_GRID_FIRST)
    expect(applied == 1, f"grid-first applied {applied}")
    expect("tid [[thread_position_in_grid]], constant uint2& mb_threads_per_grid [[buffer(29)]]" in new,
           f"grid-first output:\n{new}")
    expect(",, " not in new and ", ," not in new, "no doubled commas")
    # Grid parameter is the only parameter: empty list handled.
    new, applied, _, _ = rewrite(CASE_GRID_ONLY)
    expect(applied == 1, f"grid-only applied {applied}")
    expect("( constant uint2& mb_threads_per_grid [[buffer(29)]])" in new,
           f"grid-only output:\n{new}")

    # 2. Multiple kernels, multiple attributes.
    new, applied, notes, _ = rewrite(CASE_MULTI)
    expect(applied == 3, f"multi applied {applied}")
    expect("[[buffer(29)]]" in new and "[[buffer(30)]]" in new and "[[buffer(31)]]" in new,
           "slots 29/30/31 all used")
    expect("uint2 g = mb_threads_per_grid;" in new, "prologue for g")
    expect("uint2 t = mb_threads_per_threadgroup;" in new, "prologue for t")
    expect("uint2 tg = mb_threadgroups_per_grid;" in new, "prologue for tg")

    # 3. Comment masking: the shipped shaders document the pitfall in
    # comments and must not be rewritten or reported.
    commented = "kernel void c() {\n    // [[threads_per_grid]] reports the padded size\n}\n"
    findings = scan(commented, "c.metal")
    expect(not findings, f"comment-only attribute not reported: {findings}")
    new, applied, _, _ = rewrite(commented)
    expect(applied == 0 and new == commented, "comment-only file untouched")

    # 4. Namespace strip, including metal::math::; raytracing not stripped.
    new, applied, _, stripped = rewrite(CASE_NS)
    expect(applied == 0, "namespace-only file has no attribute rewrites")
    expect(stripped == 3, f"namespace strip count {stripped}")
    expect("metal::math" not in new and "floor(float2(0.5))" in new, "metal::math:: mapped to global builtin")
    expect("metal::abs" not in new and "abs(float2(1.0))" in new, "metal:: mapped to global")
    expect("reflect(float2(1), float2(0))" in new, "metal::geometric:: mapped to global")
    expect("metal::raytracing" not in new, "no raytracing in this case")
    rt_new, _, _, _ = rewrite(CASE_RT)
    expect("metal::raytracing" in rt_new, "raytracing namespace NOT stripped")

    # 4. Unsupported and partial detection.
    findings = scan(CASE_RT, "rt.metal")
    expect(any(f.rule == "MSL3-RT" for f in findings), "RT rule fires")
    findings = scan(CASE_UNSUPPORTED, "u.metal")
    expect(any(f.rule == "MSL3-ATOM64" and f.severity == "unsupported" for f in findings),
           "64-bit atomic flagged")
    expect(any(f.rule == "MSL3-FP16" and f.severity == "partial" for f in findings),
           "float16_t flagged partial")
    findings = scan(CASE_SIMD, "s.metal")
    expect(any(f.rule == "MSL2-SIMD" for f in findings), "simd rule fires")
    findings = scan(CASE_NS, "ns.metal")
    expect(not findings, f"clean namespace file has no findings: {findings}")

    # 5. Findings carry correct line numbers.
    findings = scan(CASE_MULTI, "m.metal")
    tpg_lines = {f.line for f in findings if f.rule == "MSL2-TPG"}
    expect(tpg_lines == {1}, f"tpg line {tpg_lines}")
    tgpg_lines = {f.line for f in findings if f.rule == "MSL2-TGPG"}
    expect(tgpg_lines == {2}, f"tgpg line {tgpg_lines}")

    if failures:
        print("SELFTEST FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("metal_retarget selftest: all cases passed")
    return 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("paths", nargs="*", help=".metal files or directories")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 if any unsupported or partial finding exists")
    parser.add_argument("--json", action="store_true", help="emit findings as JSON")
    parser.add_argument("--stdout", action="store_true",
                        help="print rewritten sources instead of writing files")
    parser.add_argument("--headers", action="store_true",
                        help="also scan .h shader headers (function constants and argument "
                             "buffers often live there behind preprocessor guards)")
    parser.add_argument("--selftest", action="store_true", help="run built-in tests")
    args = parser.parse_args()

    if args.selftest:
        sys.exit(selftest())
    if not args.paths:
        parser.error("no paths given")

    results = []
    strict_hit = False
    for path in collect_metal_files(args.paths, include_headers=args.headers):
        findings, applied, notes, stripped = retarget_file(path, write_output=not args.stdout,
                                                           emit_json=args.json)
        if args.stdout and (applied or stripped):
            sys.stdout.write(path.read_text(errors="replace"))
        results.append({"path": str(path), "applied": applied, "stripped": stripped,
                        "findings": [{"path": str(f.path), "line": f.line,
                                      "severity": f.severity, "rule": f.rule,
                                      "message": f.message} for f in findings]})
        for finding in findings:
            print(finding.as_line())
            if finding.severity in ("unsupported", "partial"):
                strict_hit = True
        if applied:
            slots = ", ".join(f"{attribute}->buffer({slot}) (param {param})"
                              for _, attribute, slot, param in notes)
            print(f"{path}: rewrote {applied} grid attribute(s): {slots}")

    if args.json:
        print(json.dumps(results, indent=2))
    if args.strict and strict_hit:
        sys.exit(1)


if __name__ == "__main__":
    main()
