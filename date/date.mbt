///|
/// 公历日期(预推公历,1–9999 年)。
///
/// 字段对外只读;只能经 `Date::new`、`Date::from_iso`、`Date::from_days`、
/// `Date::add_days` 构造,所以任何 `Date` 值都是合法日期。
pub struct Date {
  year : Int
  month : Int
  day : Int
} derive(Eq, Compare, Debug)

///|
fn pad(n : Int, width : Int) -> String {
  let mut s = n.to_string()
  while s.length() < width {
    s = "0" + s
  }
  s
}

///|
pub impl Show for Date with fn output(self, logger) {
  logger.write_string(
    "\{pad(self.year, 4)}-\{pad(self.month, 2)}-\{pad(self.day, 2)}",
  )
}

///|
pub(all) enum Weekday {
  Monday
  Tuesday
  Wednesday
  Thursday
  Friday
  Saturday
  Sunday
} derive(Eq, Compare, Debug)

///|
/// ISO 8601 星期编号:周一为 1,周日为 7。
pub fn Weekday::iso_number(self : Weekday) -> Int {
  match self {
    Monday => 1
    Tuesday => 2
    Wednesday => 3
    Thursday => 4
    Friday => 5
    Saturday => 6
    Sunday => 7
  }
}

///|
pub fn Weekday::is_weekend(self : Weekday) -> Bool {
  match self {
    Saturday | Sunday => true
    _ => false
  }
}

///|
/// 0001-01-01 距 1970-01-01 的天数。
const MIN_DAYS : Int = -719162

///|
/// 9999-12-31 距 1970-01-01 的天数。
const MAX_DAYS : Int = 2932896

///|
/// 向下取整的除法(`/` 对负数向零取整)。
fn floor_div(a : Int, b : Int) -> Int {
  let q = a / b
  if a % b != 0 && (a < 0) != (b < 0) {
    q - 1
  } else {
    q
  }
}

///|
/// 向下取整的取模,结果与除数同号。
fn floor_mod(a : Int, b : Int) -> Int {
  a - floor_div(a, b) * b
}

///|
pub fn is_leap_year(year : Int) -> Bool {
  (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

///|
pub fn days_in_month(year : Int, month : Int) -> Int raise CalendarError {
  match month {
    1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
    4 | 6 | 9 | 11 => 30
    2 => if is_leap_year(year) { 29 } else { 28 }
    _ => raise InvalidDate("月份必须在 1 到 12 之间: \{month}")
  }
}

///|
/// Howard Hinnant 的 days_from_civil:预推公历日期 → 距 1970-01-01 的天数。
/// 以 400 年(146097 天)为一个纪元,把闰年规则折算成纯整数运算。
fn days_from_civil(year : Int, month : Int, day : Int) -> Int {
  let y = if month <= 2 { year - 1 } else { year }
  let era = floor_div(y, 400)
  let yoe = y - era * 400
  let mp = if month > 2 { month - 3 } else { month + 9 }
  let doy = (153 * mp + 2) / 5 + day - 1
  let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era * 146097 + doe - 719468
}

///|
/// days_from_civil 的逆运算。
fn civil_from_days(days : Int) -> (Int, Int, Int) {
  let z = days + 719468
  let era = floor_div(z, 146097)
  let doe = z - era * 146097
  let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  let y = yoe + era * 400
  let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  let mp = (5 * doy + 2) / 153
  let d = doy - (153 * mp + 2) / 5 + 1
  let m = if mp < 10 { mp + 3 } else { mp - 9 }
  (if m <= 2 { y + 1 } else { y }, m, d)
}

///|
/// 构造日期;年份不在 1–9999、月份不在 1–12、日不在当月范围内都报 `InvalidDate`。
pub fn Date::new(
  year : Int,
  month : Int,
  day : Int,
) -> Date raise CalendarError {
  if year < 1 || year > 9999 {
    raise InvalidDate("年份必须在 1 到 9999 之间: \{year}")
  }
  let dim = days_in_month(year, month)
  if day < 1 || day > dim {
    raise InvalidDate("\{year} 年 \{month} 月没有 \{day} 日")
  }
  { year, month, day, }
}

///|
/// 距 1970-01-01 的天数(1970-01-01 为 0,更早为负)。
pub fn Date::to_days(self : Date) -> Int {
  days_from_civil(self.year, self.month, self.day)
}

///|
pub fn Date::from_days(days : Int) -> Date raise CalendarError {
  if days < MIN_DAYS || days > MAX_DAYS {
    raise OutOfRange(
      "日期必须在 0001-01-01 至 9999-12-31 之间(距 1970-01-01 \{days} 天)",
    )
  }
  let (year, month, day) = civil_from_days(days)
  { year, month, day, }
}

///|
/// 加(或减)若干天。结果超出 0001-01-01 ~ 9999-12-31 报 `OutOfRange`。
///
/// `Int` 加法溢出回绕后得到的数值一定远在合法范围之外(合法范围只有约 365 万天,
/// 而回绕会让结果落在 ±21 亿附近),所以不会回绕成一个看似合法的日期。
pub fn Date::add_days(self : Date, n : Int) -> Date raise CalendarError {
  Date::from_days(self.to_days() + n)
}

///|
/// `b - a` 的天数。
pub fn Date::days_between(a : Date, b : Date) -> Int {
  b.to_days() - a.to_days()
}

///|
pub fn Date::weekday(self : Date) -> Weekday {
  // 1970-01-01 是星期四;向下取整的取模让负的天数也正确。
  match floor_mod(self.to_days() + 3, 7) {
    0 => Monday
    1 => Tuesday
    2 => Wednesday
    3 => Thursday
    4 => Friday
    5 => Saturday
    _ => Sunday
  }
}

///|
/// 从 `from` 开始读取 `count` 位十进制数字;位数不足或含非 ASCII 数字返回 `None`。
fn parse_digits(s : String, from : Int, count : Int) -> Int? {
  let mut v = 0
  for i in from..<(from + count) {
    guard i < s.length() else { return None }
    let c = s[i]
    if c >= '0' && c <= '9' {
      v = v * 10 + (c.to_int() - '0'.to_int())
    } else {
      return None
    }
  }
  Some(v)
}

///|
/// 解析严格的 `YYYY-MM-DD`(固定 10 个字符);格式不符或日期不存在都报 `InvalidDate`。
pub fn Date::from_iso(s : String) -> Date raise CalendarError {
  if s.length() != 10 || s[4] != '-' || s[7] != '-' {
    raise InvalidDate("日期格式应为 YYYY-MM-DD: \"\{s}\"")
  }
  match (parse_digits(s, 0, 4), parse_digits(s, 5, 2), parse_digits(s, 8, 2)) {
    (Some(y), Some(m), Some(d)) => Date::new(y, m, d)
    _ => raise InvalidDate("日期含非数字字符: \"\{s}\"")
  }
}
