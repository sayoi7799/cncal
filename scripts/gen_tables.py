#!/usr/bin/env python3
"""从 lunar-python 生成 lunar/tables_gen.mbt(农历年表与节气表)。

用法:
    python scripts/gen_tables.py           重新生成
    python scripts/gen_tables.py --check   只检查已提交的文件是否与重新生成的结果一致

表是用 lunar-python 的 LunarYear 接口生成的;测试预期值(gen_expected.py)用的是它的逐日接口。
注意:这两个入口共用同一套天文计算,所以它们一致只能说明接口用对了,
不能证明 lunar-python 自身正确(见设计文档 §7.1)。
"""
import datetime as dt
import sys

from gencommon import read_text, require_lunar_python, write_text

FIRST_YEAR, LAST_YEAR = 1900, 2100
OUT = "lunar/tables_gen.mbt"


def lunar_info(year):
    from lunar_python import LunarYear, Solar

    ly = LunarYear.fromYear(year)
    leap = ly.getLeapMonth()
    months = [m for m in ly.getMonths() if m.getYear() == year]
    assert len(months) == (13 if leap else 12), (year, len(months), leap)
    # 月份顺序:1..leap,闰 leap(负数),leap+1..12
    expected_order = []
    for month in range(1, 13):
        expected_order.append(month)
        if month == leap:
            expected_order.append(-leap)
    assert [m.getMonth() for m in months] == expected_order, (year, "月份顺序")
    bits = 0
    for slot, m in enumerate(months):
        days = m.getDayCount()
        assert days in (29, 30), (year, slot, days)
        if days == 30:
            bits |= 1 << slot
    new_year = Solar.fromJulianDay(months[0].getFirstJulianDay())
    assert new_year.getYear() == year, (year, new_year.toYmd())
    offset = (
        dt.date(new_year.getYear(), new_year.getMonth(), new_year.getDay())
        - dt.date(year, 1, 21)
    ).days
    assert 0 <= offset < 32, (year, offset)
    return leap | (bits << 4) | (offset << 17)


def solar_term_days(year):
    from lunar_python import LunarYear, Solar

    # 下标 2..25 依次是:小寒、大寒、…、大雪、当年的冬至
    jds = LunarYear.fromYear(year).getJieQiJulianDays()[2:26]
    assert len(jds) == 24, year
    days = []
    for k, jd in enumerate(jds):
        s = Solar.fromJulianDay(jd)
        assert s.getYear() == year and s.getMonth() == k // 2 + 1, (year, k, s.toYmd())
        assert 3 <= s.getDay() <= 24, (year, k, s.getDay())
        days.append(s.getDay())
    return days


def render(version):
    years = range(FIRST_YEAR, LAST_YEAR + 1)
    infos = [lunar_info(y) for y in years]
    terms = [solar_term_days(y) for y in years]
    lines = [
        "// 由 scripts/gen_tables.py 生成,请勿手工修改(DO NOT EDIT)。",
        "// 数据来源:lunar_python==%s(MIT 许可,版权 6tail),范围 %d–%d 年。"
        % (version, FIRST_YEAR, LAST_YEAR),
        "",
        "///|",
        "/// 农历年表,下标为「年份 - 1900」,共 201 项。每项的位域:",
        "///   bit 0–3    闰月月份(0 表示无闰月)",
        "///   bit 4–16   13 个月槽位,按月份出现的顺序(闰月紧跟同数字的正常月);"
        "为 1 表示该月 30 天,为 0 表示 29 天",
        "///   bit 17–21  正月初一相对当年 1 月 21 日的偏移天数",
        "let lunar_info : FixedArray[Int] = [",
    ]
    lines += ["  %d," % v for v in infos]
    lines += [
        "]",
        "",
        "///|",
        "/// 二十四节气表,下标为「(年份 - 1900) * 24 + k」,k = 0 为小寒,k = 23 为冬至;值是几号。",
        "/// 第 k 个节气所在的公历月固定为 k / 2 + 1。",
        "let solar_term_days : FixedArray[Int] = [",
    ]
    for year_days in terms:
        lines.append("  " + ", ".join(str(v) for v in year_days) + ",")
    lines.append("]")
    return "\n".join(lines) + "\n"


def main(argv):
    version = require_lunar_python()
    text = render(version)
    if "--check" in argv:
        if read_text(OUT) != text:
            print(OUT, "已过期,请运行 python scripts/gen_tables.py")
            return 1
        print(OUT, "是最新的")
        return 0
    write_text(OUT, text)
    print("已生成", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
