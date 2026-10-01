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
import random
import sys

from gencommon import write_sectioned_json

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


GENERATORS = {
    "date": gen_date,
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
