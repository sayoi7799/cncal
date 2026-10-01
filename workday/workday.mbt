///|
/// 是否工作日:调休补班日,或者周一到周五且不在放假区间内。
/// 日期不在节假日数据的覆盖范围内报 `DataNotCovered`。
pub fn is_workday(d : @date.Date) -> Bool raise @date.CalendarError {
  match @holiday.day_kind(d) {
    Workday | MakeupWorkday(_) => true
    Weekend | Holiday(_) => false
  }
}

///|
/// `d` 之后(`n > 0`)或之前(`n < 0`)的第 `|n|` 个工作日。**起算日 `d` 不计入**,
/// 不论它是不是工作日;`n = 0` 原样返回 `d`,即使 `d` 不是工作日。
///
/// 起算日必须在覆盖范围内(即使 `n = 0`);计算经过的每一天也必须在覆盖范围内,
/// 否则整个调用返回 `DataNotCovered`,绝不会把没有数据的日期当成普通周末。
pub fn add_workdays(
  d : @date.Date,
  n : Int,
) -> @date.Date raise @date.CalendarError {
  // 起算日必须在覆盖范围内
  ignore(@holiday.day_kind(d))
  if n == 0 {
    return d
  }
  let step = if n > 0 { 1 } else { -1 }
  // 「剩余步数趋向 0」,避免对 Int 的最小值取负
  let mut remaining = n
  let mut cur = d
  while remaining != 0 {
    cur = cur.add_days(step)
    if is_workday(cur) {
      remaining = remaining - step
    }
  }
  cur
}

///|
/// 区间 `[a, b)` 内的工作日个数:**含 `a`、不含 `b`**。`a > b` 时是相反数。
/// `a` 与 `b` 都必须在覆盖范围内(即使 `a == b`),区间内的每一天也必须在覆盖范围内。
pub fn workdays_between(
  a : @date.Date,
  b : @date.Date,
) -> Int raise @date.CalendarError {
  ignore(@holiday.day_kind(a))
  ignore(@holiday.day_kind(b))
  if a == b {
    return 0
  }
  if a > b {
    return -workdays_between(b, a)
  }
  let mut count = 0
  let mut cur = a
  while cur < b {
    if is_workday(cur) {
      count = count + 1
    }
    cur = cur.add_days(1)
  }
  count
}
