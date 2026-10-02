# cncal — 中国日历与工作日引擎

用 [MoonBit](https://www.moonbitlang.com) 编写的中国日历库:公历农历互转、二十四节气、法定节假日与调休、工作日计算。

**同一份代码可以编译到 js、wasm-gc、native,三个后端的结果完全相同。** 库内只用整数运算,没有浮点,所以不会因为各后端数学函数的实现差异而出现不同结果。

## 为什么需要它

1. 每年国务院公布调休安排,各系统手工维护表格,常把补班日当成周末。
2. 「N 个工作日后」的计算(审批时限、物流、T+N 结算)各家手写、各自出错。
3. 前后端计算结果不一致。

## 功能

| 模块 | 功能 | 范围 |
|---|---|---|
| `date` | 轻量日期类型:合法性检查、星期几、日期加减 | 公历 0001–9999 年 |
| `lunar` | 公历 ↔ 农历互转(含闰月)、二十四节气 | 农历:公历 1900-01-31 ~ 2101-01-28;节气:1900–2100 年。范围外返回明确的错误 |
| `holiday` | 是否节假日、是否调休补班日、节日名称 | 2004-01-01 ~ 2026-12-31。**数据未涵盖的日期一律报错,不会当成普通周末** |
| `workday` | `is_workday`、`add_workdays`(支持负数)、`workdays_between` | 同 `holiday` |

所有日期都是**北京时间(UTC+8)的日历日**;不处理时区。

## 安装

本库目前**尚未发布到 mooncakes**,请从源码使用。把本仓库克隆到你的模块旁边,用 `moon.work` 把两个模块放进同一个工作区:

```
my-workspace/
├─ moon.work        members = ["app", "cncal"]
├─ cncal/           git clone 得到的本仓库
└─ app/             你自己的模块
```

`moon.work`:
```
members = [
  "app",
  "cncal",
]
```

`app/moon.mod`(`@` 后面的版本号会被忽略,模块从本地解析):
```
name = "yourname/app"

version = "0.1.0"

import {
  "sayoi7799/cncal@0.1.0",
}
```

`app/moon.pkg`:
```
import {
  "sayoi7799/cncal",
}
```

这套写法已用 `moon test` 在 js、wasm-gc、native 三个后端验证过。

## 最小使用示例

根包 `@cncal` 重新导出了常用的类型和函数,只需要导入这一个包。下面的代码与仓库里的测试 [cncal_test.mbt](cncal_test.mbt) 逐行相同,并且每次 `moon test` 都会运行:

```moonbit
// 日期
let d = @cncal.Date::new(2026, 9, 30)
assert_eq("\{d.add_days(1)}", "2026-10-01")
assert_eq(d.weekday(), @cncal.Weekday::Wednesday)

// 公历 → 农历(2023 年有闰二月)
let lunar = @cncal.solar_to_lunar(@cncal.Date::new(2023, 3, 22))
assert_eq("\{lunar}", "2023-闰02-01")
assert_eq("\{@cncal.lunar_to_solar(lunar)}", "2023-03-22")

// 二十四节气
let term = @cncal.solar_terms(2024)[2]
assert_eq(term.term.name(), "立春")
assert_eq("\{term.date}", "2024-02-04")

// 节假日与调休
let national_day = @cncal.Date::new(2026, 10, 1)
assert_eq(@cncal.is_holiday(national_day), true)
assert_eq(@cncal.holiday_name(national_day), Some("国庆节"))
let makeup = @cncal.Date::new(2026, 10, 10) // 周六,国庆调休补班
assert_eq(@cncal.is_makeup_workday(makeup), true)
assert_eq(@cncal.is_workday(makeup), true)

// 工作日计算:2026-09-30 之后的第 1 个工作日,跨过 7 天国庆长假
assert_eq("\{@cncal.add_workdays(d, 1)}", "2026-10-08")
assert_eq(@cncal.workdays_between(d, @cncal.Date::new(2026, 10, 12)), 4)

// 数据未涵盖的年份必须报错,不会当成普通周末
try @cncal.is_workday(@cncal.Date::new(2099, 1, 1)) catch {
  @cncal.CalendarError::DataNotCovered(_, _, _) => ()
  e => fail("期望 DataNotCovered,实际 \{e}")
} noraise {
  _ => fail("期望 DataNotCovered")
}
```

### 错误处理

所有可能失败的函数都用 MoonBit 的 `raise` 报告错误,错误类型是 `CalendarError`,有四个类别:

| 类别 | 含义 |
|---|---|
| `InvalidDate(String)` | 不存在的日期(如 2023-02-29),或农历的闰月标记与该年不符 |
| `OutOfRange(String)` | 超出支持范围(日期 0001–9999 年、农历域、节气年份) |
| `DataNotCovered(Date, Date, Date)` | 节假日数据没有涵盖该日期;依次是请求的日期、已涵盖范围的起、已涵盖范围的止 |
| `DataCorrupt(String)` | 嵌入的节假日数据未通过校验 |

用 `try … catch { … } noraise { … }` 处理。接口约定的是错误的类别,不是错误消息的文字。

## 工作日语义定义

「工作日」的定义:**(周一到周五且不是节假日)或者(调休补班日)**。

在此基础上,下面三条是本库对 `add_workdays`、`workdays_between` 的明确约定:

| 问题 | 约定 |
|---|---|
| **起算日算不算** | `add_workdays(d, n)`(`n > 0`)返回 `d` 之后的第 `n` 个工作日。**起算日 `d` 不计入**,不论它是不是工作日。`n < 0` 对称,取 `d` 之前的第 `\|n\|` 个。 |
| **`n = 0`** | 原样返回 `d`,即使 `d` 不是工作日。 |
| **`workdays_between(a, b)`** | 数 `[a, b)` 里的工作日:**含 `a`、不含 `b`**。`a > b` 时返回相反数,所以 `workdays_between(a, b) = -workdays_between(b, a)`。 |
| **日期落在数据未涵盖的范围** | 传入的每个日期,以及计算中经过的每一天,都必须在数据的涵盖范围内,否则整个调用返回 `DataNotCovered`。即使 `n = 0` 或 `a == b`,传入的日期也要先检查。 |

### 示例(2026 年国庆:10 月 1–7 日放假,9 月 20 日与 10 月 10 日补班)

| 表达式 | 结果 | 说明 |
|---|---|---|
| `add_workdays(2026-09-30 周三, 1)` | 2026-10-08 周四 | 跨过 7 天长假 |
| `add_workdays(2026-10-09 周五, 1)` | 2026-10-10 周六 | 10-10 是补班日,算工作日 |
| `add_workdays(2026-10-10 周六补班, 1)` | 2026-10-12 周一 | 10-11 是普通周日 |
| `add_workdays(2026-10-03 周六假日, 0)` | 2026-10-03 | `n = 0` 原样返回 |
| `add_workdays(2026-10-03, 1)` / `add_workdays(2026-10-03, -1)` | 2026-10-08 / 2026-09-30 | 起算日是假日也可以 |
| `add_workdays(2026-10-08 周四, -2)` | 2026-09-29 周二 | 向前跨过长假 |
| `workdays_between(2026-09-30, 2026-10-12)` | 4 | 9/30、10/8、10/9、10/10 |
| `workdays_between(2026-10-12, 2026-09-30)` | −4 | 反对称 |

### 由定义推出的性质(都有属性测试)

- `add_workdays(d, 0) = d`;`n ≠ 0` 时结果一定是工作日;结果随 `n` 严格递增。
- `workdays_between` 反对称(`between(a,b) = −between(b,a)`)且可加(`between(a,c) = between(a,b) + between(b,c)`)。
- **逆运算关系**:若 `d` 是工作日,则对所有 `n`,`workdays_between(d, add_workdays(d, n)) = n`。若 `d` 不是工作日,`n < 0` 时仍然成立;`n > 0` 时结果恰好是 `n − 1`(因为起算日不计入、却落在 `[a, b)` 的起点)。**这个关系不是无条件成立的。**

### 与 chinese-days 的两处差异

对照项目 chinese-days 的 `findWorkday` 与本库只有一处语义不同,另有一处命名不同:

1. **`n = 0` 且起算日不是工作日**:chinese-days 会顺延到下一个工作日;本库原样返回起算日,以保持 `add_workdays(d, 0) = d` 恒成立,并与 Excel 的 `WORKDAY` 一致。需要"顺延"的调用方可以先用 `is_workday(d)` 判断。其余情况两者完全一致(在 3281 个用例上逐一核对过)。
2. **`is_holiday` 的含义**:本库的 `is_holiday(d)` 只对"放假区间内的日子"为真,**普通周末为假**;chinese-days 的 `isHoliday` 等于"不是工作日",普通周末也算。本库的口径与它的数据字段 `holidays` 一致。

## 数据与每年更新

节假日数据是一个独立的 JSON 文件 [data/holidays.json](data/holidays.json),包含涵盖范围、每年国务院通知的出处链接、放假区间和调休补班日。构建时用 `moon tool embed` 把它嵌入程序,所以三个后端读到的是同一份字节,不依赖文件系统。

**每年更新只改数据,不改代码:**

1. 在 `data/holidays.json` 的 `holidays`、`workdays` 末尾追加新一年的条目,在 `sources` 里加上通知链接。
2. 把 `coverage.through` 改为新一年的 12 月 31 日,更新 `data_version`。
3. 如果新通知涉及上一年年末的日期(例如元旦前一天补班),这些日期同样写进对应的列表。
4. 运行 `python scripts/embed_data.py` 重新生成嵌入文件,再运行 `moon test`。数据校验会立即报告问题:补班日必须是周六或周日、不能落在放假区间内、区间必须有序且不重叠、日期必须在涵盖范围内。

## 正确性

测试的预期值**不是手写的**,而是由脚本用独立的参考实现生成,存成 JSON,测试读取这些 JSON 来比对。只有两类例外是手写的:设计文档明确规定的错误行为(例如 `1900-01-30` 转农历必须报 `OutOfRange`,而 lunar-python 在这些点上的行为不同),以及上面 README 示例里的期望值:

| 内容 | 参考实现 | 规模 |
|---|---|---|
| `Date` | Python 标准库 `datetime` | 1825 个合法日期、2010 个加减天数、16 个非法日期 |
| 公历 ↔ 农历 | lunar-python | 1000 个随机日期 + 1079 条边界用例(全部闰月的首尾、201 个除夕与正月初一、元旦、节气落在农历月初或月末),双向比对 |
| 农历全量 | lunar-python | 201 年每个农历月的初一与月长;域内约 73000 天逐日往返恒等且逐日连续。合起来等价于整个农历域与 lunar-python 完全一致 |
| 二十四节气 | lunar-python | 1900–2100 共 201 年 × 24 个节气,全部一致 |
| 节假日 | 真实的 chinese-days npm 包 | 2004-01-01 ~ 2026-12-31 共 8401 天,逐日比对类型与节日名 |
| 工作日 | chinese-days 的 `findWorkday` / `getWorkdaysInRange` + 按上述定义写的 Python 暴力参考实现 | 3558 个 `add_workdays` 用例、1908 个 `workdays_between` 用例,外加上面的属性测试 |

另外,每个包都有针对边界和误用的测试:畸形日期字符串、`Int` 的极端值、覆盖范围的边界日、闰月标记误用、损坏的节假日数据。

### 已知限制(请务必阅读)

- **差分测试验证的是代码,不是数据的真伪。** 节假日数据最初从 chinese-days 导入,拿它自己比对天然一致。数据的真伪靠国务院通知原文:2004、2005、2024、2025、2026 五个年份已对照通知逐条核对一致,记录见 [docs/data-verification.md](docs/data-verification.md);**其余年份没有逐年核对**。2005 年没有找到政府网站上的通知全文,核对用的是法律数据库的转载。
- **最新涵盖年份(2026)的年末几天,在 2027 年的通知发布后可能变化。** 次年的通知常常调整上一年最后几天的安排(2004–2026 的 22 个年末里有 5 次)。所以涵盖范围用日期区间表达。
- **农历表以 lunar-python 为准。** 流行的 `0x04bd8` 式农历表(chinese-days 使用)与 lunar-python 在 1933、1996、2060 三个年份的月大小不同(朔日落在午夜附近)。
- **节气不以 chinese-days 为参考。** 它用公式法计算节气,与 lunar-python 有 124 处不一致:其中 100 处是"立秋"在 1900–1999 年每年都晚了 20 天(它的常数表里 20 世纪的立秋常数是 28.35,而 21 世纪是 7.5),其余 24 处是公式近似造成的相差 1 天。
- 不做:黄历宜忌、八字、干支、星座、港澳台节假日、时区、iCal 导出、企业自定义工作日历。

## 开发指南

环境:MoonBit 工具链(开发时使用 moon 0.1.20260920)、Python 3.12+、Node.js。Python 与 Node 只用于生成测试数据和农历表;只想运行测试的话,有 MoonBit 工具链就够了。

```bash
# 运行测试(三个后端)
python scripts/run_all_backends.py
# 或者分别运行
moon test --target js
moon test --target wasm-gc
moon test --target native
```

复现全部生成的数据(Windows 上请设置环境变量 `PYTHONUTF8=1`;Linux/macOS 上虚拟环境的解释器是 `.venv/bin/python`):

```bash
python -m venv .venv
.venv/Scripts/python -m pip install -r scripts/requirements.txt -i https://pypi.org/simple
.venv/Scripts/python scripts/gen_tables.py           # 农历表与节气表 → lunar/tables_gen.mbt(加 --check 只检查是否最新)
.venv/Scripts/python scripts/gen_expected.py all     # 全部测试预期值 → testdata/*.json(约 1 分钟)
python scripts/embed_data.py                         # 把 JSON 嵌入成 MoonBit 字符串常量(加 --check 只检查)
```

脚本固定了参考实现的版本:`lunar_python==1.4.8`、`chinese-days@1.5.9`。生成的输出不含时间戳,重复运行结果逐字节相同。pip 默认的清华镜像下载 `lunar_python` 会返回 403,所以安装命令里指定了官方源。

### 目录结构

```
date/      日期类型与 CalendarError            lunar/     农历与节气(查表)
holiday/   节假日数据的加载、校验与查询        workday/   工作日计算
internal/jsonx/  模块内部的 JSON 读取工具       cncal.mbt  根包:重新导出常用接口
data/      节假日数据(唯一数据源)             testdata/  测试预期值(脚本生成)
scripts/   生成脚本                            docs/      设计文档、实现计划、数据核对记录
```

设计文档:[docs/superpowers/specs/2026-10-01-cncal-design.md](docs/superpowers/specs/2026-10-01-cncal-design.md)。

## 来源与致谢

- [6tail/lunar-python](https://github.com/6tail/lunar-python)(MIT,版权 6tail):农历表与节气表由它生成;农历和节气测试的参考实现。
- [vsme/chinese-days](https://github.com/vsme/chinese-days)(MIT,版权 Yawei sun):节假日数据的初始来源;节假日与工作日测试的参考实现。
- 放假与调休安排来自国务院办公厅每年发布的节假日安排通知,`data/holidays.json` 的 `sources` 记录了每一年的出处。

两个项目的授权原文见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可证

[MIT](LICENSE)
