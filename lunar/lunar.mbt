///|
const FIRST_YEAR : Int = 1900

///|
const LAST_YEAR : Int = 2100

///|
/// 农历日期。字段对外只读;只能经 `LunarDate::new` 或 `solar_to_lunar` 构造,
/// 所以任何 `LunarDate` 值都对应真实存在的农历日。
/// 闰月用 `is_leap` 标记,`month` 仍是 1–12 的月份数字。
pub struct LunarDate {
  year : Int
  month : Int
  is_leap : Bool
  day : Int
} derive(Eq, Compare, Debug)

///|
fn pad2(n : Int) -> String {
  if n < 10 {
    "0\{n}"
  } else {
    "\{n}"
  }
}

///|
pub impl Show for LunarDate with fn output(self, logger) {
  let leap = if self.is_leap { "闰" } else { "" }
  logger.write_string(
    "\{self.year}-\{leap}\{pad2(self.month)}-\{pad2(self.day)}",
  )
}

///|
/// 取某年的年表项;年份不在 1900–2100 报 `OutOfRange`。
fn info_of(year : Int) -> Int raise @date.CalendarError {
  if year < FIRST_YEAR || year > LAST_YEAR {
    raise @date.OutOfRange(
      "农历年份必须在 \{FIRST_YEAR} 到 \{LAST_YEAR} 之间: \{year}",
    )
  }
  lunar_info[year - FIRST_YEAR]
}

///|
/// 闰月月份(0 表示无闰月)。
fn leap_of(info : Int) -> Int {
  info & 0xF
}

///|
/// 一年的月槽位个数:无闰月 12 个,有闰月 13 个。
fn slot_count(info : Int) -> Int {
  if leap_of(info) == 0 {
    12
  } else {
    13
  }
}

///|
/// 第 `slot` 个月槽位的天数(30 或 29)。
fn slot_days(info : Int, slot : Int) -> Int {
  if ((info >> (4 + slot)) & 1) == 1 {
    30
  } else {
    29
  }
}

///|
/// 正月初一的公历日期,表示为距 1970-01-01 的天数。
fn new_year_days(year : Int, info : Int) -> Int raise @date.CalendarError {
  @date.Date::new(year, 1, 21).to_days() + ((info >> 17) & 0x1F)
}

///|
/// 月槽位 → (月份, 是否闰月)。闰月紧跟在同数字的正常月之后。
fn month_of_slot(leap : Int, slot : Int) -> (Int, Bool) {
  if leap == 0 || slot < leap {
    (slot + 1, false)
  } else if slot == leap {
    (leap, true)
  } else {
    (slot, false)
  }
}

///|
/// (月份, 是否闰月) → 月槽位。
fn slot_of_month(leap : Int, month : Int, is_leap : Bool) -> Int {
  if leap == 0 || month < leap || (month == leap && !is_leap) {
    month - 1
  } else {
    month
  }
}

///|
/// 构造农历日期并校验:年份不在 1900–2100 报 `OutOfRange`;月份、闰月标记、日期
/// 与该年的实际情况不符报 `InvalidDate`。
pub fn LunarDate::new(
  year : Int,
  month : Int,
  is_leap : Bool,
  day : Int,
) -> LunarDate raise @date.CalendarError {
  let info = info_of(year)
  let leap = leap_of(info)
  if month < 1 || month > 12 {
    raise @date.InvalidDate("农历月份必须在 1 到 12 之间: \{month}")
  }
  if is_leap && leap != month {
    raise @date.InvalidDate("农历 \{year} 年没有闰 \{month} 月")
  }
  let days = slot_days(info, slot_of_month(leap, month, is_leap))
  if day < 1 || day > days {
    let leap_text = if is_leap { "闰" } else { "" }
    raise @date.InvalidDate(
      "农历 \{year} 年\{leap_text}\{month} 月只有 \{days} 天,没有第 \{day} 天",
    )
  }
  { year, month, is_leap, day, }
}

///|
/// 闰月月份;该年没有闰月返回 0。
pub fn leap_month(year : Int) -> Int raise @date.CalendarError {
  leap_of(info_of(year))
}

///|
/// 某个农历月的天数(29 或 30);月份或闰月标记不合法报 `InvalidDate`。
pub fn month_days(
  year : Int,
  month : Int,
  is_leap : Bool,
) -> Int raise @date.CalendarError {
  let _ = LunarDate::new(year, month, is_leap, 1)
  let info = info_of(year)
  slot_days(info, slot_of_month(leap_of(info), month, is_leap))
}

///|
/// 公历 → 农历。日期不在 1900-01-31 ~ 2101-01-28 报 `OutOfRange`。
pub fn solar_to_lunar(d : @date.Date) -> LunarDate raise @date.CalendarError {
  let n = d.to_days()
  let first = @date.Date::new(1900, 1, 31)
  let last = @date.Date::new(2101, 1, 28)
  if n < first.to_days() || n > last.to_days() {
    raise @date.OutOfRange(
      "日期超出农历支持范围 \{first} 至 \{last}: \{d}",
    )
  }
  // 正月初一一定落在 1 月 21 日 ~ 2 月 20 日,所以农历年只可能是公历年本身或前一年。
  // 2101 年没有表,2101-01-01 ~ 2101-01-28 一律归入农历 2100 年。
  let mut year = d.year
  if year > LAST_YEAR || n < new_year_days(year, info_of(year)) {
    year = year - 1
  }
  let info = info_of(year)
  let mut rest = n - new_year_days(year, info)
  let mut slot = 0
  while slot < slot_count(info) && rest >= slot_days(info, slot) {
    rest = rest - slot_days(info, slot)
    slot = slot + 1
  }
  if slot >= slot_count(info) {
    raise @date.DataCorrupt("农历表与日期不一致: \{d}")
  }
  let (month, is_leap) = month_of_slot(leap_of(info), slot)
  { year, month, is_leap, day: rest + 1, }
}

///|
/// 农历 → 公历。`LunarDate` 一定是合法的,所以这里只做加法。
pub fn lunar_to_solar(l : LunarDate) -> @date.Date raise @date.CalendarError {
  let info = info_of(l.year)
  let slot = slot_of_month(leap_of(info), l.month, l.is_leap)
  let mut days = new_year_days(l.year, info)
  for s in 0..<slot {
    days = days + slot_days(info, s)
  }
  @date.Date::from_days(days + l.day - 1)
}
