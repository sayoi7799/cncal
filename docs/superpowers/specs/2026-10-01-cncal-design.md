# cncal 设计文档:中国日历与工作日引擎

| 项 | 内容 |
|---|---|
| 状态 | 设计已由用户确认并已实现(2026-10-01 ~ 10-02)。实现与本文档的差异见 §11 |
| 模块名 | `sayoi7799/cncal`(`sayoi7799` 是 mooncakes.io 上的用户名) |
| 许可证 | MIT |
| 工具链 | moon 0.1.20260920,moonc v0.10.14。实测 js、wasm-gc、native 三个后端均可编译并运行测试(native 使用本机 MSVC) |
| 截止时间 | MoonBit 黑客松,2026-10-24 |

## 1. 目标与验收标准

### 1.1 要解决的三个痛点

1. 每年国务院公布调休安排,各系统手工维护表格,常把补班日当成周末。
2. 「N 个工作日后」的计算(审批时限、物流、T+N 结算)各家手写、各自出错。
3. 前后端计算结果不一致:同一份 MoonBit 代码编译到 js、wasm-gc、native,结果必须完全相同。

### 1.2 验收标准

1. `moon test` 在 js、wasm-gc、native 三个后端都通过。
2. 差分测试:
   - 1900–2100 年随机抽 1000 个日期,农历转换与 lunar-python 完全一致。
   - 节气在全部年份(1900–2100)与 lunar-python 一致。
   - 节假日数据涵盖的所有年份,逐日与 chinese-days 一致。
3. README 包含安装方式、最小使用示例、「工作日语义定义」一节,并注明数据与对照项目的来源和授权。
4. 每完成一个模块,用 3–5 句话向用户解释核心逻辑(用户需要在答辩时讲清楚)。

## 2. 范围

**MVP 做:**

1. 自定义轻量 `Date` 类型:合法性检查、星期几、日期加减。
2. 公历 ↔ 农历互转(含闰月),范围 1900–2100,范围外返回明确错误。
3. 查询某年的二十四节气日期。
4. 法定节假日与调休:数据与逻辑分离;查询是否节假日、是否调休补班日、节日名称;未涵盖的年份必须报错。
5. 工作日 API:`is_workday`、`add_workdays`(支持负数)、`workdays_between`。

**明确不做:** 黄历宜忌、八字、干支、星座、港澳台节假日、时区、iCal 导出、企业自定义工作日历。

**本设计额外决定不做(YAGNI):**

- 调休休息日(chinese-days 的 `inLieuDays`)的标记。数据格式通过 `schema_version` 保留向后兼容扩展的余地。
- 农历的中文格式化(如「二〇二三年闰二月初一」)。
- 把非工作日「顺延到最近工作日」的辅助函数(见 §5.4.4)。
- 命令行程序。

## 3. 已确认的决策

| 编号 | 决策 | 理由 |
|---|---|---|
| D1 | 农历与节气用**查表**,天文算法不进库;库内全程只用 `Int`,不使用浮点 | 浮点三角函数在不同后端可能相差 1 ulp,朔日恰在午夜附近时会让日期翻转一天,直接违反痛点 3。表由脚本从 lunar-python 生成,可复现。 |
| D2 | 农历域:公历 `1900-01-31` ~ `2101-01-28` ↔ 农历 `1900-01-01` ~ `2100-12-29`;域外一律 `OutOfRange` | 这是 lunar-python 的实测边界(附录 A)。公历 1900-01-01 ~ 01-30 属农历 1899 年,不在范围内。 |
| D3 | 节假日数据:单个 `data/holidays.json` 作为唯一数据源,构建时用 `moon tool embed` 嵌入;覆盖范围用**日期区间**表达 | 不依赖文件读写(js、wasm 没有统一的 fs);日期区间能表达「年末几天要等次年通知才确定」。 |
| D4 | 5 个包:`date`、`lunar`、`holiday`、`workday`、根包 | 依赖单向,每个包可单独测试、单独讲清楚。 |
| D5 | 工作日语义见 §5.4 | 与 Excel `WORKDAY`、numpy `busday_count` 一致,互为逆运算(有条件,见 §5.4.2)。 |
| D6 | 模块名 `sayoi7799/cncal`,许可证 MIT | 与两个对照项目的 MIT 授权一致。 |
| D7 | 错误模型:`pub(all) suberror CalendarError` + `raise` | MoonBit 的惯用写法;调用方用 `try … catch …` 处理(`try?` 在当前工具链中已弃用)。错误的类别是接口契约,错误文字不是。 |
| D8 | 所有日期是**北京时间(UTC+8)的日历日** | lunar-python 的朔望与节气按北京时间计算;chinese-days 的放假安排是中国日历日。 |

## 4. 架构

### 4.1 包依赖

```
date ──┬──► lunar ───────────────┐
       │                         ├──► 根包(只做 re-export 与示例测试)
       └──► holiday ──► workday ─┘
```

- `date` 不依赖任何包,同时定义全局错误类型 `CalendarError`。
- `lunar` 依赖 `date`。
- `holiday` 依赖 `date`、`internal/jsonx` 与 `moonbitlang/core/lazy`。
- `workday` 依赖 `date` 与 `holiday`。
- 根包依赖以上四个包,自己不含逻辑。
- `lunar` 与 `holiday` 互不依赖。
- `internal/jsonx` 是模块内部的 JSON 读取小工具(`as_int`、`field` 等,出错时抛 `DataCorrupt`),只供 `holiday` 的加载器和各包的测试使用,外部无法导入。它依赖 `date` 与 `moonbitlang/core/json`。已验证:`date` 的黑盒测试可以导入 `jsonx`,不会形成依赖环。

### 4.2 目录结构

```
cncal/
├─ moon.mod  LICENSE  README.md  THIRD_PARTY_NOTICES.md  .gitignore  .gitattributes
├─ docs/superpowers/specs/2026-10-01-cncal-design.md        本文档
├─ docs/superpowers/plans/2026-10-01-cncal-implementation.md 实现计划
├─ docs/data-verification.md                              节假日数据对照国务院通知原文的核对记录
├─ internal/jsonx/  jsonx.mbt  jsonx_test.mbt             模块内部的 JSON 读取工具
├─ date/       date.mbt  error.mbt  *_test.mbt  date_cases_test.mbt(生成)
├─ lunar/      tables_gen.mbt(生成)  lunar.mbt  solar_term.mbt  *_test.mbt  *_expected_test.mbt(生成)
├─ holiday/    data_gen.mbt(生成)  loader.mbt  holiday.mbt  *_test.mbt  *_expected_test.mbt(生成)
├─ workday/    workday.mbt  *_test.mbt  workday_cases_test.mbt(生成)
├─ cncal.mbt   根包:re-export 常用类型与函数 + README 示例对应的测试
├─ data/       holidays.json                            节假日唯一数据源
├─ testdata/   *.json                                   gen_expected.py 的输出(已提交)
└─ scripts/    gen_tables.py  import_holidays.py  gen_expected.py  embed_data.py  run_all_backends.py  requirements.txt
```

- 文件名带 `_gen` 或 `_test`(生成)的文件头部都有 `DO NOT EDIT`,并注明生成命令。
- 生成物提交进仓库:别人没有 Python、Node 也能直接 `moon test`。
- 仓库统一 LF 换行(`.gitattributes`),避免嵌入的文本在不同系统上字节不同。

## 5. 各包设计

> 下面的签名是**草案**,用于确定接口形状。实现时以 `moon check` 通过为准,命名可能微调,但语义不变。

### 5.1 `date`:日期类型

```moonbit
pub struct Date { year : Int; month : Int; day : Int }   // 外部只能经下列函数构造,所以任何 Date 值都合法
pub(all) enum Weekday { Monday; Tuesday; Wednesday; Thursday; Friday; Saturday; Sunday }

pub fn Date::new(year : Int, month : Int, day : Int) -> Date raise CalendarError
pub fn Date::from_iso(s : String) -> Date raise CalendarError       // "YYYY-MM-DD"
pub fn Date::from_days(n : Int) -> Date raise CalendarError         // n = 距 1970-01-01 的天数
pub fn Date::to_days(self : Date) -> Int
pub fn Date::weekday(self : Date) -> Weekday
pub fn Date::add_days(self : Date, n : Int) -> Date raise CalendarError
pub fn Date::days_between(a : Date, b : Date) -> Int                // b - a
pub fn is_leap_year(year : Int) -> Bool
pub fn days_in_month(year : Int, month : Int) -> Int raise CalendarError
// 另有 Eq、Compare、Show(输出 "YYYY-MM-DD")
```

- **范围:** 公历 1–9999 年(预推公历)。年月日不合法 → `InvalidDate`;`add_days` / `from_days` 结果超出范围 → `OutOfRange`。
- **核心逻辑(答辩要点):**
  1. `Date` 的内部表示是年月日,但所有运算都通过「距 1970-01-01 的天数」完成。
  2. 日期 → 天数用 Howard Hinnant 的 `days_from_civil` 算法,以 400 年为一个纪元(146097 天),把闰年规则折算成纯整数运算;天数 → 日期是它的逆运算。
  3. 星期由天数直接得出(1970-01-01 是星期四),用向下取整的取模,所以负的天数也正确。
  4. 整个包只用 `Int`,没有浮点,所以三个后端的结果一致。
  5. 构造函数是唯一入口,所以持有 `Date` 值就等于合法性已经被检查过。已验证:在包外直接写 `{ year: 2023, month: 2, day: 31 }` 会得到编译错误(4036,只读类型,不可构造)。
- **测试预期值来源:** Python 标准库 `datetime`(它的范围恰好也是 1–9999 年),见 §7.1。

### 5.2 `lunar`:农历与二十四节气

```moonbit
pub struct LunarDate { year : Int; month : Int; is_leap : Bool; day : Int }
pub fn LunarDate::new(year : Int, month : Int, is_leap : Bool, day : Int) -> LunarDate raise CalendarError
pub fn solar_to_lunar(d : Date) -> LunarDate raise CalendarError
pub fn lunar_to_solar(l : LunarDate) -> Date raise CalendarError
pub fn leap_month(year : Int) -> Int raise CalendarError                   // 0 表示该年无闰月
pub fn month_days(year : Int, month : Int, is_leap : Bool) -> Int raise CalendarError

pub(all) enum SolarTerm { XiaoHan; DaHan; LiChun; YuShui; JingZhe; ChunFen; QingMing; GuYu; LiXia; XiaoMan; MangZhong; XiaZhi
                     XiaoShu; DaShu; LiQiu; ChuShu; BaiLu; QiuFen; HanLu; ShuangJiang; LiDong; XiaoXue; DaXue; DongZhi }
pub struct SolarTermDate { term : SolarTerm; date : Date }
pub fn solar_terms(year : Int) -> Array[SolarTermDate] raise CalendarError  // 24 个,按日期升序,从小寒到冬至
pub fn SolarTerm::name(self : SolarTerm) -> String                          // "小寒" … "冬至"
```

#### 5.2.1 表的编码

**农历年表** `lunar_info`:201 个 `Int`,下标为 `年份 − 1900`。每个 `Int` 的位域:

| 位 | 含义 |
|---|---|
| 0–3 | 闰月月份(0 表示无闰月) |
| 4–16 | 13 个「月槽位」,按月份出现的顺序;某位为 1 表示该月 30 天,为 0 表示 29 天。闰月紧跟在同数字的正常月之后。无闰月的年份只用前 12 位。 |
| 17–21 | 正月初一相对当年 1 月 21 日的偏移天数(生成器断言落在 0–31) |

**节气表** `solar_term_days`:`201 × 24 = 4824` 个 `Int`,下标为 `(年份 − 1900) × 24 + k`,值为「几号」(实测都在 3–24 之间)。第 k 个节气所在的公历月固定为 `k / 2 + 1`(k=0 小寒在 1 月,k=23 冬至在 12 月),所以只需要存日,不需要存月。

#### 5.2.2 公历 → 农历

1. 日期不在 `[1900-01-31, 2101-01-28]` → `OutOfRange`。
2. 确定农历年:正月初一一定落在 1 月 21 日~2 月 20 日,所以农历年只可能是公历年本身,或公历年 −1。若 `date < 当年正月初一` 则取前一年。2101 年没有表,2101-01-01 ~ 01-28 一律归入农历 2100 年。
3. 用日期的天数减去该农历年正月初一的天数,再依次扣除各月槽位的天数,得到月槽位和月内的日。
4. 槽位 → (月, 是否闰月):设该年闰月为 L(0 表示无)。槽位 `s` 对应的月份是 `s + 1`(当 `L == 0` 或 `s < L`),对应闰 L 月(当 `s == L`),对应 `s`(当 `s > L`)。

#### 5.2.3 农历 → 公历

1. 校验:农历年在 1900–2100;`is_leap` 为真时该年闰月必须恰好等于 `month`;`1 ≤ day ≤ 该月天数`。年份越界 → `OutOfRange`,其余不合法 → `InvalidDate`。
2. 槽位 `s`:当 `L == 0`、或 `month < L`、或 `month == L && !is_leap` 时为 `month − 1`;否则为 `month`。
3. 结果的天数 = 正月初一的天数 + 槽位 0..s−1 的天数之和 + `day − 1`,再转回 `Date`。

#### 5.2.4 节气

`solar_terms(year)`:取表中该年的 24 个「日」,配上固定的公历月,构造 24 个 `Date`。年份不在 1900–2100 → `OutOfRange`。节气按公历年查询,所以**不受农历域边界(D2)限制**。

#### 5.2.5 自洽性不变量(不依赖任何外部数据,作为测试)

- `正月初一(y+1) − 正月初一(y) = 第 y 年各月槽位天数之和`(y = 1900..2099)。
- 每个月 29 或 30 天;全年 353–355 天(无闰月)或 383–385 天(有闰月)。
- 对农历域内的**每一天**(约 73000 天),`公历 → 农历 → 公历` 恒等;相邻两天的农历日期要么「日 +1」,要么「进位到下个月初一」。
- 每年 24 个节气严格递增,且落在各自规定的公历月。

#### 5.2.6 核心逻辑(答辩要点)

1. 农历的所有信息只有两张表:每年的闰月、各月大小、正月初一的公历日期;节气表只存每个节气的「几号」。
2. 表不是手写的,而是 `scripts/gen_tables.py` 从 lunar-python 生成,所以可以复现、可以逐位核对。
3. 公历转农历,先用「正月初一一定在 1 月 21 日~2 月 20 日」把农历年缩小到两个候选,再用天数差逐月扣除;农历转公历是同一计算的逆过程。
4. 闰月在「月槽位」里紧跟同数字的正常月,所以月份与槽位的换算只需要一个分支。
5. 库内没有浮点运算,三个后端不可能因为数学函数的实现差异而出现不同结果。

### 5.3 `holiday`:法定节假日与调休

#### 5.3.1 数据格式(`data/holidays.json`,`schema_version = 1`)

```json
{
  "schema_version": 1,
  "data_version": "2026.10.01",
  "coverage": { "from": "2004-01-01", "through": "2026-12-31" },
  "sources": [
    { "year": 2026, "url": "https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm" }
  ],
  "holidays": [
    { "name": "元旦",   "from": "2026-01-01", "to": "2026-01-03" },
    { "name": "国庆节", "from": "2026-10-01", "to": "2026-10-07" }
  ],
  "workdays": [
    { "name": "元旦",   "date": "2026-01-04" },
    { "name": "国庆节", "date": "2026-09-20" }
  ]
}
```

- `holidays` 是**放假日**的区间:包含法定节日、因调休而连休的工作日,也包含落在这些区间内的周六周日。普通周末不在其中。
- `workdays` 是**调休补班日**。补班日必然是周六或周日。
- `sources` 是出处链接,每个覆盖年份至少一条,**只用于审计,不参与计算**。
- 节日名称沿用 chinese-days 的中文名(如「元旦」「春节」「清明」「劳动节」「端午」「国庆节」「中秋」),这样逐日比对时可以直接比较字符串。
- 两个列表按日期升序排列。

#### 5.3.2 覆盖范围与加载校验

- `coverage.from` ~ `coverage.through`(含两端)之内的每一天,数据才是完整的;范围外的日期一律 `DataNotCovered`,错误里带上请求日期与已覆盖的起止日期。**绝不把未覆盖的日期当成普通周末。**
- 首次使用时才解析并校验嵌入的 JSON,结果缓存。校验不通过返回 `DataCorrupt`(带原因),不会 abort:
  - `schema_version` 等于 1;日期格式合法;`from ≤ through`。
  - 每个放假区间 `from ≤ to`,区间按顺序排列、互不重叠,且全部落在覆盖范围内。
  - 每个补班日落在覆盖范围内、是周六或周日、不在任何放假区间内、没有重复。
  - 名称非空。
- 这些不变量已在 chinese-days 2004–2026 的全部数据上验证成立(附录 A),所以校验不会误伤合法数据,同时能立刻拦住手工录入时的日期笔误。

#### 5.3.3 接口

```moonbit
pub(all) enum DayKind {
  Workday                  // 普通工作日:周一至周五,且不在放假区间内
  Weekend                  // 普通周末:周六日,不在放假区间内,也不是补班日
  Holiday(String)          // 放假日,附节日名
  MakeupWorkday(String)    // 调休补班日,附相关节日名
}
pub fn day_kind(d : Date) -> DayKind raise CalendarError
pub fn is_holiday(d : Date) -> Bool raise CalendarError            // 是否放假日(见下方「命名说明」)
pub fn is_makeup_workday(d : Date) -> Bool raise CalendarError
pub fn holiday_name(d : Date) -> String? raise CalendarError       // Holiday 与 MakeupWorkday 都返回节日名,其余为 None
pub struct DataInfo { schema_version : Int; data_version : String; from : Date; through : Date }
pub fn data_info() -> DataInfo raise CalendarError
```

**命名说明:** `is_holiday` 为真,当且仅当该日在 `holidays` 的放假区间内(含区间内的周末)。**普通周末返回 `false`**,它的类型是 `Weekend`。这与 chinese-days 的 API `isHoliday` 不同(后者等于「不是工作日」,普通周末也算);与它的数据字段 `holidays` 一致。

#### 5.3.4 每年更新数据的流程(只改数据,不改代码)

1. 在 `data/holidays.json` 的 `holidays`、`workdays` 末尾追加新一年的条目,在 `sources` 里加上通知链接。
2. 把 `coverage.through` 改为新一年的 12 月 31 日,更新 `data_version`。
3. 如果新通知涉及上一年年末的日期(例如元旦前一天补班),这些日期同样写进对应的列表。
4. 运行 `python scripts/embed_data.py` 重新生成嵌入文件,再运行 `moon test`。数据校验和逐日差分测试会立即报告问题。

#### 5.3.5 核心逻辑(答辩要点)

1. 数据与逻辑分离:唯一的数据源是一个 JSON 文件,放假通知里的区间原样记录,每年更新只追加数据。
2. 构建时用 `moon tool embed` 把 JSON 变成字符串常量,所以 js、wasm-gc、native 读到的是同一份字节,不依赖任何文件系统。
3. 加载时把区间展开成「日期 → (类型, 节日名)」的映射,并做一遍不变量校验。
4. 查询时先检查日期是否在覆盖范围内,不在就报错,而不是默认当作周末。
5. 覆盖范围用日期区间表达,而不是年份列表,是因为次年通知常常会修改上一年最后几天的安排(见 §9 风险 2)。

### 5.4 `workday`:工作日计算

```moonbit
pub fn is_workday(d : Date) -> Bool raise CalendarError
pub fn add_workdays(d : Date, n : Int) -> Date raise CalendarError
pub fn workdays_between(a : Date, b : Date) -> Int raise CalendarError
```

#### 5.4.1 正式定义(用户已确认)

记 `W(x)` 为「x 是工作日」:`day_kind(x)` 是 `Workday` 或 `MakeupWorkday`,即 **(周一到周五且非节假日) 或 调休补班日**。

| 函数 | 定义 |
|---|---|
| `add_workdays(d, 0)` | 返回 `d` 本身,即使 `d` 不是工作日。 |
| `add_workdays(d, n)`,`n > 0` | `d` 之后的第 `n` 个工作日。**起算日 `d` 不计入**,不论它是不是工作日。 |
| `add_workdays(d, n)`,`n < 0` | `d` 之前的第 `\|n\|` 个工作日,对称处理,`d` 不计入。 |
| `workdays_between(a, b)`,`a ≤ b` | 区间 `[a, b)` 内的工作日个数:**含 a、不含 b**。 |
| `workdays_between(a, b)`,`a > b` | `-workdays_between(b, a)`,即反对称。 |
| 未涵盖的日期 | 所有传入的日期,以及计算中经过的每一天,都必须在覆盖范围内,否则整个调用返回 `DataNotCovered`。即使 `n = 0` 或 `a = b`,传入的日期也要先检查覆盖范围。 |

#### 5.4.2 由定义推出的性质(作为属性测试)

- **P1** `add_workdays(d, 0) = d`。
- **P2** `n ≠ 0` 时,`add_workdays(d, n)` 一定是工作日。
- **P3** `add_workdays(d, n)` 随 `n` 严格递增。
- **P4** `workdays_between(a, b) = -workdays_between(b, a)`,`workdays_between(a, a) = 0`。
- **P5** 可加性:`workdays_between(a, c) = workdays_between(a, b) + workdays_between(b, c)`(任意 a、b、c)。
- **P6** 逆运算关系:
  - 若 `d` 是工作日,则对所有 `n`,`workdays_between(d, add_workdays(d, n)) = n`。
  - 若 `d` 不是工作日,则 `n < 0` 时仍然成立;`n > 0` 时结果恰好少 1,即等于 `n − 1`。
  - 实测(起算日取 2026-01-05 ~ 2026-11-30 的每一天,数据取自 chinese-days):从工作日起算,n ∈ {−7, −1, 1, 3, 7, 11},违例 0 次;从非工作日起算,n ∈ {1, 3},违例 212 次,符合上述「少 1」的预期。这一限制会写进 README,不会宣称它无条件成立。

#### 5.4.3 示例(用 chinese-days 的 2026 年数据算出)

| 表达式 | 结果 | 说明 |
|---|---|---|
| `add_workdays(2026-09-30 周三, 1)` | 2026-10-08 周四 | 跨过 10 月 1–7 日的国庆假期 |
| `add_workdays(2026-10-09 周五, 1)` | 2026-10-10 周六 | 10-10 是补班日,算工作日 |
| `add_workdays(2026-10-10 周六补班, 1)` | 2026-10-12 周一 | 10-11 是普通周日 |
| `add_workdays(2026-10-03 周六假日, 0)` | 2026-10-03 | n=0 原样返回 |
| `add_workdays(2026-10-03, 1)` / `(…, -1)` | 2026-10-08 / 2026-09-30 | 起算日是假日也可以 |
| `add_workdays(2026-10-08 周四, -2)` | 2026-09-29 周二 | 向前跨过长假 |
| `workdays_between(2026-09-30, 2026-10-12)` | 4 | 9/30、10/8、10/9、10/10 |
| `workdays_between(2026-10-12, 2026-09-30)` | −4 | 反对称 |

#### 5.4.4 与 chinese-days 的 `findWorkday` 的差异

chinese-days 的 `findWorkday(n, date)` 与本设计只有一处不同:

- `n ≠ 0`:完全相同(起算日不计入,第 n 个工作日)。
- `n = 0` 且起算日是工作日:相同,返回起算日。
- **`n = 0` 且起算日不是工作日:chinese-days 顺延到下一个工作日(当作 n = 1);本设计原样返回起算日。**

本设计选择「原样返回」,是为了保持 `add_workdays(d, 0) = d` 恒成立(P1),并与 Excel `WORKDAY` 一致。需要「顺延」语义的调用方可以自行判断 `is_workday(d)`。如果以后需要,再增加 `roll_forward` / `roll_backward` 两个函数,MVP 不包含。差分测试对 `n ≠ 0` 与「n=0 且为工作日」使用 chinese-days 作为预期值,对「n=0 且非工作日」使用本节的定义。

#### 5.4.5 实现与复杂度

- `add_workdays`:逐日前进(或后退),遇到工作日才把剩余步数减一。循环用「剩余步数趋向 0」的写法,避免对 `Int.min_value` 取负。
- `workdays_between`:逐日扫描 `[a, b)`,统计工作日。
- 覆盖范围是有限的(目前约 8400 天),逐日扫描最坏约 8400 步,每步是一次映射查询,足够快,而且和定义逐字对应,最容易检查正确性。**不做周跳跃之类的优化(YAGNI)。**

#### 5.4.6 核心逻辑(答辩要点)

1. 「是否工作日」只有一个判据:调休补班日,或者周一到周五且不在放假区间内;它完全由 `holiday` 提供的 `DayKind` 决定。
2. `add_workdays` 从起算日的下一天(或前一天)开始逐日扫描,每遇到一个工作日就消耗一步,起算日本身从不计数,所以不会出现「起算日是否算一天」的歧义。
3. `workdays_between` 是半开区间 `[a, b)`,并对反向区间取相反数,这样它自然满足反对称与可加性。
4. 扫描到未覆盖的日期时立即报错,所以「跨到没有数据的年份」绝不会静默得到一个错误答案。
5. 这套语义与 Excel、numpy 的约定一致,并通过属性测试(P1–P6)验证。

### 5.5 根包 `cncal`

re-export 常用类型与函数,使最小示例只需要导入一个包。如果 `pub using` 式 re-export 在接口文件(`.mbti`)或某个后端上带来问题,则降级为:根包只保留 README 示例对应的测试,用户直接导入各子包。两种情况下 README 的示例都经过测试验证。

## 6. 错误模型

```moonbit
pub(all) suberror CalendarError {
  InvalidDate(String)                 // 不存在的日期,如 2023-02-29、13 月;农历的闰月标记与该年不符
  OutOfRange(String)                  // 超出支持范围:Date 的 1–9999 年、农历域、节气年份
  DataNotCovered(Date, Date, Date)    // 请求的日期、已覆盖的起、已覆盖的止
  DataCorrupt(String)                 // 嵌入的节假日数据未通过校验
} derive(Eq, Debug)
// 另有手写的 Show,输出简体中文消息
```

- **必须是 `pub(all)`:** 普通的 `pub suberror` 在包外是只读类型(编译错误 4036),`lunar`、`holiday` 等兄弟包就无法 `raise @date.OutOfRange(...)`。`pub(all)` 也让测试可以直接构造并比较错误值。
- **调用方处理错误用 `try … catch { … } noraise { … }`。** `try?` 在当前工具链中已弃用,库不提供 `Result` 版本的接口。
- **接口契约是错误的类别**,测试只匹配类别(`InvalidDate` 等),不匹配消息文字;消息使用简体中文。
- 超出农历域、节气年份、节假日覆盖范围的行为是**本设计规定**的(例如 `1900-01-30` 转农历必须是错误),而 lunar-python 在这些点上会给出别的结果(它把 `1900-01-30` 转成农历 1899 年十二月三十)。所以这类用例由设计文档规定,不用 lunar-python 生成。

## 7. 测试策略

**原则:测试的预期值不手写。** 除上一节说明的「错误行为」用例外,所有预期值都由 `scripts/gen_expected.py` 用独立的参考实现生成,存为 JSON(提交进仓库),MoonBit 测试读取这些 JSON 来比对。

### 7.1 预期值的来源(`testdata/`)

| 文件 | 参考实现 | 内容 |
|---|---|---|
| `date_cases.json` | Python 标准库 `datetime` | 随机日期的星期、加减天数后的日期、日差;一批非法日期(2023-02-29、月日越界等) |
| `lunar_samples.json` | lunar-python 的**逐日接口**(`Solar.getLunar()`、`Lunar.getSolar()`) | 在农历域内随机抽取 1000 个公历日期(固定随机种子),给出双向转换结果;外加带标签的边界集合(见 §7.3) |
| `lunar_month_starts.json` | 同上,逐日扫描整个农历域 | 每个农历月的初一对应的公历日期与月长 |
| `solar_terms.json` | lunar-python 的**逐日接口**(`Lunar.getJieQi()`),逐日扫描 1900–2100 | 201 年 × 24 个节气 |
| `holiday_daily.json` | **真实的 chinese-days npm 包**(`isWorkday`、`getDayDetail`),经 Node 调用 | 覆盖范围内每一天的类型与节日名 |
| `workday_cases.json` | chinese-days 的 `findWorkday`、`getWorkdaysInRange`;`n=0` 非工作日及各属性用 Python 暴力参考实现 | `add_workdays` 与 `workdays_between` 的用例 |

- 每个 JSON 的 `meta` 记录:生成器名称、lunar-python 与 chinese-days 的版本、随机种子、数据范围。**不写时间戳**,保证重复运行结果逐字节相同。
- **版本固定**:`lunar_python==1.4.8`,`chinese-days@1.5.9`。
- **两个入口互相校验,但不构成独立验证。** 表生成器 `gen_tables.py` 使用 lunar-python 的 `LunarYear` 接口,期望值生成器使用逐日接口(`Solar.getLunar()`、`Lunar.getJieQi()` 等)。实测二者在 201 年 × 24 个节气上完全一致(0 处差异),这能发现生成器误用接口的错误。但读 `LunarYear.compute` 的源码可知,两个入口共用同一套天文计算,所以它**不能**证明 lunar-python 自身正确。我们的验收基准本来就是 lunar-python,这一点在此如实记录。
- 嵌入方式:用 `moon tool embed` 把 JSON 转成测试专用的 `*_test.mbt` 字符串常量(`scripts/embed_data.py` 统一执行,并提供 `--check` 检查生成物是否过期)。
- **嵌入文件的行数限制:** `moon tool embed` 把 JSON 的每一行变成一行 `#|`,编译器在单个字符串常量达到约 16384 行时给出警告 0033。所以生成器输出的 JSON 都是「一条记录一行」(或「一年一行」),每个文件远少于 16000 行。(实测 24000 行、约 1MB 的嵌入文件三个后端都能编译和运行,只是有警告。)

### 7.2 验收项与测试的对应

| 验收项 | 测试 |
|---|---|
| 1000 个随机日期,农历转换与 lunar-python 一致 | 用 `lunar_samples.json` 同时检查 公历→农历 与 农历→公历 |
| 加强:农历转换在整个域内完全一致 | `lunar_month_starts.json`(每个农历月的初一与月长)+ §5.2.5 的「逐日往返、逐日连续」不变量。两者合起来,等价于对约 73000 天全部与 lunar-python 一致 |
| 节气全部年份一致 | 用 `solar_terms.json` 比对 201 年 × 24 个 |
| 节假日覆盖的所有年份逐日一致 | 用 `holiday_daily.json` 逐日比对类型、节日名与 `is_workday` |
| Date | 用 `date_cases.json` |
| `add_workdays` / `workdays_between` | 用 `workday_cases.json`,外加 §5.4.2 的属性测试 |

当本项目的数据比 chinese-days 新(例如 chinese-days 尚未发布最新一年)时,`holiday_daily.json` 只覆盖它自己的范围,测试遍历该文件声明的范围,同时检查本项目的覆盖范围不小于它。

### 7.3 边界用例清单

| 边界 | 具体用例 |
|---|---|
| 闰月 | 域内**全部闰月**的第一天与最后一天,包括 1900 年闰八月、2023 年闰二月;`LunarDate::new` 对「该年无此闰月」报 `InvalidDate` |
| 农历年跨公历年 | 每年 1 月 1 日(多数仍属上一个农历年);每一年的除夕与正月初一 |
| 除夕 | 201 个除夕(月大月小两种) |
| 节气落在月初月末 | 实测 24 个节气在公历月里只落在 3–24 号,所以公历意义上的月初月末不会出现。本设计取**农历月初一与月末日**这个含义:这正是判定闰月的关键边界,1900–2100 年间共 326 次,全部纳入。另外覆盖每个节气在 201 年中出现的最早与最晚日期 |
| 调休补班的周六周日 | 数据中全部 150 个补班日,都必须是工作日;其中周六、周日各自都有 |
| 跨长假的 `add_workdays` | 对每个连续 ≥ 3 天的休息块(含周末),取其前一个工作日与后一个工作日作为起点,n ∈ {±1, ±2, ±5};包括春节、国庆、以及跨年的元旦 |
| 资料范围外的年份 | `2003-12-31`、`2027-01-01` 报 `DataNotCovered`;从覆盖范围内起算、结果跨出范围的 `add_workdays` / `workdays_between` 同样报错;`1900-01-30`、`2101-01-29` 转农历报 `OutOfRange`;`solar_terms(1899)`、`solar_terms(2101)` 报 `OutOfRange` |

### 7.4 三后端

- 每个步骤结束时,分别运行 `moon test --target js`、`--target wasm-gc`、`--target native`,三者全部通过才进入下一步。`scripts/run_all_backends.py` 顺序运行并汇总结果。
- 同一份测试数据在三个后端上的结果必须相同。因为库内只用 `Int`,没有浮点,所以不应有后端差异;有差异就是 bug。

## 8. 第三方来源与授权

| 项目 | 授权 | 版权人 | 本项目如何使用 |
|---|---|---|---|
| [6tail/lunar-python](https://github.com/6tail/lunar-python) | MIT | 6tail | 农历、节气表由它生成;农历、节气测试的参考实现 |
| [vsme/chinese-days](https://github.com/vsme/chinese-days) | MIT | Yawei sun | 节假日数据的初始来源;节假日与工作日测试的参考实现 |

- 两个项目的授权均已于 2026-10-01 阅读 LICENSE 原文核实。
- 在 `THIRD_PARTY_NOTICES.md` 中收录两份 MIT 授权全文与版权声明,README 的「来源与致谢」一节注明用途与链接。
- 放假安排本身是国务院办公厅通知中的事实性日期。`holidays.json` 的 `sources` 记录每一年通知的原始链接。

## 9. 已知差异、风险与取舍

1. **lunar-python 与流行的农历表在 3 个年份不一致。** chinese-days 使用的是流行的 `0x04bd8` 式农历表,与 lunar-python 在 **1933、1996、2060** 三个年份的月大小不同(朔日落在午夜附近)。验收标准是与 lunar-python 一致,所以本项目以 lunar-python 为准。README 会写明这三年。可选的加分项:用香港天文台公布的数据交叉核对,不属于 MVP 验收。
2. **年末几天的数据可能被次年的通知修改。** 次年的通知常常调整上一年最后几天(例如 2019 年通知规定了 2018-12-29 补班)。2004–2026 的 22 个年末里,有 5 次出现(2006、2007、2011、2018、2022)。所以覆盖范围写成日期区间,README 注明「最新覆盖年份的年末几天,在下一年通知发布后可能变化」。
3. **差分测试验证的是代码,不是数据的真伪。** 节假日数据初始从 chinese-days 导入,拿它自己比对天然一致。所以:差分测试验证的是**加载、展开、校验与判定逻辑**;数据真伪靠 `sources` 里的国务院通知链接,实现阶段我会对照 2024、2025、2026 三年的通知原文抽查。README 也会如实写出这一点。
4. **部分年份的出处不是一手来源。** chinese-days 源码中 2005 年的出处是百度知道、2004 年是维基文库,其余 21 年均为 gov.cn。实现阶段会尝试补充 gov.cn 的一手链接,补不到就在 README 中注明。
5. **与 chinese-days 的命名与语义差异**(已在 §5.3.3 与 §5.4.4 说明):`is_holiday` 不含普通周末;`n = 0` 且非工作日时不顺延。
6. **环境注意事项(已实测):** pip 默认的清华镜像下载 `lunar_python` 会返回 403,需要 `-i https://pypi.org/simple`;运行 Python 脚本需设置 `PYTHONUTF8=1` 避免中文乱码;脚手架会尝试创建 `README.md → README.mbt.md` 的符号链接,Windows 需要管理员权限,所以本项目使用普通的 `README.md`。
7. **MoonBit 语言细节(均已在临时探针里用 js、wasm-gc、native 三个后端验证,不凭记忆):**
   - `pub(all) suberror CalendarError { … } derive(Eq, Debug)`。普通 `pub suberror` 的构造器在包外只读(4036),兄弟包无法 `raise`。
   - 测试里断言错误用 `try f() catch { @date.InvalidDate(_) => () … } noraise { _ => fail("…") }`;`try?` 已弃用。
   - `pub struct` 的字段对外可读,但包外无法构造(4036),所以「持有 Date 即合法」成立。没有不变量的枚举(`Weekday`、`DayKind`、`SolarTerm`)用 `pub(all)`。
   - `Eq`、`Compare`、`Debug` 用 `derive`;`derive(Show)` 已弃用,所以 `Show` 手写:`pub impl Show for T with fn output(self, logger) { … }`。`assert_eq` 要求 `Eq + Debug`,`inspect` 要求 `Show`。
   - 每个 `derive` 与自定义 `Show` 会触发弃用警告 `implicit_impl_as_method`,在各包的 `moon.pkg` 里用 `warnings = "-implicit_impl_as_method"` 关闭。
   - re-export 的写法是 `.mbt` 源文件里的 `pub using @date {type Date, type CalendarError}`,不是 `moon.pkg` 里的配置。
   - 惰性缓存用 core 自带的 `@lazy.Lazy`:`Lazy(() => …)` 与 `.force()`。`force` 不会抛错,所以缓存的是 `Result[T, CalendarError]`,在调用处再 `raise`。
   - 4824 个元素的 `FixedArray[Int]` 字面量,以及约 1MB、24000 行的嵌入 JSON,三个后端都能编译运行,耗时 0–2 秒。
   - `s[i]` 取到的是 `Char`;空 Map 写 `Map([])`(`{}` 有歧义警告,`Map::new` 已弃用)。
   - `moon test --target all` 实际运行 wasm、wasm-gc、js、native 四个后端(不含 llvm)。`moon test` 有失败时退出码为 2,全部通过为 0。
   - `moon tool embed` 在 Windows 上输出 LF;只有 `moon.mod` 与空 `moon.pkg` 的空根包可以通过 `moon check` 与 `moon test`。
   - `moon fmt` 会重排 `moon.mod`,不会改动格式已经规范的生成文件。
   - 本地路径依赖(已验证):新版 `moon.mod` 不再支持在 `import` 里写本地路径;改用工作区文件 `moon.work`(`members = ["app", "cncal"]`),使用者模块的 `moon.mod` 里写 `"sayoi7799/cncal@0.1.0"`(版本号被忽略,从本地解析)。用并排克隆的两个模块实测,js、wasm-gc、native 都通过。
8. **节气的独立对照:chinese-days 的公式法不可作为参考。** chinese-days 用「寿星通用公式」计算节气,是和 lunar-python 完全不同的算法。逐一比对 1900–2100 年的 24 个节气,共 124 处 (年, 节气) 不一致:其中 100 处是「立秋」在 1900–1999 年**每一年都晚了整整 20 天**(它的常数表里 `the_beginning_of_autumn` 的 20 世纪常数是 28.35,而 21 世纪是 7.5),其余 24 处是公式近似造成的相差 1 天(冬至 7 次,大寒、立春、雨水各 3 次等)。所以节气仍以 lunar-python 为准(这也是验收标准),chinese-days 的公式法不用于测试。这是 chinese-days 的上游缺陷,与本项目无关,在此记录。

## 10. 实施步骤与提交粒度

每一步都遵循:**先生成预期数据并写测试,看到失败,再写实现**;结束时 `moon check` 与三个后端的 `moon test` 全部通过,才提交并进入下一步。每个提交对应一个实质性的完成步骤,不做空提交。

| 步骤 | 内容 | 完成后向用户讲解 |
|---|---|---|
| S0 | 本设计文档(**当前步骤**) | — |
| S1 | 项目骨架:`moon.mod`、MIT `LICENSE`、`.gitignore`、`.gitattributes`、`THIRD_PARTY_NOTICES.md`;清理脚手架里不需要的文件 | — |
| S2 | `date` 包 + `CalendarError` + `gen_expected.py` 的 Date 部分 + 测试 | `date` 的核心逻辑 |
| S3 | `gen_tables.py`(生成农历表与节气表)+ `gen_expected.py` 的农历、节气部分 + `embed_data.py` | — |
| S4 | `lunar`:公历 ↔ 农历 + 测试 | `lunar` 转换的核心逻辑 |
| S5 | `lunar`:二十四节气 + 测试 | 节气的核心逻辑 |
| S6 | `import_holidays.py` 生成 `data/holidays.json` + 校验;对照 2024–2026 的国务院通知原文抽查 | — |
| S7 | `holiday` 包(加载、校验、查询)+ 逐日差分测试 | `holiday` 的核心逻辑 |
| S8 | `workday` 包 + 属性测试 + 差分测试 | `workday` 的核心逻辑 |
| S9 | `run_all_backends.py`、README(安装、最小示例、「工作日语义定义」、来源与致谢)、最终三后端全量验证 | 整体回顾 |

- S9 结束时,会**先询问**用户是否发布到 mooncakes(`moon publish` 对外可见,需要用户明确同意)。未发布时,README 的「安装方式」只写从源码使用的方式,不写 `moon add`。
- 提交信息使用简体中文,清楚描述这一步做了什么。

## 附录 A:调查事实(2026-10-01 实测)

**lunar-python 1.4.8**

- `1900-01-30` → 农历 1899 年十二月三十;`1900-01-31` → 农历 1900 年正月初一。
- `2101-01-28` → 农历 2100 年十二月二十九;`2101-01-29` → 农历 2101 年正月初一。`2100-12-31` → 农历 2100 年十二月初一。
- 1900 年闰八月;2023 年闰二月初一对应公历 `2023-03-22`。
- 1900–2100 每年恰好 24 个节气;每个节气总落在固定的公历月份;「几号」的范围是 3–24。
- 节气恰好落在农历月初一或月末日的次数:326(1900-01-31 ~ 2100-12-31)。
- 提取全部 201 个农历年的闰月、各月天数、正月初一约 0.5 秒;逐日扫描节气约 42 秒。
- `LunarYear.getJieQiJulianDays()`(取下标 2 到 25,即小寒到冬至)与逐日接口 `Lunar.getJieQi()` 在 201 年 × 24 个节气上完全一致,0 处差异;二者共用天文计算核心。

**chinese-days 1.5.9**

- 数据覆盖 2004-01-01 ~ 2026-12-31(23 个年份块,每块都有出处链接)。
- `holidays` 619 天,其中周一到周五 407 天、周六日 212 天;`workdays` 150 天,**全部是周六或周日**;`holidays` 与 `workdays` 不相交;`inLieuDays`(151 天)是 `holidays` 的子集。
- `isHoliday` 的实现是「不是工作日」,所以普通周末也返回真。
- `findWorkday(0, d)`:`d` 是工作日则返回 `d`;否则当作 `n = 1`。
- 它自带的农历表(`LUNAR_INFO`)与 lunar-python 在 1933、1996、2060 三年的月大小不同。
- 它的节气公式法与 lunar-python 在 124 个 (年, 节气) 上不同:100 处是「立秋」在 1900–1999 年全部晚 20 天,24 处是相差 1 天(见 §9 风险 8)。

**官方通知核对**

- 「国务院办公厅关于2026年部分节假日安排的通知」,发文字号「国办发明电〔2025〕7号」,2025-11-04 发布;其中的放假与补班安排与 chinese-days 的 2026 年数据一致。

**工具链**

- moon 0.1.20260920、moonc v0.10.14;新版配置文件是 `moon.mod`、`moon.pkg`(DSL),不再是 JSON。
- `moon test` 在 js、wasm-gc、native 三个后端上对带真实断言的探针均为 3/3 通过。
- `moon test --target` 的可选值:`wasm`、`wasm-gc`、`js`、`native`、`llvm`、`all`。

## 11. 实现与设计的差异

实现过程中有以下几处与本文档的原文不同。它们都是工具链或实测带来的调整,没有改变任何已确认的语义。

| 项 | 设计文档里的写法 | 实际做法 | 原因 |
|---|---|---|---|
| 生成的农历表是否被 `moon fmt` 重排 | 未提及 | `lunar/moon.pkg` 里写 `formatter(ignore: [ "tables_gen.mbt" ])` | `moon fmt` 会把整型数组按列宽重新折行,破坏「一年一行」的可读布局;让它跳过生成物最稳 |
| 布尔取反 | `not(x)` | `!x` | `not()` 在当前工具链中已弃用(警告 0020) |
| 区间的写法 | `a..=b` | `a..<=b` | `moon fmt` 自动迁移,`..=` 是旧写法 |
| 测试辅助函数 | 带 `T : Show` 约束并打印意外得到的值 | 去掉约束,只报告「没有出错」 | 对 `Array` 使用 `Show` 已弃用;打印值的价值不大 |
| 根包重导出的枚举 | 只写 `pub using @date {type Weekday}` | 同上,但使用时变体要用类型名限定,如 `@cncal.Weekday::Wednesday`、`@cncal.CalendarError::DataNotCovered(_, _, _)` | 重导出的是类型别名,变体不会作为独立的名字被导出 |
| 2004、2005 年的出处 | 沿用 chinese-days 的链接 | 2004 年换成陕西省人民政府网站转发的全文;2005 年换成法律数据库的转载(没有找到政府网站上的版本) | 原链接是维基文库和百度知道,不是一手来源 |
| 节假日数据核对 | 只核对 2024–2026 | 另外核对了 2004、2005 | 这两年的出处最弱,顺带核对;结果见 `docs/data-verification.md` |
| 边界用例数量 | 「约千条」 | 1079 条(闰月首尾各 74 个、除夕与正月初一各 201 个、元旦 201 个、节气落在农历月初月末 326 次、域首尾各 1 个) | 实测值 |
