#!/usr/bin/env python3
"""生成测试预期值 testdata/*.json。预期值全部来自独立的参考实现,不手写:

    date     Python 标准库 datetime
    lunar    lunar-python 的逐日接口
    terms    lunar-python 的逐日接口
    holiday  真实的 chinese-days npm 包(经 Node 调用)
    workday  chinese-days 的 findWorkday / getWorkdaysInRange,加 Python 暴力参考实现

用法:
    python scripts/gen_expected.py date
    python scripts/gen_expected.py all

运行 Python 时请设置 PYTHONUTF8=1。输出不含时间戳,重复运行结果逐字节相同。
"""
import calendar
import datetime as dt
import functools
import random
import sys
from collections import namedtuple

from gencommon import LUNAR_PYTHON_VERSION, require_lunar_python, write_sectioned_json

SEED = 20261001
EPOCH = dt.date(1970, 1, 1).toordinal()
MAX_ORDINAL = dt.date.max.toordinal()


def day_number(d):
    return d.toordinal() - EPOCH


def gen_date():
    rng = random.Random(SEED)
    anchors = [
        dt.date(*t)
        for t in [
            (1, 1, 1), (1, 1, 2), (1, 12, 31), (4, 2, 29), (100, 2, 28), (100, 3, 1),
            (400, 2, 29), (1600, 2, 29), (1700, 2, 28), (1700, 3, 1), (1800, 12, 31),
            (1899, 12, 31), (1900, 1, 1), (1900, 2, 28), (1900, 3, 1), (1969, 12, 31),
            (1970, 1, 1), (2000, 2, 29), (2000, 3, 1), (2024, 2, 29), (2026, 10, 1),
            (2100, 2, 28), (2100, 3, 1), (9999, 1, 1), (9999, 12, 31),
        ]
    ]
    randoms = [dt.date.fromordinal(rng.randint(1, MAX_ORDINAL)) for _ in range(1800)]
    pool = anchors + randoms

    valid = [
        {
            "y": d.year, "m": d.month, "d": d.day,
            "days": day_number(d), "wd": d.isoweekday(), "iso": d.isoformat(),
        }
        for d in pool
    ]

    def add_record(d, n):
        try:
            to = dt.date.fromordinal(d.toordinal() + n).isoformat()
        except (ValueError, OverflowError):
            to = None
        return {"from": d.isoformat(), "n": n, "to": to}

    add = []
    # 边界:恰好在 0001-01-01 与 9999-12-31 上下
    for d, n in [
        (dt.date.max, 1), (dt.date.max, 0), (dt.date.max, -1),
        (dt.date.min, -1), (dt.date.min, 0), (dt.date.min, 1),
        (dt.date(1970, 1, 1), -719162), (dt.date(1970, 1, 1), -719163),
        (dt.date(1970, 1, 1), 2932896), (dt.date(1970, 1, 1), 2932897),
    ]:
        add.append(add_record(d, n))
    for _ in range(2000):
        d = pool[rng.randrange(len(pool))]
        n = rng.randint(-400, 400) if rng.random() < 0.5 else rng.randint(-3_700_000, 3_700_000)
        add.append(add_record(d, n))

    invalid = [
        [2023, 2, 29], [1900, 2, 29], [2100, 2, 29], [2023, 4, 31], [2023, 6, 31],
        [2023, 9, 31], [2023, 11, 31], [2023, 1, 32], [2023, 0, 1], [2023, 13, 1],
        [2023, 1, 0], [2023, 1, -1], [0, 1, 1], [-1, 1, 1], [10000, 1, 1], [2023, -5, 10],
    ]
    for y, m, d in invalid:
        try:
            dt.date(y, m, d)
        except (ValueError, OverflowError):
            continue
        raise SystemExit("%s 其实是合法日期,不能放进 invalid 列表" % ((y, m, d),))

    leap = [
        [y, calendar.isleap(y)]
        for y in (1, 4, 100, 400, 1600, 1700, 1800, 1900, 2000, 2023, 2024, 2100, 2400, 9999)
    ]

    meta = {
        "generator": "scripts/gen_expected.py date",
        "reference": "Python 标准库 datetime / calendar",
        "seed": SEED,
        "epoch": "1970-01-01",
        "days_formula": "date.toordinal() - 719163",
    }
    write_sectioned_json(
        "testdata/date_cases.json",
        [("meta", meta), ("valid", valid), ("add", add), ("invalid", invalid), ("leap", leap)],
    )
    print(
        "testdata/date_cases.json:", len(valid), "个合法日期,", len(add), "个加减天数,",
        len(invalid), "个非法日期",
    )


FIRST_YEAR, LAST_YEAR = 1900, 2100
DOMAIN_FIRST = dt.date(1900, 1, 31)  # 农历 1900 年正月初一
DOMAIN_LAST = dt.date(2101, 1, 28)  # 农历 2100 年最后一天

Row = namedtuple("Row", "date ly lm leap ld jq")


@functools.lru_cache(maxsize=None)
def scan():
    """逐日扫描 1900-01-01 ~ 2101-01-28,记录 lunar-python 给出的农历日期与节气(约一分钟)。"""
    from lunar_python import Solar

    require_lunar_python()
    rows = []
    d = dt.date(1900, 1, 1)
    while d <= DOMAIN_LAST:
        lunar = Solar.fromYmd(d.year, d.month, d.day).getLunar()
        m = lunar.getMonth()
        rows.append(Row(d, lunar.getYear(), abs(m), m < 0, lunar.getDay(), lunar.getJieQi()))
        d += dt.timedelta(days=1)
    # 自检:农历日期逐日连续(同月内日加一,换月从初一开始)
    for prev, cur in zip(rows, rows[1:]):
        same_month = (cur.ly, cur.lm, cur.leap) == (prev.ly, prev.lm, prev.leap)
        assert (same_month and cur.ld == prev.ld + 1) or (not same_month and cur.ld == 1), (prev, cur)
    return rows


def lunar_meta(extra=None):
    meta = {
        "generator": "scripts/gen_expected.py",
        "reference": "lunar_python==%s 的逐日接口(Solar.getLunar / Lunar.getSolar / Lunar.getJieQi)"
        % LUNAR_PYTHON_VERSION,
        "seed": SEED,
        "domain": [DOMAIN_FIRST.isoformat(), DOMAIN_LAST.isoformat()],
    }
    if extra:
        meta.update(extra)
    return meta


def lunar_record(row, tag, **extra):
    rec = {
        "s": row.date.isoformat(),
        "y": row.ly,
        "m": row.lm,
        "leap": 1 if row.leap else 0,
        "d": row.ld,
        "t": tag,
    }
    rec.update(extra)
    return rec


def gen_lunar():
    """农历转换的随机样本与边界集合 + 每个农历月的初一与月长。"""
    from lunar_python import Lunar

    rows = scan()
    dom = [r for r in rows if r.date >= DOMAIN_FIRST]
    rng = random.Random(SEED)

    def reverse_ok(r):
        # 反方向再问一次 lunar-python:农历 → 公历必须回到同一天
        s = Lunar.fromYmd(r.ly, -r.lm if r.leap else r.lm, r.ld).getSolar()
        assert (s.getYear(), s.getMonth(), s.getDay()) == (r.date.year, r.date.month, r.date.day), r

    samples = []
    for i in sorted(rng.sample(range(len(dom)), 1000)):
        reverse_ok(dom[i])
        samples.append(lunar_record(dom[i], "sample"))

    edges = []

    def edge(row, tag, **extra):
        reverse_ok(row)
        edges.append(lunar_record(row, tag, **extra))

    edge(dom[0], "range_first")
    edge(dom[-1], "range_last")
    by_year = {}
    for r in dom:
        by_year.setdefault(r.ly, []).append(r)
    for y in sorted(by_year):
        edge(by_year[y][0], "new_year")
        edge(by_year[y][-1], "new_year_eve")
    leap_groups = {}
    for r in dom:
        if r.leap:
            leap_groups.setdefault((r.ly, r.lm), []).append(r)
    for key in sorted(leap_groups):
        edge(leap_groups[key][0], "leap_first")
        edge(leap_groups[key][-1], "leap_last")
    for r in dom:
        if r.date.month == 1 and r.date.day == 1 and r.date > DOMAIN_FIRST:
            edge(r, "solar_jan1")
    for i, r in enumerate(dom):
        if r.jq and r.date.year <= LAST_YEAR:
            is_month_end = i + 1 < len(dom) and dom[i + 1].ld == 1
            if r.ld == 1 or is_month_end:
                edge(r, "term_edge", jq=r.jq)

    counts = {}
    for e in edges:
        counts[e["t"]] = counts.get(e["t"], 0) + 1
    write_sectioned_json(
        "testdata/lunar_samples.json",
        [("meta", lunar_meta({"edge_counts": counts})), ("samples", samples), ("edges", edges)],
    )
    print("testdata/lunar_samples.json:", len(samples), "个随机样本,", len(edges), "个边界用例", counts)

    # 每个农历月的初一与月长
    months_by_year = {}
    cur = None
    for r in dom:
        key = (r.ly, r.lm, r.leap)
        if cur is None or cur[0] != key:
            cur = [key, r.date, 0]
            months_by_year.setdefault(r.ly, []).append(cur)
        cur[2] += 1
    lines = []
    for y in sorted(months_by_year):
        months = [
            [k[1], 1 if k[2] else 0, start.isoformat(), n] for (k, start, n) in months_by_year[y]
        ]
        assert all(m[3] in (29, 30) for m in months), y
        lines.append({"y": y, "months": months})
    assert len(lines) == LAST_YEAR - FIRST_YEAR + 1
    write_sectioned_json(
        "testdata/lunar_month_starts.json",
        [("meta", lunar_meta()), ("years", lines)],
    )
    print("testdata/lunar_month_starts.json:", len(lines), "个农历年")


def gen_terms():
    """1900–2100 年每年 24 个节气的(公历月, 日)。"""
    rows = scan()
    per_year = {}
    for r in rows:
        if r.jq and r.date.year <= LAST_YEAR:
            per_year.setdefault(r.date.year, []).append((r.jq, r.date.month, r.date.day))
    names = [n for (n, _, _) in per_year[2024]]
    assert len(names) == 24, names
    lines = []
    for y in range(FIRST_YEAR, LAST_YEAR + 1):
        v = per_year[y]
        assert len(v) == 24 and [n for (n, _, _) in v] == names, y
        assert all(m == k // 2 + 1 for k, (_, m, _) in enumerate(v)), y
        lines.append({"y": y, "t": [[m, d] for (_, m, d) in v]})
    write_sectioned_json(
        "testdata/solar_terms.json",
        [("meta", lunar_meta({"names": names})), ("years", lines)],
    )
    print("testdata/solar_terms.json:", len(lines), "年 × 24 个节气")


GENERATORS = {
    "date": gen_date,
    "lunar": gen_lunar,
    "terms": gen_terms,
}


def main(argv):
    names = argv or ["all"]
    if "all" in names:
        names = list(GENERATORS)
    for name in names:
        if name not in GENERATORS:
            sys.exit("未知的数据集 %r,可选:%s" % (name, ", ".join(GENERATORS)))
        GENERATORS[name]()


if __name__ == "__main__":
    main(sys.argv[1:])
