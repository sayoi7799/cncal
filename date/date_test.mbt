///|
fn expect_invalid(
  f : () -> @date.Date raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.InvalidDate(_) => ()
    e => fail("\{what}: 期望 InvalidDate,实际 \{e}")
  } noraise {
    d => fail("\{what}: 期望 InvalidDate,实际得到 \{d}")
  }
}

///|
fn expect_out_of_range(
  f : () -> @date.Date raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.OutOfRange(_) => ()
    e => fail("\{what}: 期望 OutOfRange,实际 \{e}")
  } noraise {
    d => fail("\{what}: 期望 OutOfRange,实际得到 \{d}")
  }
}

///|
test "合法日期:天数、星期、字符串与 Python datetime 一致" {
  let root = @jsonx.parse(date_cases_json)
  let valid = @jsonx.as_array(@jsonx.field(root, "valid"))
  assert_true(valid.length() >= 1000)
  for rec in valid {
    let y = @jsonx.as_int(@jsonx.field(rec, "y"))
    let m = @jsonx.as_int(@jsonx.field(rec, "m"))
    let d = @jsonx.as_int(@jsonx.field(rec, "d"))
    let days = @jsonx.as_int(@jsonx.field(rec, "days"))
    let wd = @jsonx.as_int(@jsonx.field(rec, "wd"))
    let iso = @jsonx.as_string(@jsonx.field(rec, "iso"))
    let date = @date.Date::new(y, m, d)
    assert_eq(date.to_days(), days, msg="to_days \{iso}")
    assert_eq(date.weekday().iso_number(), wd, msg="weekday \{iso}")
    assert_eq("\{date}", iso)
    assert_eq(@date.Date::from_days(days), date, msg="from_days \{iso}")
    assert_eq(@date.Date::from_iso(iso), date, msg="from_iso \{iso}")
  }
}

///|
test "add_days 与 Python date 运算一致,越界报 OutOfRange" {
  let root = @jsonx.parse(date_cases_json)
  let adds = @jsonx.as_array(@jsonx.field(root, "add"))
  assert_true(adds.length() >= 1000)
  let mut out_of_range = 0
  for rec in adds {
    let from = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "from")))
    let n = @jsonx.as_int(@jsonx.field(rec, "n"))
    let to = @jsonx.field(rec, "to")
    if @jsonx.is_null(to) {
      out_of_range += 1
      expect_out_of_range(() => from.add_days(n), "\{from} + \{n}")
    } else {
      let expected = @date.Date::from_iso(@jsonx.as_string(to))
      assert_eq(from.add_days(n), expected, msg="\{from} + \{n}")
      assert_eq(
        from.days_between(expected),
        n,
        msg="days_between \{from} \{expected}",
      )
    }
  }
  // 数据里确实包含越界的用例,防止生成器悄悄漏掉这一类
  assert_true(out_of_range > 0)
}

///|
test "非法日期报 InvalidDate" {
  let root = @jsonx.parse(date_cases_json)
  let invalid = @jsonx.as_array(@jsonx.field(root, "invalid"))
  assert_true(invalid.length() > 0)
  for rec in invalid {
    let parts = @jsonx.as_array(rec)
    let y = @jsonx.as_int(parts[0])
    let m = @jsonx.as_int(parts[1])
    let d = @jsonx.as_int(parts[2])
    expect_invalid(() => @date.Date::new(y, m, d), "\{y}-\{m}-\{d}")
  }
}

///|
test "闰年判断与 Python calendar 一致" {
  let root = @jsonx.parse(date_cases_json)
  for rec in @jsonx.as_array(@jsonx.field(root, "leap")) {
    let parts = @jsonx.as_array(rec)
    let y = @jsonx.as_int(parts[0])
    assert_eq(
      @date.is_leap_year(y),
      @jsonx.as_bool(parts[1]),
      msg="闰年 \{y}",
    )
  }
}

///|
test "审查重点:畸形日期字符串一律报 InvalidDate" {
  let bad = [
    "", "2026", "2026-1-1", "2026/10/01", " 2026-10-01", "2026-10-01 ", "2026-10-01T00:00",
    "２０２６-10-01", "2026-10-0a", "2026-13-01", "2026-02-30", "abcd-ef-gh",
    "0000-01-01", "10000-01-01", "2026-10--1", "+026-10-01", "2026-１0-01",
  ]
  for s in bad {
    expect_invalid(() => @date.Date::from_iso(s), "from_iso(\"\{s}\")")
  }
  // 严格格式的合法字符串仍然可以解析
  assert_eq("\{@date.Date::from_iso("2026-10-01")}", "2026-10-01")
}

///|
test "审查重点:极端整数不会回绕成合法日期" {
  let max_n = 2147483647
  let min_n = -2147483648
  let mid = @date.Date::new(2026, 1, 1)
  expect_out_of_range(() => mid.add_days(max_n), "2026-01-01 + Int 最大值")
  expect_out_of_range(() => mid.add_days(min_n), "2026-01-01 + Int 最小值")
  let last = @date.Date::new(9999, 12, 31)
  let first = @date.Date::new(1, 1, 1)
  expect_out_of_range(() => last.add_days(max_n), "9999-12-31 + Int 最大值")
  expect_out_of_range(() => first.add_days(min_n), "0001-01-01 + Int 最小值")
  expect_out_of_range(() => last.add_days(1), "9999-12-31 + 1")
  expect_out_of_range(() => first.add_days(-1), "0001-01-01 - 1")
  expect_out_of_range(
    () => @date.Date::from_days(max_n),
    "from_days(Int 最大值)",
  )
  expect_out_of_range(
    () => @date.Date::from_days(min_n),
    "from_days(Int 最小值)",
  )
  // 边界本身是合法的
  assert_eq("\{last.add_days(0)}", "9999-12-31")
  assert_eq("\{first.add_days(0)}", "0001-01-01")
}
