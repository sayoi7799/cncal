///|
fn doc(
  version : Int,
  from : String,
  through : String,
  holidays : String,
  workdays : String,
) -> String {
  "{\"schema_version\":\{version},\"data_version\":\"t\",\"coverage\":{\"from\":\"\{from}\",\"through\":\"\{through}\"},\"sources\":[],\"holidays\":[\{holidays}],\"workdays\":[\{workdays}]}"
}

///|
fn hol(name : String, from : String, to : String) -> String {
  "{\"name\":\"\{name}\",\"from\":\"\{from}\",\"to\":\"\{to}\"}"
}

///|
fn wk(name : String, date : String) -> String {
  "{\"name\":\"\{name}\",\"date\":\"\{date}\"}"
}

///|
fn expect_corrupt(raw : String, what : String) -> Unit raise {
  try parse_table(raw) catch {
    @date.DataCorrupt(_) => ()
    e => fail("\{what}: 期望 DataCorrupt,实际 \{e}")
  } noraise {
    _ => fail("\{what}: 期望 DataCorrupt,但加载成功了")
  }
}

///|
test "合法的最小文档可以加载" {
  let raw = doc(
    1,
    "2026-01-01",
    "2026-12-31",
    hol("元旦", "2026-01-01", "2026-01-03"),
    wk("元旦", "2026-01-04"),
  )
  let t = parse_table(raw)
  assert_eq(t.info.from, @date.Date::new(2026, 1, 1))
  assert_eq(t.info.through, @date.Date::new(2026, 12, 31))
  assert_eq(t.days.length(), 4) // 3 个放假日 + 1 个补班日
  assert_eq(
    t.days.get(@date.Date::new(2026, 1, 3).to_days()),
    Some(Holiday("元旦")),
  )
  assert_eq(
    t.days.get(@date.Date::new(2026, 1, 4).to_days()),
    Some(MakeupWorkday("元旦")),
  )
  assert_eq(t.days.get(@date.Date::new(2026, 1, 5).to_days()), None)
}

///|
test "审查重点:损坏的数据一律返回 DataCorrupt,不会静默加载" {
  let a = "2026-01-01"
  let z = "2026-12-31"
  let h = hol("元旦", "2026-01-01", "2026-01-03")
  let w = wk("元旦", "2026-01-04")
  expect_corrupt(doc(2, a, z, h, w), "schema_version 不是 1")
  expect_corrupt(doc(1, z, a, h, w), "coverage 起止颠倒")
  expect_corrupt(
    doc(1, a, z, hol("元旦", "2026-01-03", "2026-01-01"), w),
    "放假区间起止颠倒",
  )
  expect_corrupt(
    doc(1, a, z, h + "," + hol("春节", "2026-01-03", "2026-01-05"), w),
    "放假区间重叠",
  )
  expect_corrupt(
    doc(1, a, z, hol("春节", "2026-02-01", "2026-02-03") + "," + h, w),
    "放假区间未按日期升序",
  )
  expect_corrupt(
    doc(1, a, z, hol("元旦", "2025-12-31", "2026-01-01"), w),
    "放假区间超出 coverage",
  )
  expect_corrupt(
    doc(1, a, z, h, wk("元旦", "2026-01-07")),
    "补班日是星期三",
  )
  expect_corrupt(
    doc(1, a, z, h, wk("元旦", "2026-01-03")),
    "补班日落在放假区间内",
  )
  expect_corrupt(doc(1, a, z, h, w + "," + w), "补班日重复")
  expect_corrupt(
    doc(1, a, z, h, wk("元旦", "2027-01-03")),
    "补班日超出 coverage",
  )
  expect_corrupt(
    doc(1, a, z, hol("", "2026-01-01", "2026-01-03"), w),
    "节日名称为空",
  )
  expect_corrupt(doc(1, a, z, h, wk("", "2026-01-04")), "补班日名称为空")
  expect_corrupt(
    doc(1, a, z, hol("元旦", "2026-02-30", "2026-03-01"), w),
    "日期不存在",
  )
  expect_corrupt(
    doc(1, a, z, hol("元旦", "2026-1-1", "2026-01-03"), w),
    "日期格式不对",
  )
  expect_corrupt("not json", "不是 JSON")
  expect_corrupt("{}", "缺少字段")
  expect_corrupt("{\"schema_version\":1}", "缺少 data_version 等字段")
  expect_corrupt("[1,2,3]", "根不是对象")
}
