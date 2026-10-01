///|
test "README 最小示例:日期、农历、节气、节假日、工作日" {
  // 日期
  let d = @cncal.Date::new(2026, 9, 30)
  assert_eq("\{d.add_days(1)}", "2026-10-01")
  assert_eq(d.weekday(), @cncal.Weekday::Wednesday)

  // 公历 → 农历(2023 年有闰二月)
  let lunar = @cncal.solar_to_lunar(@cncal.Date::new(2023, 3, 22))
  assert_eq("\{lunar}", "2023-闰02-01")
  assert_eq("\{@cncal.lunar_to_solar(lunar)}", "2023-03-22")

  // 二十四节气
  let term = @cncal.solar_terms(2024)[2]
  assert_eq(term.term.name(), "立春")
  assert_eq("\{term.date}", "2024-02-04")

  // 节假日与调休
  let national_day = @cncal.Date::new(2026, 10, 1)
  assert_eq(@cncal.is_holiday(national_day), true)
  assert_eq(@cncal.holiday_name(national_day), Some("国庆节"))
  let makeup = @cncal.Date::new(2026, 10, 10) // 周六,国庆调休补班
  assert_eq(@cncal.is_makeup_workday(makeup), true)
  assert_eq(@cncal.is_workday(makeup), true)

  // 工作日计算:2026-09-30 之后的第 1 个工作日,跨过 7 天国庆长假
  assert_eq("\{@cncal.add_workdays(d, 1)}", "2026-10-08")
  assert_eq(@cncal.workdays_between(d, @cncal.Date::new(2026, 10, 12)), 4)

  // 数据未涵盖的年份必须报错,不会当成普通周末
  try @cncal.is_workday(@cncal.Date::new(2099, 1, 1)) catch {
    @cncal.CalendarError::DataNotCovered(_, _, _) => ()
    e => fail("期望 DataNotCovered,实际 \{e}")
  } noraise {
    _ => fail("期望 DataNotCovered")
  }
}
