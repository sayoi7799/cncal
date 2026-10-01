///|
test "农历表自洽:相邻两年正月初一之差等于上一年各月天数之和" {
  for year in 1900..<2100 {
    let info = lunar_info[year - FIRST_YEAR]
    let next = lunar_info[year + 1 - FIRST_YEAR]
    let mut total = 0
    for slot in 0..<slot_count(info) {
      let days = slot_days(info, slot)
      assert_true(
        days == 29 || days == 30,
        msg="\{year} 年第 \{slot} 个月槽位的天数",
      )
      total += days
    }
    if leap_of(info) == 0 {
      assert_true(
        total >= 353 && total <= 355,
        msg="\{year} 年共 \{total} 天",
      )
    } else {
      assert_true(
        total >= 383 && total <= 385,
        msg="\{year} 年(有闰月)共 \{total} 天",
      )
    }
    assert_eq(
      new_year_days(year + 1, next) - new_year_days(year, info),
      total,
      msg="\{year} 年的天数应等于两个正月初一之差",
    )
  }
}

///|
test "农历表自洽:闰月在 0–12 之间,表的长度正确" {
  assert_eq(lunar_info.length(), 201)
  for info in lunar_info {
    assert_true(leap_of(info) >= 0 && leap_of(info) <= 12)
  }
}

///|
test "节气表自洽:长度正确,日期落在 3–24 号" {
  assert_eq(solar_term_days.length(), 201 * 24)
  assert_eq(term_names.length(), 24)
  for v in solar_term_days {
    assert_true(v >= 3 && v <= 24, msg="节气日期 \{v}")
  }
}
