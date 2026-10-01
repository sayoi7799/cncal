///|
/// 加载并校验后的节假日数据。
priv struct Table {
  info : DataInfo
  from_days : Int
  through_days : Int
  days : Map[Int, DayKind]
}

///|
/// 解析日期字符串;格式或日期不合法按「数据损坏」处理。
fn date_of(s : String) -> @date.Date raise @date.CalendarError {
  @date.Date::from_iso(s) catch {
    @date.InvalidDate(msg) => raise @date.DataCorrupt("日期无效: \{msg}")
    e => raise e
  }
}

///|
fn nonempty(name : String) -> String raise @date.CalendarError {
  if name == "" {
    raise @date.DataCorrupt("节日名称不能为空")
  }
  name
}

///|
/// 解析并校验节假日 JSON(格式见设计文档 §5.3.1),任何问题都返回 `DataCorrupt`。
fn parse_table(raw : String) -> Table raise @date.CalendarError {
  let root = @jsonx.parse(raw)
  let version = @jsonx.as_int(@jsonx.field(root, "schema_version"))
  if version != 1 {
    raise @date.DataCorrupt("不支持的 schema_version: \{version}")
  }
  let data_version = @jsonx.as_string(@jsonx.field(root, "data_version"))
  let coverage = @jsonx.field(root, "coverage")
  let from = date_of(@jsonx.as_string(@jsonx.field(coverage, "from")))
  let through = date_of(@jsonx.as_string(@jsonx.field(coverage, "through")))
  if from > through {
    raise @date.DataCorrupt("coverage.from 晚于 coverage.through")
  }
  let from_days = from.to_days()
  let through_days = through.to_days()
  let days : Map[Int, DayKind] = Map([])
  // 放假区间:起止不颠倒、按日期升序、互不重叠、都在覆盖范围内
  let mut prev_to = from_days - 1
  for rec in @jsonx.as_array(@jsonx.field(root, "holidays")) {
    let name = nonempty(@jsonx.as_string(@jsonx.field(rec, "name")))
    let a = date_of(@jsonx.as_string(@jsonx.field(rec, "from"))).to_days()
    let b = date_of(@jsonx.as_string(@jsonx.field(rec, "to"))).to_days()
    if a > b {
      raise @date.DataCorrupt("放假区间起止颠倒: \{name}")
    }
    if a <= prev_to {
      raise @date.DataCorrupt(
        "放假区间未按日期升序排列或发生重叠: \{name}",
      )
    }
    if a < from_days || b > through_days {
      raise @date.DataCorrupt("放假区间超出 coverage: \{name}")
    }
    for n in a..<=b {
      days[n] = Holiday(name)
    }
    prev_to = b
  }
  // 补班日:在覆盖范围内、是周六或周日、不在放假区间内、不重复
  for rec in @jsonx.as_array(@jsonx.field(root, "workdays")) {
    let name = nonempty(@jsonx.as_string(@jsonx.field(rec, "name")))
    let date = date_of(@jsonx.as_string(@jsonx.field(rec, "date")))
    let n = date.to_days()
    if n < from_days || n > through_days {
      raise @date.DataCorrupt("补班日超出 coverage: \{date}")
    }
    if !date.weekday().is_weekend() {
      raise @date.DataCorrupt("补班日必须是周六或周日: \{date}")
    }
    if days.contains(n) {
      raise @date.DataCorrupt(
        "补班日与放假日或其他补班日重复: \{date}",
      )
    }
    days[n] = MakeupWorkday(name)
  }
  {
    info: { schema_version: version, data_version, from, through, },
    from_days,
    through_days,
    days,
  }
}
