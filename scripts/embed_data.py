#!/usr/bin/env python3
"""用 `moon tool embed` 把 JSON 嵌入成 MoonBit 字符串常量。

用法:
    python scripts/embed_data.py          重新生成全部嵌入文件
    python scripts/embed_data.py --check  只检查已提交的嵌入文件是否过期(过期则退出码为 1)
"""
import os
import shutil
import subprocess
import sys

from gencommon import ROOT

# (输入 JSON, 输出 .mbt, 常量名)。新增数据集时在这里追加。
EMBEDS = [
    ("testdata/date_cases.json", "date/date_cases_test.mbt", "date_cases_json"),
    ("testdata/lunar_samples.json", "lunar/lunar_samples_test.mbt", "lunar_samples_json"),
    ("testdata/lunar_month_starts.json", "lunar/lunar_month_starts_test.mbt", "lunar_month_starts_json"),
    ("testdata/solar_terms.json", "lunar/solar_terms_test.mbt", "solar_terms_json"),
    ("data/holidays.json", "holiday/data_gen.mbt", "holidays_json"),
    ("testdata/holiday_daily.json", "holiday/holiday_daily_test.mbt", "holiday_daily_json"),
    ("testdata/workday_cases.json", "workday/workday_cases_test.mbt", "workday_cases_json"),
]


def embed_to(src, dst, name):
    moon = shutil.which("moon")
    if not moon:
        sys.exit("找不到 moon 命令,请先安装 MoonBit 工具链")
    os.makedirs(os.path.dirname(os.path.join(ROOT, dst)), exist_ok=True)
    subprocess.run(
        [moon, "tool", "embed", "--text", "-i", src, "-o", dst, "--name", name],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )


def read_bytes(rel_path):
    path = os.path.join(ROOT, rel_path)
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return f.read()


def main(argv):
    check = "--check" in argv
    stale = []
    for src, dst, name in EMBEDS:
        if check:
            tmp = os.path.join("_build", "embed_check", dst.replace("/", "__"))
            embed_to(src, tmp, name)
            if read_bytes(tmp) != read_bytes(dst):
                stale.append(dst)
        else:
            embed_to(src, dst, name)
            print("已生成", dst)
    if check:
        if stale:
            print("以下嵌入文件已过期,请运行 python scripts/embed_data.py:")
            for dst in stale:
                print("  ", dst)
            return 1
        print("嵌入文件全部是最新的")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
