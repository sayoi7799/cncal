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
import json
import os
import random
import sys
from collections import namedtuple

from gencommon import (
    LUNAR_PYTHON_VERSION,
    CHINESE_DAYS_VERSION,
    chinese_days_dir,
    node_query,
    require_lunar_python,
    write_sectioned_json,
)

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


@functools.lru_cache(maxsize=None)
def chinese_days_daily():
    """chinese-days 覆盖范围内每一天的类型、节日名与 isWorkday。

    类型与节日名取自包内的 dist/chinese-days.json,并与真实 API(isWorkday、getDayDetail)
    逐日交叉核对,不一致就失败。返回 (起, 止, 日期列表, 类型, 节日名, 是否工作日)。
    类型字符:W 普通工作日,E 普通周末,H 放假日,M 调休补班日。
    """
    pkg = chinese_days_dir()
    with open(os.path.join(pkg, "dist", "chinese-days.json"), encoding="utf-8") as f:
        raw = json.load(f)
    zh = lambda v: v.split(",")[1]
    hol = {k: zh(v) for k, v in raw["holidays"].items()}
    wrk = {k: zh(v) for k, v in raw["workdays"].items()}
    years = sorted({int(k[:4]) for k in list(hol) + list(wrk)})
    first, last = dt.date(years[0], 1, 1), dt.date(years[-1], 12, 31)
    days = [first + dt.timedelta(days=i) for i in range((last - first).days + 1)]
    answers = node_query(pkg, {"daily": [d.isoformat() for d in days]})["daily"]
    kinds, names, flags = {}, {}, {}
    for d, (iso, is_workday, work, _name) in zip(days, answers):
        assert iso == d.isoformat()
        if iso in wrk:
            kind, names[iso] = "M", wrk[iso]
        elif iso in hol:
            kind, names[iso] = "H", hol[iso]
        else:
            kind = "W" if d.weekday() < 5 else "E"
        expected_work = kind in ("W", "M")
        assert bool(is_workday) == expected_work and bool(work) == expected_work, (
            iso, kind, is_workday, work,
        )
        kinds[iso] = kind
        flags[iso] = 1 if expected_work else 0
    return first, last, days, kinds, names, flags


def cd_meta(extra=None):
    meta = {
        "generator": "scripts/gen_expected.py",
        "reference": "chinese-days@%s(真实 npm 包,经 Node 调用 isWorkday / getDayDetail / findWorkday / getWorkdaysInRange)"
        % CHINESE_DAYS_VERSION,
        "seed": SEED,
    }
    if extra:
        meta.update(extra)
    return meta


def gen_holiday():
    first, last, days, kinds, names, _flags = chinese_days_daily()
    years = []
    for y in range(first.year, last.year + 1):
        ds = [d.isoformat() for d in days if d.year == y]
        years.append(
            {
                "y": y,
                "k": "".join(kinds[iso] for iso in ds),
                "n": {iso: names[iso] for iso in ds if iso in names},
            }
        )
    write_sectioned_json(
        "testdata/holiday_daily.json",
        [
            ("meta", cd_meta({"kinds": "W 工作日 / E 周末 / H 放假日 / M 调休补班日"})),
            ("from", first.isoformat()),
            ("through", last.isoformat()),
            ("years", years),
        ],
    )
    print("testdata/holiday_daily.json:", len(days), "天,", len(years), "个年份")


def ref_add(flags, first, last, start, n):
    """按设计文档 §5.4.1 的定义暴力计算 add_workdays;路径越出 [first, last] 返回 None。"""
    if n == 0:
        return start
    step = 1 if n > 0 else -1
    delta = dt.timedelta(days=step)
    remaining, cur = n, start
    while remaining != 0:
        cur += delta
        if cur < first or cur > last:
            return None
        if flags[cur.isoformat()]:
            remaining -= step
    return cur


def ref_between(flags, a, b):
    """[a, b) 内的工作日个数;a > b 时取相反数。a、b 必须在覆盖范围内。"""
    if a > b:
        return -ref_between(flags, b, a)
    return sum(flags[(a + dt.timedelta(days=i)).isoformat()] for i in range((b - a).days))


def gen_workday():
    pkg = chinese_days_dir()
    first, last, days, _kinds, _names, flags = chinese_days_daily()
    rng = random.Random(SEED)
    one = dt.timedelta(days=1)

    def is_wd(d):
        return flags[d.isoformat()] == 1

    # 连续 3 天及以上的非工作日区块(春节、国庆、五一……含前后相连的周末)
    runs, i = [], 0
    while i < len(days):
        if not is_wd(days[i]):
            j = i
            while j + 1 < len(days) and not is_wd(days[j + 1]):
                j += 1
            if j - i + 1 >= 3:
                runs.append((days[i], days[j]))
            i = j + 1
        else:
            i += 1

    # ---- add_workdays 用例 ----
    starts = []
    for a, b in runs:
        for s in (a - one, b + one, a, b):
            if first <= s <= last:
                starts.append(s)
    cases = [(s, n) for s in starts for n in (-5, -1, 0, 1, 5)]
    for _ in range(800):
        cases.append((days[rng.randrange(len(days))], rng.randint(-40, 40)))
    cases += [(first, 5000), (last, -5000), (dt.date(2010, 6, 1), 1500), (dt.date(2020, 1, 1), -800)]
    # 去重(保持顺序),并只保留全程都在覆盖范围内的用例
    cases = [c for c in dict.fromkeys(cases) if ref_add(flags, first, last, c[0], c[1]) is not None]

    # 真实 chinese-days 的 findWorkday 能回答:n != 0,或 n == 0 且起算日是工作日
    api_cases = [(s, n) for (s, n) in cases if n != 0 or is_wd(s)]
    answers = node_query(pkg, {"add": [[s.isoformat(), n] for (s, n) in api_cases]})["add"]
    api = dict(zip(api_cases, answers))
    add = []
    for s, n in cases:
        want = ref_add(flags, first, last, s, n).isoformat()
        if (s, n) in api:
            assert api[(s, n)] == want, ("findWorkday 与定义不一致", s, n, api[(s, n)], want)
            src = "cd"
        else:
            src = "ref"  # n == 0 且起算日不是工作日:chinese-days 会顺延,本设计原样返回(§5.4.4)
        add.append({"from": s.isoformat(), "n": n, "to": want, "src": src})

    # ---- workdays_between 用例 ----
    pairs = []
    for a, b in runs:
        for x, y in [(a - one, b + one), (a - one, b), (a, b + one), (a, b)]:
            if first <= x <= last and first <= y <= last:
                pairs += [(x, y), (y, x)]
    for _ in range(800):
        pairs.append((days[rng.randrange(len(days))], days[rng.randrange(len(days))]))
    pairs += [(first, last), (last, first), (first, first), (last, last)]
    pairs = list(dict.fromkeys(pairs))
    # chinese-days 的 getWorkdaysInRange(起, 止) 两端都含;[a, b) 对应 (a, b 的前一天)
    forward = [(x, y) for (x, y) in pairs if x < y]
    counts = node_query(
        pkg, {"between": [[x.isoformat(), (y - one).isoformat()] for (x, y) in forward]}
    )["between"]
    api_between = dict(zip(forward, counts))
    between = []
    for x, y in pairs:
        want = ref_between(flags, x, y)
        if (x, y) in api_between:
            assert api_between[(x, y)] == want, ("getWorkdaysInRange 与定义不一致", x, y)
        between.append({"a": x.isoformat(), "b": y.isoformat(), "count": want})

    # ---- 文档里的示例(设计文档 §5.4.3) ----
    examples_add = []
    for ds, n in [
        ("2026-09-30", 1), ("2026-10-09", 1), ("2026-10-10", 1), ("2026-10-03", 0),
        ("2026-10-03", 1), ("2026-10-03", -1), ("2026-10-08", -2),
    ]:
        want = ref_add(flags, first, last, dt.date.fromisoformat(ds), n)
        assert want is not None, (ds, n)
        examples_add.append({"from": ds, "n": n, "to": want.isoformat()})
    examples_between = []
    for da, db in [("2026-09-30", "2026-10-12"), ("2026-10-12", "2026-09-30")]:
        a, b = dt.date.fromisoformat(da), dt.date.fromisoformat(db)
        examples_between.append({"a": da, "b": db, "count": ref_between(flags, a, b)})

    year_flags = []
    for y in range(first.year, last.year + 1):
        year_flags.append(
            {"y": y, "f": "".join(str(flags[d.isoformat()]) for d in days if d.year == y)}
        )

    write_sectioned_json(
        "testdata/workday_cases.json",
        [
            ("meta", cd_meta({"semantics": "docs/superpowers/specs/2026-10-01-cncal-design.md §5.4.1"})),
            ("from", first.isoformat()),
            ("through", last.isoformat()),
            ("add", add),
            ("between", between),
            ("examples_add", examples_add),
            ("examples_between", examples_between),
            ("flags", year_flags),
        ],
    )
    print(
        "testdata/workday_cases.json:", len(add), "个 add_workdays 用例(其中",
        sum(1 for a in add if a["src"] == "cd"), "个来自 chinese-days),",
        len(between), "个 workdays_between 用例,", len(runs), "个连续非工作日区块",
    )


GENERATORS = {
    "date": gen_date,
    "lunar": gen_lunar,
    "terms": gen_terms,
    "holiday": gen_holiday,
    "workday": gen_workday,
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
