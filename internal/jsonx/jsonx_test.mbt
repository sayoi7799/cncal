///|
test "读取各种类型的字段" {
  let j = @jsonx.parse(
    "{\"a\":[1,2,3],\"b\":\"中文\",\"c\":true,\"d\":null,\"e\":-7,\"f\":{\"g\":1}}",
  )
  assert_eq(@jsonx.as_array(@jsonx.field(j, "a")).length(), 3)
  assert_eq(@jsonx.as_string(@jsonx.field(j, "b")), "中文")
  assert_eq(@jsonx.as_bool(@jsonx.field(j, "c")), true)
  assert_true(@jsonx.is_null(@jsonx.field(j, "d")))
  assert_eq(@jsonx.as_int(@jsonx.field(j, "e")), -7)
  let f = @jsonx.as_object(@jsonx.field(j, "f"))
  assert_eq(@jsonx.as_int(f.get("g").unwrap()), 1)
}

///|
fn expect_corrupt(
  f : () -> Unit raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.DataCorrupt(_) => ()
    e => fail("\{what}: 期望 DataCorrupt,实际 \{e}")
  } noraise {
    _ => fail("\{what}: 期望 DataCorrupt,但没有出错")
  }
}

///|
test "结构不符或不是 JSON 时抛 DataCorrupt" {
  expect_corrupt(() => ignore(@jsonx.parse("{not json")), "非法 JSON")
  let j = @jsonx.parse("{\"a\":1,\"s\":\"x\"}")
  expect_corrupt(() => ignore(@jsonx.field(j, "缺失")), "缺少字段")
  expect_corrupt(
    () => ignore(@jsonx.as_string(@jsonx.field(j, "a"))),
    "数字当字符串",
  )
  expect_corrupt(
    () => ignore(@jsonx.as_int(@jsonx.field(j, "s"))),
    "字符串当数字",
  )
  expect_corrupt(() => ignore(@jsonx.as_array(j)), "对象当数组")
  expect_corrupt(() => ignore(@jsonx.as_bool(j)), "对象当布尔值")
  expect_corrupt(
    () => ignore(@jsonx.field(@jsonx.parse("[1]"), "a")),
    "数组取字段",
  )
}
