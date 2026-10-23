#!/usr/bin/env python3
"""Render a readable Markdown summary from .xcresult bundles (stdout).

Usage: xcresult-summary.py <label>=<path.xcresult> [...]
Never raises on malformed/missing bundles; prints what it can.
"""
import json
import os
import subprocess
import sys


def xr(*args):
    cmd = ["xcrun", "xcresulttool", "get", *args, "--format", "json"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    except Exception as exc:  # noqa: BLE001
        return None, str(exc)
    if out.returncode != 0:
        return None, (out.stderr or out.stdout).strip()
    try:
        return json.loads(out.stdout), None
    except ValueError as exc:
        return None, str(exc)


def build_section(label, path):
    data, err = xr("build-results", "--path", path)
    print(f"### {label}: build results")
    if data is None:
        print(f"_Could not read build results: {err}_\n")
        return
    print(f"- status: **{data.get('status', '?')}**  errors: {data.get('errorCount', 0)}  "
          f"warnings: {data.get('warningCount', 0)}")
    errors = data.get("errors") or []
    if errors:
        print("\n**Compile / build errors**\n")
        print("```")
        for e in errors:
            print(f"{e.get('sourceURL', '')}: {e.get('message', '')}".strip())
        print("```")
    print()


def walk_failures(nodes, path, out):
    for n in nodes or []:
        name = n.get("name", "")
        kind = n.get("nodeType", "")
        here = path + [name] if kind in ("Test Suite", "Test Case", "Unit test bundle") else path
        if kind == "Test Case" and n.get("result") == "Failed":
            msgs = [c.get("name", "") for c in (n.get("children") or [])
                    if c.get("nodeType") == "Failure Message"]
            out.append(("/".join(here), msgs))
        walk_failures(n.get("children"), here, out)


def test_section(label, path):
    print(f"### {label}: test results")
    summ, err = xr("test-results", "summary", "--path", path)
    if summ is None:
        print(f"_Could not read test summary: {err}_\n")
        return
    print(f"- result: **{summ.get('result', '?')}**  total: {summ.get('totalTestCount', 0)}  "
          f"passed: {summ.get('passedTests', 0)}  failed: {summ.get('failedTests', 0)}  "
          f"skipped: {summ.get('skippedTests', 0)}  "
          f"expected failures: {summ.get('expectedFailures', 0)}")
    for f in summ.get("testFailures") or []:
        print(f"  - FAIL `{f.get('testIdentifierString') or f.get('testName', '?')}`: "
              f"{f.get('failureText', '')}")
    tests, err = xr("test-results", "tests", "--path", path)
    if tests is not None:
        failed = []
        walk_failures(tests.get("testNodes"), [], failed)
        if failed:
            print("\n**Failed tests**\n")
            for name, msgs in failed:
                print(f"- `{name}`")
                for m in msgs:
                    print(f"    - {m}")
    print()


def main():
    print("## iOS xcresult summary\n")
    for arg in sys.argv[1:]:
        label, _, path = arg.partition("=")
        if not path:
            continue
        if not os.path.isdir(path):
            print(f"### {label}\n_No result bundle at `{path}` "
                  f"(step did not run or crashed early)._\n")
            continue
        build_section(label, path)
        if label != "build":
            test_section(label, path)


if __name__ == "__main__":
    main()
