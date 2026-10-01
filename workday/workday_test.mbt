///|
fn[T] expect_not_covered(
  f : () -> T raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.DataNotCovered(_, _, _) => ()
    e => fail("\{what}: 期望 DataNotCovered,实际 \{e}")
  } noraise {
    _ => fail("\{what}: 期望 DataNotCovered,但没有出错")
  }
}

///|
/// 覆盖范围内的所有日期(升序)。
fn all_days() -> Array[@date.Date] raise {
  let info = @holiday.data_info()
  let result : Array[@date.Date] = []
  let mut d = info.from
  while d <= info.through {
    result.push(d)
    d = d.add_days(1)
  }
  result
}

///|
/// 结果会跑出覆盖范围时返回 `None`,其余错误照常抛出。
fn try_add(d : @date.Date, n : Int) -> @date.Date? raise {
  try @workday.add_workdays(d, n) catch {
    @date.DataNotCovered(_, _, _) => None
    e => raise e
  } noraise {
    r => Some(r)
  }
}

///|
test "add_workdays 与 chinese-days 的 findWorkday 及设计定义一致" {
  let root = @jsonx.parse(workday_cases_json)
  let adds = @jsonx.as_array(@jsonx.field(root, "add"))
  assert_true(adds.length() > 1000)
  let mut from_cd = 0
  let mut from_ref = 0
  for rec in adds {
    let from = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "from")))
    let n = @jsonx.as_int(@jsonx.field(rec, "n"))
    let to = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "to")))
    match @jsonx.as_string(@jsonx.field(rec, "src")) {
      "cd" => from_cd += 1
      _ => from_ref += 1
    }
    assert_eq(
      @workday.add_workdays(from, n),
      to,
      msg="\{from} + \{n} 个工作日",
    )
  }
  // 两类用例都确实出现过
  assert_true(from_cd > 0 && from_ref > 0)
}

///|
test "workdays_between 与 chinese-days 的 getWorkdaysInRange 及设计定义一致" {
  let root = @jsonx.parse(workday_cases_json)
  let items = @jsonx.as_array(@jsonx.field(root, "between"))
  assert_true(items.length() > 500)
  for rec in items {
    let a = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "a")))
    let b = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "b")))
    let count = @jsonx.as_int(@jsonx.field(rec, "count"))
    assert_eq(@workday.workdays_between(a, b), count, msg="\{a} 到 \{b}")
  }
}

///|
test "is_workday 逐日与 chinese-days 的 isWorkday 一致(含调休补班的周六周日)" {
  let root = @jsonx.parse(workday_cases_json)
  let mut makeup_weekend = 0
  for rec in @jsonx.as_array(@jsonx.field(root, "flags")) {
    let year = @jsonx.as_int(@jsonx.field(rec, "y"))
    let flags = @jsonx.as_string(@jsonx.field(rec, "f"))
    let mut d = @date.Date::new(year, 1, 1)
    for i in 0..<flags.length() {
      let expected = flags[i] == '1'
      assert_eq(@workday.is_workday(d), expected, msg="is_workday \{d}")
      if expected && d.weekday().is_weekend() {
        makeup_weekend += 1
      }
      d = d.add_days(1)
    }
    assert_eq(d, @date.Date::new(year + 1, 1, 1), msg="\{year} 年的天数")
  }
  // 数据里确实有「周末上班」的日子,并且它们都被算作工作日
  assert_true(makeup_weekend > 100)
}

///|
test "文档示例(设计文档 §5.4.3):跨国庆长假、补班日、n=0 与负数" {
  let root = @jsonx.parse(workday_cases_json)
  for rec in @jsonx.as_array(@jsonx.field(root, "examples_add")) {
    let from = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "from")))
    let n = @jsonx.as_int(@jsonx.field(rec, "n"))
    let to = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "to")))
    assert_eq(@workday.add_workdays(from, n), to, msg="示例 \{from} + \{n}")
  }
  for rec in @jsonx.as_array(@jsonx.field(root, "examples_between")) {
    let a = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "a")))
    let b = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "b")))
    let count = @jsonx.as_int(@jsonx.field(rec, "count"))
    assert_eq(
      @workday.workdays_between(a, b),
      count,
      msg="示例 \{a} 到 \{b}",
    )
  }
}

///|
test "性质 P1 P2:n=0 返回自身;n≠0 的结果一定是工作日" {
  for d in all_days() {
    assert_eq(@workday.add_workdays(d, 0), d, msg="P1 \{d}")
    for n in [-3, -1, 1, 3] {
      match try_add(d, n) {
        Some(r) =>
          assert_true(@workday.is_workday(r), msg="P2 \{d} + \{n} = \{r}")
        None => ()
      }
    }
  }
}

///|
test "性质 P3:add_workdays 随 n 严格递增" {
  let days = all_days()
  let mut i = 0
  while i < days.length() {
    let d = days[i]
    let mut prev : @date.Date? = None
    for n in -4..<=4 {
      match try_add(d, n) {
        Some(r) => {
          match prev {
            Some(p) =>
              assert_true(
                p < r,
                msg="P3 \{d}: n=\{n} 的结果 \{r} 不大于上一个 \{p}",
              )
            None => ()
          }
          prev = Some(r)
        }
        None => ()
      }
    }
    i += 7
  }
}

///|
test "性质 P4 P5:workdays_between 反对称且可加" {
  let days = all_days()
  let steps = [1, 3, 10, 40]
  let mut i = 0
  while i < days.length() {
    let a = days[i]
    for x in steps {
      if i + x < days.length() {
        let b = days[i + x]
        assert_eq(
          @workday.workdays_between(a, b),
          -@workday.workdays_between(b, a),
          msg="P4 \{a} \{b}",
        )
        for y in steps {
          if i + x + y < days.length() {
            let c = days[i + x + y]
            assert_eq(
              @workday.workdays_between(a, c),
              @workday.workdays_between(a, b) + @workday.workdays_between(b, c),
              msg="P5 \{a} \{b} \{c}",
            )
          }
        }
      }
    }
    assert_eq(@workday.workdays_between(a, a), 0, msg="P4 \{a}")
    i += 11
  }
}

///|
test "性质 P6:workdays_between 与 add_workdays 互为逆运算(起算日是工作日时恒成立)" {
  let days = all_days()
  let mut i = 0
  while i < days.length() {
    let a = days[i]
    for n in [-7, -1, 1, 3, 7, 11] {
      match try_add(a, n) {
        Some(b) => {
          let c = @workday.workdays_between(a, b)
          if @workday.is_workday(a) || n < 0 {
            assert_eq(c, n, msg="P6 \{a} + \{n} = \{b}")
          } else {
            // 起算日不是工作日且向后加:[a, b) 里恰好少算了一个
            assert_eq(c, n - 1, msg="P6 \{a} + \{n} = \{b}")
          }
        }
        None => ()
      }
    }
    i += 5
  }
}

///|
test "审查重点:极端的 n 与覆盖范围边界,add_workdays 返回 DataNotCovered" {
  let info = @holiday.data_info()
  let mid = @date.Date::new(2015, 6, 15)
  // Int 的最大/最小值:走出覆盖范围就报错,不会回绕,也不会死循环
  expect_not_covered(
    () => @workday.add_workdays(mid, 2147483647),
    "mid + Int 最大值",
  )
  expect_not_covered(
    () => @workday.add_workdays(mid, -2147483648),
    "mid + Int 最小值",
  )
  // 覆盖范围末日再往后一个工作日,首日再往前一个工作日
  try @workday.add_workdays(info.through, 1) catch {
    @date.DataNotCovered(requested, from, through) => {
      assert_eq(requested, info.through.add_days(1))
      assert_eq(from, info.from)
      assert_eq(through, info.through)
    }
    e => fail("期望 DataNotCovered,实际 \{e}")
  } noraise {
    r => fail("期望 DataNotCovered,实际得到 \{r}")
  }
  expect_not_covered(() => @workday.add_workdays(info.from, -1), "首日 - 1")
  // 起算日本身不在覆盖范围内,即使 n = 0 也报错
  expect_not_covered(
    () => @workday.add_workdays(info.through.add_days(1), 0),
    "末日后一天 + 0",
  )
  expect_not_covered(
    () => @workday.add_workdays(info.from.add_days(-1), 0),
    "首日前一天 + 0",
  )
}

///|
test "审查重点:is_workday 与 workdays_between 在覆盖范围边界上的行为" {
  let info = @holiday.data_info()
  let before = info.from.add_days(-1)
  let after = info.through.add_days(1)
  expect_not_covered(() => @workday.is_workday(before), "首日前一天")
  expect_not_covered(() => @workday.is_workday(after), "末日后一天")
  // 结束日不参与计数([a, b) 不含 b),但也必须在覆盖范围内
  expect_not_covered(
    () => @workday.workdays_between(info.through, after),
    "[末日, 末日后一天)",
  )
  expect_not_covered(
    () => @workday.workdays_between(before, info.from),
    "[首日前一天, 首日)",
  )
  // 起止相同也要检查覆盖范围
  expect_not_covered(
    () => @workday.workdays_between(after, after),
    "[末日后一天, 末日后一天)",
  )
  // 覆盖范围内的整段区间可以计算,正反相反
  let total = @workday.workdays_between(info.from, info.through)
  assert_true(
    total > 5000,
    msg="整个覆盖范围内应有数千个工作日,实际 \{total}",
  )
  assert_eq(@workday.workdays_between(info.through, info.from), -total)
  assert_eq(@workday.workdays_between(info.through, info.through), 0)
}
