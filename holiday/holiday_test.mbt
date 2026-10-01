///|
fn expect_not_covered(
  f : () -> Unit raise @date.CalendarError,
  d : @date.Date,
  info : @holiday.DataInfo,
) -> Unit raise {
  try f() catch {
    @date.DataNotCovered(requested, from, through) => {
      assert_eq(requested, d)
      assert_eq(from, info.from)
      assert_eq(through, info.through)
    }
    e => fail("\{d}: 期望 DataNotCovered,实际 \{e}")
  } noraise {
    _ => fail("\{d}: 期望 DataNotCovered,但没有出错")
  }
}

///|
test "覆盖范围内每一天的类型与节日名和 chinese-days 一致" {
  let root = @jsonx.parse(holiday_daily_json)
  let expected_from = @date.Date::from_iso(
    @jsonx.as_string(@jsonx.field(root, "from")),
  )
  let expected_through = @date.Date::from_iso(
    @jsonx.as_string(@jsonx.field(root, "through")),
  )
  let info = @holiday.data_info()
  // 本项目的覆盖范围不能小于 chinese-days 的
  assert_true(info.from <= expected_from, msg="覆盖起点 \{info.from}")
  assert_true(
    info.through >= expected_through,
    msg="覆盖终点 \{info.through}",
  )
  let mut checked = 0
  let mut makeup_saturdays = 0
  let mut makeup_sundays = 0
  for rec in @jsonx.as_array(@jsonx.field(root, "years")) {
    let year = @jsonx.as_int(@jsonx.field(rec, "y"))
    let kinds = @jsonx.as_string(@jsonx.field(rec, "k"))
    let names = @jsonx.as_object(@jsonx.field(rec, "n"))
    let mut d = @date.Date::new(year, 1, 1)
    for i in 0..<kinds.length() {
      let key = "\{d}"
      let kind = @holiday.day_kind(d)
      if kinds[i] == 'M' {
        // 调休补班日只会出现在周六或周日
        match d.weekday() {
          @date.Saturday => makeup_saturdays += 1
          @date.Sunday => makeup_sundays += 1
          _ => fail("补班日不是周末: \{key}")
        }
      }
      let name = match names.get(key) {
        Some(j) => @jsonx.as_string(j)
        None => ""
      }
      let c = kinds[i]
      match c {
        'W' => assert_eq(kind, @holiday.Workday, msg=key)
        'E' => assert_eq(kind, @holiday.Weekend, msg=key)
        'H' => assert_eq(kind, @holiday.Holiday(name), msg=key)
        'M' => assert_eq(kind, @holiday.MakeupWorkday(name), msg=key)
        _ => fail("未知的类型字符 \{c}")
      }
      assert_eq(@holiday.is_holiday(d), c == 'H', msg="is_holiday \{key}")
      assert_eq(
        @holiday.is_makeup_workday(d),
        c == 'M',
        msg="is_makeup_workday \{key}",
      )
      assert_eq(
        @holiday.holiday_name(d),
        if name == "" {
          None
        } else {
          Some(name)
        },
        msg="holiday_name \{key}",
      )
      checked += 1
      d = d.add_days(1)
    }
    assert_eq(d, @date.Date::new(year + 1, 1, 1), msg="\{year} 年的天数")
  }
  assert_eq(checked, expected_from.days_between(expected_through) + 1)
  // 周六的补班日和周日的补班日各自都出现过
  assert_true(makeup_saturdays > 0 && makeup_sundays > 0)
}

///|
test "数据版本信息" {
  let info = @holiday.data_info()
  assert_eq(info.schema_version, 1)
  assert_true(info.from < info.through)
  assert_true(info.data_version != "")
}

///|
test "审查重点:覆盖范围边界日的行为,错误里带着请求日期与覆盖范围" {
  let info = @holiday.data_info()
  // 边界当天可以查询
  ignore(@holiday.day_kind(info.from))
  ignore(@holiday.day_kind(info.through))
  // 紧邻覆盖范围的前一天、后一天,以及远处的日期,所有接口都报 DataNotCovered
  let before = info.from.add_days(-1)
  let after = info.through.add_days(1)
  for
    d in [
      before,
      after,
      @date.Date::new(1, 1, 1),
      @date.Date::new(9999, 12, 31),
    ] {
    expect_not_covered(() => ignore(@holiday.day_kind(d)), d, info)
    expect_not_covered(() => ignore(@holiday.is_holiday(d)), d, info)
    expect_not_covered(() => ignore(@holiday.is_makeup_workday(d)), d, info)
    expect_not_covered(() => ignore(@holiday.holiday_name(d)), d, info)
  }
}
