///|
/// 示例程序:一条命令看到 cncal 的主要功能。
/// 运行方式(在项目根目录):moon run cmd/demo --target js
/// 可以换成 --target wasm-gc 或 --target native;三个后端的输出完全相同。
fn weekday_cn(w : @cncal.Weekday) -> String {
  match w {
    Monday => "一"
    Tuesday => "二"
    Wednesday => "三"
    Thursday => "四"
    Friday => "五"
    Saturday => "六"
    Sunday => "日"
  }
}

///|
fn kind_cn(k : @cncal.DayKind) -> String {
  match k {
    Workday => "工作日"
    Weekend => "普通周末"
    Holiday(name) => "放假(\{name})"
    MakeupWorkday(name) => "调休补班(\{name})"
  }
}

///|
fn demo() -> Unit raise {
  println("== 1. 日期 ==")
  let start = @cncal.Date::new(2026, 9, 30)
  println(
    "\{start} 是星期\{weekday_cn(start.weekday())};加 1 天是 \{start.add_days(1)}",
  )
  println(
    "2024 年是闰年吗?\{@cncal.is_leap_year(2024)};2024 年 2 月有 \{@cncal.days_in_month(2024, 2)} 天",
  )
  println("")
  println("== 2. 公历 ↔ 农历(含闰月) ==")
  let lunar = @cncal.solar_to_lunar(@cncal.Date::new(2023, 3, 22))
  println("公历 2023-03-22 = 农历 \{lunar}(闰二月初一)")
  println("农历 \{lunar} 转回公历是 \{@cncal.lunar_to_solar(lunar)}")
  println("2023 年的闰月是 \{@cncal.leap_month(2023)} 月")
  println("")
  println("== 3. 2024 年的二十四节气 ==")
  let terms = @cncal.solar_terms(2024)
  let mut line = ""
  for k in 0..<terms.length() {
    let t = terms[k]
    line = line + "\{t.term.name()} \{t.date}  "
    if (k + 1) % 3 == 0 {
      println("  " + line)
      line = ""
    }
  }
  println("")
  println("== 4. 2026 年国庆前后:节假日与调休 ==")
  for i in 0..<13 {
    let day = start.add_days(i)
    println(
      "  \{day} 周\{weekday_cn(day.weekday())}  \{kind_cn(@cncal.day_kind(day))}",
    )
  }
  println("")
  println("== 5. 工作日计算 ==")
  let end = @cncal.Date::new(2026, 10, 12)
  println(
    "2026-09-30 之后的第 1 个工作日:\{@cncal.add_workdays(start, 1)}(跨过 7 天长假)",
  )
  println(
    "2026-10-09 之后的第 1 个工作日:\{@cncal.add_workdays(@cncal.Date::new(2026, 10, 9), 1)}(周六补班,算工作日)",
  )
  println(
    "2026-10-08 之前的第 2 个工作日:\{@cncal.add_workdays(@cncal.Date::new(2026, 10, 8), -2)}",
  )
  println(
    "2026-10-03 加 0 个工作日:\{@cncal.add_workdays(@cncal.Date::new(2026, 10, 3), 0)}(n=0 原样返回)",
  )
  println(
    "[2026-09-30, 2026-10-12) 内的工作日个数:\{@cncal.workdays_between(start, end)}",
  )
  println(
    "[2026-10-12, 2026-09-30) 内的工作日个数:\{@cncal.workdays_between(end, start)}(反向取相反数)",
  )
  println("")
  println("== 6. 超出范围必须报错,不能悄悄当成普通周末 ==")
  try @cncal.is_workday(@cncal.Date::new(2099, 1, 1)) catch {
    e => println("2099-01-01 是工作日吗?报错:\{e}")
  } noraise {
    b => println("意外:没有报错,得到 \{b}")
  }
  try @cncal.solar_to_lunar(@cncal.Date::new(1900, 1, 30)) catch {
    e => println("1900-01-30 转农历?报错:\{e}")
  } noraise {
    l => println("意外:没有报错,得到 \{l}")
  }
  try @cncal.Date::new(2023, 2, 29) catch {
    e => println("2023-02-29?报错:\{e}")
  } noraise {
    d => println("意外:没有报错,得到 \{d}")
  }
  println("")
  println("示例结束")
}

///|
fn main {
  demo() catch {
    e => {
      println("示例运行出错:\{e}")
      abort("demo failed")
    }
  }
}
