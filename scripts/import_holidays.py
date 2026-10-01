#!/usr/bin/env python3
"""从 chinese-days@1.5.9 导入节假日数据,生成 data/holidays.json。

用法:
    python scripts/import_holidays.py [--data-version 2026.10.01]

只使用 chinese-days 包里随包发布的两个文件:
  - dist/chinese-days.json    按日期逐天列出放假日与补班日
  - src/holidays/generate.ts  每年一段注释,里面有国务院通知的出处链接
生成后会把区间重新展开,与来源逐日比对,并检查数据不变量,有任何不一致都会失败。

这个脚本记录的是数据的来历。以后每年的更新是直接编辑 data/holidays.json(见设计文档 §5.3.4),
不需要再运行它。
"""
import datetime as dt
import json
import os
import re
import sys

from gencommon import chinese_days_dir, write_sectioned_json

DEFAULT_DATA_VERSION = "2026.10.01"

# 对 chinese-days 给出的出处链接不满意时(例如不是一手来源),在这里按年份覆盖。
SOURCE_OVERRIDES = {
    # 陕西省人民政府网站完整转发的国务院办公厅通知(国办发明电〔2003〕53号,2003-12-18),
    # 比 chinese-days 给出的维基文库更接近一手来源。
    2004: "https://www.shaanxi.gov.cn/zfxxgk/zfgb/2004/d1q_4317/200806/t20080626_1641120.html",
    # 没有找到政府网站上的 2005 年通知。这里是法律数据库转载的全文(国办发明电〔2004〕52号,
    # 2004-12-17),比 chinese-days 给出的百度知道可靠,但仍不是一手来源。
    2005: "https://www.055110.com/law/1/27150.html",
}


def zh_name(value):
    parts = value.split(",")
    assert len(parts) == 3, value  # 「英文名,中文名,序号」
    return parts[1]


def load_days(pkg):
    with open(os.path.join(pkg, "dist", "chinese-days.json"), encoding="utf-8") as f:
        raw = json.load(f)
    holidays = {k: zh_name(v) for k, v in raw["holidays"].items()}
    workdays = {k: zh_name(v) for k, v in raw["workdays"].items()}
    return holidays, workdays


def load_sources(pkg):
    """每个年份块之前最近一段注释里的第一个链接。"""
    with open(os.path.join(pkg, "src", "holidays", "generate.ts"), encoding="utf-8") as f:
        text = f.read()
    result = {}
    for m in re.finditer(r"\.y\((\d{4})\)", text):
        year = int(m.group(1))
        head = text[max(0, m.start() - 6000) : m.start()]
        start = head.rfind("/**")
        url = re.search(r"https?://\S+", head[start:] if start >= 0 else "")
        assert url, "找不到 %d 年的出处链接" % year
        result[year] = url.group(0)
    result.update(SOURCE_OVERRIDES)
    return result


def to_ranges(holidays):
    """把逐日的放假日合并成「同名且连续」的区间。"""
    one = dt.timedelta(days=1)
    ranges = []
    for d in sorted(dt.date.fromisoformat(k) for k in holidays):
        name = holidays[d.isoformat()]
        if ranges and ranges[-1][0] == name and ranges[-1][2] + one == d:
            ranges[-1][2] = d
        else:
            ranges.append([name, d, d])
    return [
        {"name": n, "from": a.isoformat(), "to": b.isoformat()} for (n, a, b) in ranges
    ]


def expand(doc):
    hol = {}
    for r in doc["holidays"]:
        d = dt.date.fromisoformat(r["from"])
        end = dt.date.fromisoformat(r["to"])
        while d <= end:
            assert d.isoformat() not in hol, "区间重叠 " + d.isoformat()
            hol[d.isoformat()] = r["name"]
            d += dt.timedelta(days=1)
    wrk = {}
    for w in doc["workdays"]:
        assert w["date"] not in wrk, "补班日重复 " + w["date"]
        wrk[w["date"]] = w["name"]
    return hol, wrk


def build(data_version):
    pkg = chinese_days_dir()
    holidays, workdays = load_days(pkg)
    sources = load_sources(pkg)
    years = sorted(sources)
    assert years == list(range(years[0], years[-1] + 1)), "出处链接的年份不连续"
    doc = {
        "schema_version": 1,
        "data_version": data_version,
        "coverage": {"from": "%d-01-01" % years[0], "through": "%d-12-31" % years[-1]},
        "sources": [{"year": y, "url": sources[y]} for y in years],
        "holidays": to_ranges(holidays),
        "workdays": [{"name": workdays[k], "date": k} for k in sorted(workdays)],
    }
    verify(doc, holidays, workdays)
    return doc


def verify(doc, holidays, workdays):
    # 1. 区间展开后与来源逐日一致
    hol, wrk = expand(doc)
    assert hol == holidays, "放假日与来源不一致"
    assert wrk == workdays, "补班日与来源不一致"
    # 2. 数据不变量(与 holiday 包的加载校验一致)
    first = dt.date.fromisoformat(doc["coverage"]["from"])
    last = dt.date.fromisoformat(doc["coverage"]["through"])
    for k in wrk:
        d = dt.date.fromisoformat(k)
        assert d.weekday() >= 5, "补班日不是周末: " + k
        assert k not in hol, "补班日在放假区间内: " + k
        assert first <= d <= last, "补班日越出覆盖范围: " + k
    prev_to = first - dt.timedelta(days=1)
    for r in doc["holidays"]:
        a = dt.date.fromisoformat(r["from"])
        b = dt.date.fromisoformat(r["to"])
        assert prev_to < a <= b <= last, "放假区间次序或范围不对: %r" % (r,)
        assert r["name"], "名称为空"
        prev_to = b
    # 3. 覆盖范围内的每个年份都有出处
    assert {s["year"] for s in doc["sources"]} == set(range(first.year, last.year + 1))


def main(argv):
    data_version = DEFAULT_DATA_VERSION
    if "--data-version" in argv:
        data_version = argv[argv.index("--data-version") + 1]
    doc = build(data_version)
    write_sectioned_json(
        "data/holidays.json",
        [
            ("schema_version", doc["schema_version"]),
            ("data_version", doc["data_version"]),
            ("coverage", doc["coverage"]),
            ("sources", doc["sources"]),
            ("holidays", doc["holidays"]),
            ("workdays", doc["workdays"]),
        ],
    )
    names = sorted({r["name"] for r in doc["holidays"]})
    print(
        "data/holidays.json:",
        len(doc["holidays"]), "个放假区间,",
        len(doc["workdays"]), "个补班日,",
        "覆盖", doc["coverage"]["from"], "至", doc["coverage"]["through"],
    )
    print("节日名称:", "、".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
