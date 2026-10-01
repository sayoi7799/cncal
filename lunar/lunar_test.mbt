///|
fn[T : Show] expect_invalid(
  f : () -> T raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.InvalidDate(_) => ()
    e => fail("\{what}: 期望 InvalidDate,实际 \{e}")
  } noraise {
    v => fail("\{what}: 期望 InvalidDate,实际得到 \{v}")
  }
}

///|
fn[T : Show] expect_out_of_range(
  f : () -> T raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.OutOfRange(_) => ()
    e => fail("\{what}: 期望 OutOfRange,实际 \{e}")
  } noraise {
    v => fail("\{what}: 期望 OutOfRange,实际得到 \{v}")
  }
}

///|
/// 一条预期记录:公历日期 ↔ 农历日期必须双向一致。
fn check_conversion(rec : Json) -> Unit raise {
  let s = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "s")))
  let y = @jsonx.as_int(@jsonx.field(rec, "y"))
  let m = @jsonx.as_int(@jsonx.field(rec, "m"))
  let leap = @jsonx.as_int(@jsonx.field(rec, "leap")) == 1
  let d = @jsonx.as_int(@jsonx.field(rec, "d"))
  let tag = @jsonx.as_string(@jsonx.field(rec, "t"))
  let expected = @lunar.LunarDate::new(y, m, leap, d)
  assert_eq(
    @lunar.solar_to_lunar(s),
    expected,
    msg="公历→农历 \{s} (\{tag})",
  )
  assert_eq(
    @lunar.lunar_to_solar(expected),
    s,
    msg="农历→公历 \{expected} (\{tag})",
  )
}

///|
test "1000 个随机日期的公历与农历互转和 lunar-python 一致" {
  let root = @jsonx.parse(lunar_samples_json)
  let samples = @jsonx.as_array(@jsonx.field(root, "samples"))
  assert_eq(samples.length(), 1000)
  for rec in samples {
    check_conversion(rec)
  }
}

///|
test "边界集合:闰月首尾、除夕、正月初一、元旦、节气落在农历月初月末" {
  let root = @jsonx.parse(lunar_samples_json)
  let edges = @jsonx.as_array(@jsonx.field(root, "edges"))
  let counts : Map[String, Int] = Map([])
  for rec in edges {
    check_conversion(rec)
    let tag = @jsonx.as_string(@jsonx.field(rec, "t"))
    counts[tag] = counts.get(tag).unwrap_or(0) + 1
  }
  // 每一类边界都确实出现过,防止生成器悄悄漏掉某一类
  for
    tag in [
      "range_first", "range_last", "new_year", "new_year_eve", "leap_first", "leap_last",
      "solar_jan1", "term_edge",
    ] {
    assert_true(
      counts.get(tag).unwrap_or(0) > 0,
      msg="缺少边界类别 \{tag}",
    )
  }
  // 201 个农历年各有一个正月初一与一个除夕
  assert_eq(counts.get("new_year"), Some(201))
  assert_eq(counts.get("new_year_eve"), Some(201))
  assert_eq(counts.get("leap_first"), counts.get("leap_last"))
}

///|
test "每个农历月的初一与月长和 lunar-python 一致(覆盖整个农历域)" {
  let root = @jsonx.parse(lunar_month_starts_json)
  let years = @jsonx.as_array(@jsonx.field(root, "years"))
  assert_eq(years.length(), 201)
  for rec in years {
    let y = @jsonx.as_int(@jsonx.field(rec, "y"))
    let months = @jsonx.as_array(@jsonx.field(rec, "months"))
    let mut leap_in_data = 0
    for item in months {
      let parts = @jsonx.as_array(item)
      let m = @jsonx.as_int(parts[0])
      let leap = @jsonx.as_int(parts[1]) == 1
      let start = @date.Date::from_iso(@jsonx.as_string(parts[2]))
      let days = @jsonx.as_int(parts[3])
      if leap {
        leap_in_data = m
      }
      let first_day = @lunar.LunarDate::new(y, m, leap, 1)
      assert_eq(
        @lunar.lunar_to_solar(first_day),
        start,
        msg="初一 \{first_day}",
      )
      assert_eq(@lunar.month_days(y, m, leap), days, msg="月长 \{first_day}")
    }
    assert_eq(@lunar.leap_month(y), leap_in_data, msg="闰月 \{y}")
    assert_eq(months.length(), if leap_in_data == 0 { 12 } else { 13 })
  }
}

///|
test "农历域内逐日往返恒等且逐日连续(约 73000 天)" {
  let first = @date.Date::new(1900, 1, 31)
  let last = @date.Date::new(2101, 1, 28)
  let total = first.days_between(last)
  let mut prev : @lunar.LunarDate? = None
  for i in 0..<=total {
    let d = first.add_days(i)
    let l = @lunar.solar_to_lunar(d)
    assert_eq(@lunar.lunar_to_solar(l), d, msg="往返 \{d}")
    match prev {
      Some(p) =>
        if l.year == p.year && l.month == p.month && l.is_leap == p.is_leap {
          assert_eq(
            l.day,
            p.day + 1,
            msg="同月内日期应逐日加一: \{d}",
          )
        } else {
          assert_eq(l.day, 1, msg="换月应从初一开始: \{d}")
          assert_eq(
            p.day,
            @lunar.month_days(p.year, p.month, p.is_leap),
            msg="换月前一天应是月末: \{d}",
          )
        }
      None => ()
    }
    prev = Some(l)
  }
}

///|
test "农历域边界:域外的日期报 OutOfRange" {
  // 域内首尾(1900-01-31 与 2101-01-28)的预期值来自生成的 range_first / range_last 用例
  expect_out_of_range(
    () => @lunar.solar_to_lunar(@date.Date::new(1900, 1, 30)),
    "1900-01-30",
  )
  expect_out_of_range(
    () => @lunar.solar_to_lunar(@date.Date::new(2101, 1, 29)),
    "2101-01-29",
  )
  expect_out_of_range(
    () => @lunar.solar_to_lunar(@date.Date::new(1899, 12, 31)),
    "1899-12-31",
  )
  expect_out_of_range(
    () => @lunar.solar_to_lunar(@date.Date::new(1, 1, 1)),
    "0001-01-01",
  )
  expect_out_of_range(
    () => @lunar.solar_to_lunar(@date.Date::new(9999, 12, 31)),
    "9999-12-31",
  )
}

///|
test "审查重点:闰月标记、月份、日期、年份的误用一律报错" {
  let root = @jsonx.parse(lunar_month_starts_json)
  for rec in @jsonx.as_array(@jsonx.field(root, "years")) {
    let y = @jsonx.as_int(@jsonx.field(rec, "y"))
    let leap_months : Array[Int] = []
    for item in @jsonx.as_array(@jsonx.field(rec, "months")) {
      let parts = @jsonx.as_array(item)
      let m = @jsonx.as_int(parts[0])
      let leap = @jsonx.as_int(parts[1]) == 1
      let days = @jsonx.as_int(parts[3])
      if leap {
        leap_months.push(m)
      }
      // 月内最后一天合法;再往后一天、第 0 天、负数天都不合法
      assert_eq(@lunar.LunarDate::new(y, m, leap, days).day, days)
      expect_invalid(
        () => @lunar.LunarDate::new(y, m, leap, days + 1),
        "\{y}-\{m} 第 \{days + 1} 天",
      )
      expect_invalid(
        () => @lunar.LunarDate::new(y, m, leap, 0),
        "\{y}-\{m} 第 0 天",
      )
      expect_invalid(
        () => @lunar.LunarDate::new(y, m, leap, -1),
        "\{y}-\{m} 第 -1 天",
      )
    }
    // 没有闰月的月份,加上闰标记必须报错,不能换算成别的合法日期
    for m in 1..<=12 {
      if not(leap_months.contains(m)) {
        expect_invalid(
          () => @lunar.LunarDate::new(y, m, true, 1),
          "\{y} 年没有闰 \{m} 月",
        )
      }
    }
    expect_invalid(
      () => @lunar.LunarDate::new(y, 0, false, 1),
      "\{y} 年 0 月",
    )
    expect_invalid(
      () => @lunar.LunarDate::new(y, 13, false, 1),
      "\{y} 年 13 月",
    )
    expect_invalid(
      () => @lunar.LunarDate::new(y, -1, false, 1),
      "\{y} 年 -1 月",
    )
  }
  // 年份越界
  for y in [1899, 2101, 0, -1, 2147483647, -2147483648] {
    expect_out_of_range(
      () => @lunar.LunarDate::new(y, 1, false, 1),
      "LunarDate::new 年份 \{y}",
    )
    expect_out_of_range(() => @lunar.leap_month(y), "leap_month 年份 \{y}")
    expect_out_of_range(
      () => @lunar.month_days(y, 1, false),
      "month_days 年份 \{y}",
    )
  }
}
