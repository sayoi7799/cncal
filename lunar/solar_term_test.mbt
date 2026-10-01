///|
test "二十四节气在 1900–2100 全部年份与 lunar-python 一致" {
  let root = @jsonx.parse(solar_terms_json)
  let names = @jsonx.as_array(@jsonx.field(@jsonx.field(root, "meta"), "names"))
  assert_eq(names.length(), 24)
  let years = @jsonx.as_array(@jsonx.field(root, "years"))
  assert_eq(years.length(), 201)
  for rec in years {
    let y = @jsonx.as_int(@jsonx.field(rec, "y"))
    let expected = @jsonx.as_array(@jsonx.field(rec, "t"))
    let actual = @lunar.solar_terms(y)
    assert_eq(actual.length(), 24, msg="\{y} 年的节气个数")
    for k in 0..<24 {
      let pair = @jsonx.as_array(expected[k])
      let month = @jsonx.as_int(pair[0])
      let day = @jsonx.as_int(pair[1])
      assert_eq(
        actual[k].date,
        @date.Date::new(y, month, day),
        msg="\{y} 年第 \{k} 个节气的日期",
      )
      assert_eq(
        actual[k].term.name(),
        @jsonx.as_string(names[k]),
        msg="\{y} 年第 \{k} 个节气的名称",
      )
      assert_eq(actual[k].term.index(), k)
    }
  }
}

///|
test "每年的节气按日期严格递增,小寒在前,冬至在后" {
  for y in 1900..<=2100 {
    let terms = @lunar.solar_terms(y)
    assert_eq(terms[0].term, @lunar.XiaoHan)
    assert_eq(terms[23].term, @lunar.DongZhi)
    for k in 0..<23 {
      assert_true(
        terms[k].date < terms[k + 1].date,
        msg="\{y} 年第 \{k} 个节气",
      )
    }
  }
}

///|
test "节气只依赖公历年,不受农历域边界限制(1900 年的小寒在 1900-01-31 之前)" {
  let terms = @lunar.solar_terms(1900)
  assert_true(terms[0].date < @date.Date::new(1900, 1, 31))
}

///|
test "审查重点:节气年份越界报 OutOfRange" {
  for y in [1899, 2101, 0, -1, 2147483647, -2147483648] {
    expect_out_of_range(() => @lunar.solar_terms(y), "solar_terms(\{y})")
  }
}
