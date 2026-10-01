///|
/// 二十四节气,按一个公历年内的先后顺序:小寒在前,冬至在后。
pub(all) enum SolarTerm {
  XiaoHan
  DaHan
  LiChun
  YuShui
  JingZhe
  ChunFen
  QingMing
  GuYu
  LiXia
  XiaoMan
  MangZhong
  XiaZhi
  XiaoShu
  DaShu
  LiQiu
  ChuShu
  BaiLu
  QiuFen
  HanLu
  ShuangJiang
  LiDong
  XiaoXue
  DaXue
  DongZhi
} derive(Eq, Compare, Debug)

///|
let all_terms : FixedArray[SolarTerm] = [
  XiaoHan,
  DaHan,
  LiChun,
  YuShui,
  JingZhe,
  ChunFen,
  QingMing,
  GuYu,
  LiXia,
  XiaoMan,
  MangZhong,
  XiaZhi,
  XiaoShu,
  DaShu,
  LiQiu,
  ChuShu,
  BaiLu,
  QiuFen,
  HanLu,
  ShuangJiang,
  LiDong,
  XiaoXue,
  DaXue,
  DongZhi,
]

///|
let term_names : FixedArray[String] = [
  "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨",
  "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑",
  "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
]

///|
/// 节气在一个公历年内的序号:小寒为 0,冬至为 23。
pub fn SolarTerm::index(self : SolarTerm) -> Int {
  match self {
    XiaoHan => 0
    DaHan => 1
    LiChun => 2
    YuShui => 3
    JingZhe => 4
    ChunFen => 5
    QingMing => 6
    GuYu => 7
    LiXia => 8
    XiaoMan => 9
    MangZhong => 10
    XiaZhi => 11
    XiaoShu => 12
    DaShu => 13
    LiQiu => 14
    ChuShu => 15
    BaiLu => 16
    QiuFen => 17
    HanLu => 18
    ShuangJiang => 19
    LiDong => 20
    XiaoXue => 21
    DaXue => 22
    DongZhi => 23
  }
}

///|
/// 节气的中文名,如「小寒」「冬至」。
pub fn SolarTerm::name(self : SolarTerm) -> String {
  term_names[self.index()]
}

///|
/// 某个节气及其公历日期。
pub struct SolarTermDate {
  term : SolarTerm
  date : @date.Date
} derive(Eq, Debug)

///|
pub impl Show for SolarTermDate with fn output(self, logger) {
  logger.write_string("\{self.term.name()} \{self.date}")
}

///|
/// 某个公历年的 24 个节气,按日期升序,从小寒到冬至。
/// 年份不在 1900–2100 报 `OutOfRange`。节气按公历年查询,不受农历域边界限制。
pub fn solar_terms(
  year : Int,
) -> Array[SolarTermDate] raise @date.CalendarError {
  if year < FIRST_YEAR || year > LAST_YEAR {
    raise @date.OutOfRange(
      "节气年份必须在 \{FIRST_YEAR} 到 \{LAST_YEAR} 之间: \{year}",
    )
  }
  let base = (year - FIRST_YEAR) * 24
  let result : Array[SolarTermDate] = []
  for k in 0..<24 {
    // 第 k 个节气所在的公历月固定为 k / 2 + 1,表里只需要存「几号」。
    result.push({
      term: all_terms[k],
      date: @date.Date::new(year, k / 2 + 1, solar_term_days[base + k]),
    })
  }
  result
}
