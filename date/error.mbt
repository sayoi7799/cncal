///|
/// 本库所有可失败操作使用的错误类型。
///
/// - `InvalidDate`:不存在的日期(如 2023-02-29、13 月),或农历的闰月标记与该年不符
/// - `OutOfRange`:超出支持范围(`Date` 的 1–9999 年、农历域、节气年份)
/// - `DataNotCovered`:节假日数据未涵盖该日期;依次是请求的日期、已覆盖范围的起、已覆盖范围的止
/// - `DataCorrupt`:嵌入的节假日数据未通过校验
///
/// 调用方用 `try … catch { … } noraise { … }` 处理。接口契约是错误的类别,不是错误文字。
/// 声明为 `pub(all)`:普通的 `pub suberror` 在包外是只读类型,兄弟包就无法 `raise` 这些变体。
pub(all) suberror CalendarError {
  InvalidDate(String)
  OutOfRange(String)
  DataNotCovered(Date, Date, Date)
  DataCorrupt(String)
} derive(Eq, Debug)

///|
pub impl Show for CalendarError with fn output(self, logger) {
  match self {
    InvalidDate(msg) => logger.write_string("无效日期: \{msg}")
    OutOfRange(msg) => logger.write_string("超出支持范围: \{msg}")
    DataNotCovered(d, from, through) =>
      logger.write_string(
        "节假日数据未涵盖 \{d}(已涵盖 \{from} 至 \{through})",
      )
    DataCorrupt(msg) => logger.write_string("节假日数据损坏: \{msg}")
  }
}
