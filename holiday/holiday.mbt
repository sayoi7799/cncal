///|
/// 一天的类型。
///
/// - `Workday`:普通工作日(周一到周五,且不在放假区间内)
/// - `Weekend`:普通周末(周六日,不在放假区间内,也不是补班日)
/// - `Holiday(name)`:放假日,附节日名。包含因调休而连休的工作日,
///   也包含落在放假区间内的周六周日
/// - `MakeupWorkday(name)`:调休补班日(周六或周日上班),附相关节日名
pub(all) enum DayKind {
  Workday
  Weekend
  Holiday(String)
  MakeupWorkday(String)
} derive(Eq, Debug)

///|
/// 嵌入数据的版本与覆盖范围(含两端)。
pub struct DataInfo {
  schema_version : Int
  data_version : String
  from : @date.Date
  through : @date.Date
} derive(Eq, Debug)

///|
/// 首次使用时才解析并校验嵌入的 JSON,结果缓存。`Lazy.force` 本身不会抛错,
/// 所以缓存的是 `Result`,在调用处再 `raise`。
let table_cell : @lazy.Lazy[Result[Table, @date.CalendarError]] = @lazy.Lazy(() => {
  try parse_table(holidays_json) catch {
    e => Err(e)
  } noraise {
    t => Ok(t)
  }
})

///|
fn table() -> Table raise @date.CalendarError {
  match table_cell.force() {
    Ok(t) => t
    Err(e) => raise e
  }
}

///|
pub fn data_info() -> DataInfo raise @date.CalendarError {
  table().info
}

///|
/// 某一天的类型。日期不在覆盖范围内报 `DataNotCovered`,**绝不会**把未覆盖的日期当成普通周末。
pub fn day_kind(d : @date.Date) -> DayKind raise @date.CalendarError {
  let t = table()
  let n = d.to_days()
  if n < t.from_days || n > t.through_days {
    raise @date.DataNotCovered(d, t.info.from, t.info.through)
  }
  match t.days.get(n) {
    Some(kind) => kind
    None => if d.weekday().is_weekend() { Weekend } else { Workday }
  }
}

///|
/// 是否放假日。普通周末返回 `false`(它的类型是 `Weekend`);
/// 与 chinese-days 的 `isHoliday`(等于「不是工作日」)不同,与它的数据字段 `holidays` 一致。
pub fn is_holiday(d : @date.Date) -> Bool raise @date.CalendarError {
  match day_kind(d) {
    Holiday(_) => true
    _ => false
  }
}

///|
pub fn is_makeup_workday(d : @date.Date) -> Bool raise @date.CalendarError {
  match day_kind(d) {
    MakeupWorkday(_) => true
    _ => false
  }
}

///|
/// 节日名。放假日和补班日都返回相关的节日名,其余为 `None`。
pub fn holiday_name(d : @date.Date) -> String? raise @date.CalendarError {
  match day_kind(d) {
    Holiday(name) => Some(name)
    MakeupWorkday(name) => Some(name)
    _ => None
  }
}
