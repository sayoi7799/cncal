#!/usr/bin/env python3
"""依次运行 moon check,以及 js、wasm-gc、native 三个后端的 moon test,并汇总结果。

用法: python scripts/run_all_backends.py
全部通过则退出码为 0,否则为 1。
"""
import re
import shutil
import subprocess
import sys
import time

TARGETS = ["js", "wasm-gc", "native"]


def run(moon, args):
    start = time.time()
    p = subprocess.run(
        [moon] + args, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    return p.returncode, p.stdout + p.stderr, time.time() - start


def main():
    moon = shutil.which("moon")
    if not moon:
        sys.exit("找不到 moon 命令,请先安装 MoonBit 工具链")
    code, out, secs = run(moon, ["check"])
    ok = code == 0
    print("%-10s %s (%.1f 秒)" % ("moon check", "通过" if ok else "失败", secs))
    if not ok:
        print(out[-3000:])
    for target in TARGETS:
        code, out, secs = run(moon, ["test", "--target", target])
        totals = re.findall(r"Total tests: (\d+), passed: (\d+), failed: (\d+)", out)
        passed = code == 0 and bool(totals) and totals[-1][2] == "0"
        ok = ok and passed
        summary = "%s/%s 通过" % (totals[-1][1], totals[-1][0]) if totals else "没有找到测试汇总"
        print("%-10s %s (%.1f 秒) %s" % (target, "通过" if passed else "失败", secs, summary))
        if not passed:
            print(out[-3000:])
    print("全部通过" if ok else "存在失败")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
