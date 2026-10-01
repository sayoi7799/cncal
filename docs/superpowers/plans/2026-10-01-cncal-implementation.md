# cncal 实现计划

> **给执行者:** 必须使用 superpowers:subagent-driven-development(推荐)或 superpowers:executing-plans 逐任务执行本计划。步骤使用复选框(`- [ ]`)语法跟踪进度。本项目在主会话内联执行(executing-plans)。

**目标:** 用 MoonBit 实现「中国日历与工作日引擎」MVP:日期类型、公历农历互转、二十四节气、法定节假日与调休、工作日计算,并在 js、wasm-gc、native 三个后端得到完全相同的结果。

**架构:** 五个包 `date` → `lunar` / `holiday` → `workday` → 根包,库内全程只用 `Int`。农历与节气用 lunar-python 生成的查找表;节假日用单个 JSON 数据文件,构建时用 `moon tool embed` 嵌入;测试预期值全部由 `scripts/gen_expected.py` 用独立的参考实现(Python `datetime`、lunar-python、真实的 chinese-days npm 包)生成 JSON,MoonBit 测试读取这些 JSON 比对。

**技术栈:** MoonBit(moon 0.1.20260920,moonc v0.10.14)、Python 3(仅标准库 + `lunar_python==1.4.8`)、Node.js + `chinese-days@1.5.9`(仅用于生成测试预期值)。

**设计文档:** [docs/superpowers/specs/2026-10-01-cncal-design.md](../specs/2026-10-01-cncal-design.md)(执行前后都要读;本计划引用其中的章节号)

## 全局约束

以下每条对所有任务生效,数值逐字取自设计文档。

- 模块名 `sayoi7799/cncal`,许可证 MIT,所有文档与提交信息使用简体中文。
- 每个任务结束前必须:`moon fmt && moon info && moon check` 通过,并且 `moon test --target js`、`--target wasm-gc`、`--target native` 三个后端全部 0 失败;之后才能提交。
- 库代码只用 `Int`,不使用 `Double`(设计文档 D1)。
- `Date` 范围:公历 1–9999 年。农历域:公历 `1900-01-31` ~ `2101-01-28`。节气:1900–2100 年。节假日覆盖范围由 `data/holidays.json` 的 `coverage` 决定(设计文档 D2、D3)。
- 所有日期是北京时间(UTC+8)的日历日(设计文档 D8)。
- 错误类型:`pub(all) suberror CalendarError`,变体 `InvalidDate(String)`、`OutOfRange(String)`、`DataNotCovered(Date, Date, Date)`、`DataCorrupt(String)`;测试里用 `try … catch { … } noraise { … }` 断言错误,不使用已弃用的 `try?`(设计文档 §6)。
- 无不变量的枚举(`Weekday`、`SolarTerm`、`DayKind`)用 `pub(all)`;有不变量的结构(`Date`、`LunarDate`)用 `pub struct`,保证包外无法直接构造(设计文档 §9 风险 7)。
- 每个包的 `moon.pkg` 都写 `warnings = "-implicit_impl_as_method"`。`Show` 手写(`derive(Show)` 已弃用),`Eq`/`Compare`/`Debug` 用 `derive`。
- 测试预期值不手写。唯一例外:设计文档明确规定的「错误行为」用例(如 `1900-01-30` 转农历必须报 `OutOfRange`)。
- 生成的文件(`*_gen.mbt`、`*_test.mbt` 嵌入文件、`testdata/*.json`)头部有 `DO NOT EDIT`;仓库统一 LF 换行。嵌入的 JSON 必须「一条记录一行」,每个文件远少于 16000 行(设计文档 §7.1)。
- 版本固定:`lunar_python==1.4.8`,`chinese-days@1.5.9`。运行 Python 脚本时设置 `PYTHONUTF8=1`;pip 安装使用 `-i https://pypi.org/simple`(默认清华镜像对该包返回 403)。
- 提交信息末尾加一行 `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`。不做空提交,不为凑数拆分提交。

## 审查重点

设计文档对下面五类输入没有逐一规定,但它们最可能让使用者踩坑。每一条都在对应任务里有测试固定住行为。

1. **极端整数**:`Date::add_days(Int 最大/最小值)`、`add_workdays(d, Int 最大/最小值)` 必须返回 `OutOfRange` / `DataNotCovered`,不能回绕成一个看似合法的日期,也不能死循环。(任务 2、任务 8)
2. **覆盖范围的边界日**:覆盖范围首日的前一天、首日、末日、末日的后一天,在每个节假日/工作日接口上的行为;`workdays_between` 的结束日即使不参与计数也必须在覆盖范围内;`add_workdays(未覆盖日, 0)` 也要报错。(任务 7、任务 8)
3. **畸形日期字符串**:`Date::from_iso` 对分隔符不对、位数不对、含空白、含全角数字、含多余后缀的输入必须报 `InvalidDate`,不能崩溃也不能给出错误日期。(任务 2)
4. **农历的闰月误用**:对没有闰月的年份或月份加闰标记、月份 0/13、日期 0 或超过当月天数、年份越界,必须报 `InvalidDate` / `OutOfRange`,不能悄悄换算成另一个合法日期。(任务 4)
5. **损坏的节假日数据**:`schema_version` 不对、区间颠倒或重叠、日期越出覆盖范围、补班日落在工作日或放假区间内、名称为空、日期非法、不是 JSON,加载器必须返回 `DataCorrupt`,不能静默加载。(任务 7)

## 文件结构

```
moon.mod  moon.pkg(根包)  cncal.mbt  cncal_test.mbt        根包:re-export + README 示例测试
LICENSE  README.md  THIRD_PARTY_NOTICES.md  .gitignore  .gitattributes
internal/jsonx/    moon.pkg  jsonx.mbt  jsonx_test.mbt       模块内部 JSON 读取工具(出错抛 DataCorrupt)
date/              moon.pkg  error.mbt  date.mbt  date_test.mbt  date_cases_test.mbt(生成)
lunar/             moon.pkg  tables_gen.mbt(生成)  lunar.mbt  solar_term.mbt
                   lunar_test.mbt  lunar_wbtest.mbt  solar_term_test.mbt
                   lunar_samples_test.mbt  lunar_month_starts_test.mbt  solar_terms_test.mbt(均为生成)
holiday/           moon.pkg  data_gen.mbt(生成)  holiday.mbt  loader.mbt
                   holiday_test.mbt  loader_wbtest.mbt  holiday_daily_test.mbt(生成)
workday/           moon.pkg  workday.mbt  workday_test.mbt  workday_cases_test.mbt(生成)
data/holidays.json                                          节假日唯一数据源
testdata/*.json                                             gen_expected.py 的输出(已提交)
docs/data-verification.md                                   对照国务院通知原文的核对记录
scripts/           requirements.txt  gencommon.py  gen_tables.py  gen_expected.py
                   import_holidays.py  embed_data.py  cd_query.js  run_all_backends.py
```

---

### Task 1:项目骨架

**文件:**
- 创建:`moon.mod`、`moon.pkg`、`LICENSE`、`.gitignore`、`.gitattributes`、`THIRD_PARTY_NOTICES.md`、`README.md`、`scripts/requirements.txt`

**接口:**
- 消费:无
- 产出:可通过 `moon check` / `moon test` 的空模块 `sayoi7799/cncal`;后续任务在其中添加包

- [ ] **步骤 1:创建开发分支**

```bash
cd /d/moonbitsource && git switch -c feat/mvp && git branch --show-current
```
预期输出:`feat/mvp`

- [ ] **步骤 2:写 `moon.mod`**

```
name = "sayoi7799/cncal"

version = "0.1.0"

readme = "README.md"

repository = ""

license = "MIT"

keywords = [ "calendar", "lunar", "holiday", "workday", "china" ]

description = "中国日历与工作日引擎:公历农历互转、二十四节气、法定节假日与调休、工作日计算"

preferred_target = "wasm-gc"
```

- [ ] **步骤 3:创建空的根包配置**

```bash
cd /d/moonbitsource && : > moon.pkg
```

- [ ] **步骤 4:写 `LICENSE`**

```
MIT License

Copyright (c) 2026 sayoi7799

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **步骤 5:写 `.gitignore` 与 `.gitattributes`**

`.gitignore`:
```
_build/
.mooncakes/
.venv/
__pycache__/
*.pyc
scripts/.cache/
node_modules/
*.tgz
```

`.gitattributes`:
```
* text=auto eol=lf
```

- [ ] **步骤 6:用上游原文生成 `THIRD_PARTY_NOTICES.md`**

授权文本不手敲,直接取上游的 LICENSE 原文,保证逐字一致。

```bash
cd /d/moonbitsource && {
  printf '# 第三方来源与授权\n\n本项目的数据与测试使用了下列开源项目。它们的授权声明原文如下。\n\n'
  printf '## lunar-python\n\n- 项目:https://github.com/6tail/lunar-python\n- 用途:农历表、节气表由它生成;农历、节气测试的参考实现\n\n```text\n'
  curl -sSL --fail https://raw.githubusercontent.com/6tail/lunar-python/master/LICENSE
  printf '\n```\n\n## chinese-days\n\n- 项目:https://github.com/vsme/chinese-days\n- 用途:节假日数据的初始来源;节假日与工作日测试的参考实现\n\n```text\n'
  curl -sSL --fail https://raw.githubusercontent.com/vsme/chinese-days/main/LICENSE
  printf '\n```\n'
} > THIRD_PARTY_NOTICES.md
grep -c "Permission is hereby granted" THIRD_PARTY_NOTICES.md
head -12 THIRD_PARTY_NOTICES.md
```
预期:`grep` 输出 `2`;前 12 行可见 lunar-python 的 `Copyright (c) 2020 6tail`。

- [ ] **步骤 7:写临时的 `README.md` 与 `scripts/requirements.txt`**

`README.md`(任务 9 会重写):
```markdown
# cncal

中国日历与工作日引擎(MoonBit):公历农历互转、二十四节气、法定节假日与调休、工作日计算。

开发中。设计文档见 [docs/superpowers/specs/2026-10-01-cncal-design.md](docs/superpowers/specs/2026-10-01-cncal-design.md)。
```

`scripts/requirements.txt`:
```
lunar_python==1.4.8
```

- [ ] **步骤 8:验证空模块可以通过检查与测试**

```bash
cd /d/moonbitsource && moon fmt && moon info && moon check && for t in js wasm-gc native; do echo "== $t"; moon test --target $t 2>&1 | grep -E "Total tests|rror"; done; echo "exit=$?"
```
预期:`moon check` 无错误;三个后端各输出 `Total tests: 0, passed: 0, failed: 0.`(空模块没有测试,退出码为 0)。`moon fmt` 可能会重排 `moon.mod`,这是正常的。

- [ ] **步骤 9:提交**

```bash
cd /d/moonbitsource && git add -A && git status --short && git commit -q -F - <<'EOF'
chore: 建立项目骨架(moon.mod、MIT 许可证、第三方授权声明、LF 换行约定)

- moon.mod:模块名 sayoi7799/cncal,默认目标 wasm-gc
- THIRD_PARTY_NOTICES.md:逐字收录 lunar-python 与 chinese-days 的 MIT 授权原文
- .gitattributes 统一 LF 换行,避免嵌入的文本在不同系统上字节不同
- scripts/requirements.txt 固定 lunar_python==1.4.8

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git log --oneline | head -3
```

---

### Task 2:`date` 包(含 `CalendarError`、`internal/jsonx`、Date 期望数据生成器、嵌入脚本)

**文件:**
- 创建:`date/moon.pkg`、`date/error.mbt`、`date/date.mbt`、`date/date_test.mbt`、`date/date_cases_test.mbt`(生成)
- 创建:`internal/jsonx/moon.pkg`、`internal/jsonx/jsonx.mbt`、`internal/jsonx/jsonx_test.mbt`
- 创建:`scripts/gencommon.py`、`scripts/gen_expected.py`、`scripts/embed_data.py`、`testdata/date_cases.json`

**接口:**
- 消费:无
- 产出(后续任务依赖这些确切的名字与类型):
  - `@date.Date`:`pub struct`,字段 `year`、`month`、`day`(`Int`,包外只读);`derive(Eq, Compare, Debug)`;`Show` 输出 `YYYY-MM-DD`
  - `@date.Weekday`:`pub(all) enum`(`Monday` … `Sunday`);`Weekday::iso_number(self) -> Int`(周一为 1,周日为 7);`Weekday::is_weekend(self) -> Bool`
  - `@date.CalendarError`:`pub(all) suberror`(四个变体见全局约束),手写 `Show`(简体中文)
  - `Date::new(Int, Int, Int) -> Date raise CalendarError`
  - `Date::from_iso(String) -> Date raise CalendarError`
  - `Date::from_days(Int) -> Date raise CalendarError`(距 1970-01-01 的天数)
  - `Date::to_days(Date) -> Int`、`Date::weekday(Date) -> Weekday`
  - `Date::add_days(Date, Int) -> Date raise CalendarError`
  - `Date::days_between(Date, Date) -> Int`(`b - a`)
  - `@date.is_leap_year(Int) -> Bool`、`@date.days_in_month(Int, Int) -> Int raise CalendarError`
  - `@jsonx`:`parse(String) -> Json`、`as_int`、`as_string`、`as_bool`、`as_array`、`as_object`、`field(Json, String) -> Json`(除 `is_null` 外都 `raise @date.CalendarError`,出错时抛 `DataCorrupt`)、`is_null(Json) -> Bool`
  - Python:`gencommon.py`(`ROOT`、`compact`、`write_text`、`read_text`、`write_sectioned_json`);`gen_expected.py`(`GENERATORS` 注册表,键为数据集名);`embed_data.py`(`EMBEDS` 注册表,元素为 `(输入 JSON, 输出 .mbt, 常量名)`)

- [ ] **步骤 1:创建 `date` 包的类型定义**

`date/moon.pkg`:
```
warnings = "-implicit_impl_as_method"
```

`date/error.mbt`:
```moonbit
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
      logger.write_string("节假日数据未涵盖 \{d}(已涵盖 \{from} 至 \{through})")
    DataCorrupt(msg) => logger.write_string("节假日数据损坏: \{msg}")
  }
}
```

`date/date.mbt`(此时只有类型,函数在步骤 7 添加):
```moonbit
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
```

- [ ] **步骤 2:创建 `internal/jsonx` 包并测试**

`internal/jsonx/moon.pkg`:
```
import {
  "sayoi7799/cncal/date",
  "moonbitlang/core/json",
}

import {
  "sayoi7799/cncal/date",
} for "test"
```

`internal/jsonx/jsonx.mbt`:
```moonbit
///|
fn bad(msg : String) -> @date.CalendarError {
  @date.DataCorrupt("JSON 结构错误: \{msg}")
}

///|
pub fn parse(raw : String) -> Json raise @date.CalendarError {
  @json.parse(raw) catch {
    e => raise @date.DataCorrupt("JSON 解析失败: \{e}")
  }
}

///|
pub fn as_int(j : Json) -> Int raise @date.CalendarError {
  match j {
    Number(n, ..) => n.to_int()
    _ => raise bad("期望数字")
  }
}

///|
pub fn as_string(j : Json) -> String raise @date.CalendarError {
  match j {
    String(s) => s
    _ => raise bad("期望字符串")
  }
}

///|
pub fn as_bool(j : Json) -> Bool raise @date.CalendarError {
  match j {
    True => true
    False => false
    _ => raise bad("期望布尔值")
  }
}

///|
pub fn as_array(j : Json) -> Array[Json] raise @date.CalendarError {
  match j {
    Array(a) => a
    _ => raise bad("期望数组")
  }
}

///|
pub fn as_object(j : Json) -> Map[String, Json] raise @date.CalendarError {
  match j {
    Object(m) => m
    _ => raise bad("期望对象")
  }
}

///|
pub fn field(j : Json, key : String) -> Json raise @date.CalendarError {
  match j {
    Object(m) =>
      match m.get(key) {
        Some(v) => v
        None => raise bad("缺少字段 \{key}")
      }
    _ => raise bad("期望对象")
  }
}

///|
pub fn is_null(j : Json) -> Bool {
  match j {
    Null => true
    _ => false
  }
}
```

`internal/jsonx/jsonx_test.mbt`:
```moonbit
///|
test "读取各种类型的字段" {
  let j = @jsonx.parse(
    "{\"a\":[1,2,3],\"b\":\"中文\",\"c\":true,\"d\":null,\"e\":-7,\"f\":{\"g\":1}}",
  )
  assert_eq(@jsonx.as_array(@jsonx.field(j, "a")).length(), 3)
  assert_eq(@jsonx.as_string(@jsonx.field(j, "b")), "中文")
  assert_eq(@jsonx.as_bool(@jsonx.field(j, "c")), true)
  assert_true(@jsonx.is_null(@jsonx.field(j, "d")))
  assert_eq(@jsonx.as_int(@jsonx.field(j, "e")), -7)
  let f = @jsonx.as_object(@jsonx.field(j, "f"))
  assert_eq(@jsonx.as_int(f.get("g").unwrap()), 1)
}

///|
fn expect_corrupt(f : () -> Unit raise @date.CalendarError, what : String) -> Unit raise {
  try f() catch {
    @date.DataCorrupt(_) => ()
    e => fail("\{what}: 期望 DataCorrupt,实际 \{e}")
  } noraise {
    _ => fail("\{what}: 期望 DataCorrupt,但没有出错")
  }
}

///|
test "结构不符或不是 JSON 时抛 DataCorrupt" {
  expect_corrupt(() => ignore(@jsonx.parse("{not json")), "非法 JSON")
  let j = @jsonx.parse("{\"a\":1,\"s\":\"x\"}")
  expect_corrupt(() => ignore(@jsonx.field(j, "缺失")), "缺少字段")
  expect_corrupt(() => ignore(@jsonx.as_string(@jsonx.field(j, "a"))), "数字当字符串")
  expect_corrupt(() => ignore(@jsonx.as_int(@jsonx.field(j, "s"))), "字符串当数字")
  expect_corrupt(() => ignore(@jsonx.as_array(j)), "对象当数组")
  expect_corrupt(() => ignore(@jsonx.as_bool(j)), "对象当布尔值")
  expect_corrupt(() => ignore(@jsonx.field(@jsonx.parse("[1]"), "a")), "数组取字段")
}
```

- [ ] **步骤 3:运行 `jsonx` 的测试**

```bash
cd /d/moonbitsource && moon check 2>&1 | grep -E "^Error|error" ; moon test --target wasm-gc 2>&1 | grep -E "Total tests|rror|FAIL"
```
预期:`Total tests: 2, passed: 2, failed: 0.`。如果编译报错(例如 `Option::unwrap` 或 `ignore` 的用法),按编译器提示改成等价写法,不要改变测试的意图。

- [ ] **步骤 4:写 `scripts/gencommon.py`、`scripts/embed_data.py`、`scripts/gen_expected.py`(只含 date 部分)**

`scripts/gencommon.py`:
```python
"""生成脚本共用的小工具。"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def compact(value):
    """紧凑的 JSON 文本(不转义中文)。"""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def write_text(rel_path, text):
    """以 UTF-8 与 LF 换行写文件(相对仓库根目录)。"""
    path = os.path.join(ROOT, rel_path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def read_text(rel_path):
    """原样读取文本(不转换换行),文件不存在则返回 None。"""
    path = os.path.join(ROOT, rel_path)
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def write_sectioned_json(rel_path, sections):
    """写「列表中的每个元素独占一行」的 JSON(仍然是合法 JSON)。

    sections 是 [(键, 值)];值是列表时每个元素一行,否则整个值写在一行。
    """
    parts = []
    for key, value in sections:
        if isinstance(value, list):
            body = ",\n".join(compact(v) for v in value)
            parts.append('"%s":[\n%s\n]' % (key, body))
        else:
            parts.append('"%s":%s' % (key, compact(value)))
    write_text(rel_path, "{\n" + ",\n".join(parts) + "\n}\n")
```

`scripts/embed_data.py`:
```python
#!/usr/bin/env python3
"""用 `moon tool embed` 把 JSON 嵌入成 MoonBit 字符串常量。

用法:
    python scripts/embed_data.py          重新生成全部嵌入文件
    python scripts/embed_data.py --check  只检查已提交的嵌入文件是否过期(过期则退出码为 1)
"""
import os
import shutil
import subprocess
import sys

from gencommon import ROOT

# (输入 JSON, 输出 .mbt, 常量名)。新增数据集时在这里追加。
EMBEDS = [
    ("testdata/date_cases.json", "date/date_cases_test.mbt", "date_cases_json"),
]


def embed_to(src, dst, name):
    moon = shutil.which("moon")
    if not moon:
        sys.exit("找不到 moon 命令,请先安装 MoonBit 工具链")
    os.makedirs(os.path.dirname(os.path.join(ROOT, dst)), exist_ok=True)
    subprocess.run(
        [moon, "tool", "embed", "--text", "-i", src, "-o", dst, "--name", name],
        cwd=ROOT,
        check=True,
        capture_output=True,
    )


def read_bytes(rel_path):
    path = os.path.join(ROOT, rel_path)
    if not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return f.read()


def main(argv):
    check = "--check" in argv
    stale = []
    for src, dst, name in EMBEDS:
        if check:
            tmp = os.path.join("_build", "embed_check", dst.replace("/", "__"))
            embed_to(src, tmp, name)
            if read_bytes(tmp) != read_bytes(dst):
                stale.append(dst)
        else:
            embed_to(src, dst, name)
            print("已生成", dst)
    if check:
        if stale:
            print("以下嵌入文件已过期,请运行 python scripts/embed_data.py:")
            for dst in stale:
                print("  ", dst)
            return 1
        print("嵌入文件全部是最新的")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

`scripts/gen_expected.py`:
```python
#!/usr/bin/env python3
"""生成测试预期值 testdata/*.json。预期值全部来自独立的参考实现,不手写:

    date     Python 标准库 datetime
    lunar    lunar-python 的逐日接口
    terms    lunar-python 的逐日接口
    holiday  真实的 chinese-days npm 包(经 Node 调用)
    workday  chinese-days 的 findWorkday / getWorkdaysInRange,加 Python 暴力参考实现

用法:
    python scripts/gen_expected.py date
    python scripts/gen_expected.py all

运行 Python 时请设置 PYTHONUTF8=1。输出不含时间戳,重复运行结果逐字节相同。
"""
import calendar
import datetime as dt
import random
import sys

from gencommon import write_sectioned_json

SEED = 20261001
EPOCH = dt.date(1970, 1, 1).toordinal()
MAX_ORDINAL = dt.date.max.toordinal()


def day_number(d):
    return d.toordinal() - EPOCH


def gen_date():
    rng = random.Random(SEED)
    anchors = [
        dt.date(*t)
        for t in [
            (1, 1, 1), (1, 1, 2), (1, 12, 31), (4, 2, 29), (100, 2, 28), (100, 3, 1),
            (400, 2, 29), (1600, 2, 29), (1700, 2, 28), (1700, 3, 1), (1800, 12, 31),
            (1899, 12, 31), (1900, 1, 1), (1900, 2, 28), (1900, 3, 1), (1969, 12, 31),
            (1970, 1, 1), (2000, 2, 29), (2000, 3, 1), (2024, 2, 29), (2026, 10, 1),
            (2100, 2, 28), (2100, 3, 1), (9999, 1, 1), (9999, 12, 31),
        ]
    ]
    randoms = [dt.date.fromordinal(rng.randint(1, MAX_ORDINAL)) for _ in range(1800)]
    pool = anchors + randoms

    valid = [
        {
            "y": d.year, "m": d.month, "d": d.day,
            "days": day_number(d), "wd": d.isoweekday(), "iso": d.isoformat(),
        }
        for d in pool
    ]

    def add_record(d, n):
        try:
            to = dt.date.fromordinal(d.toordinal() + n).isoformat()
        except (ValueError, OverflowError):
            to = None
        return {"from": d.isoformat(), "n": n, "to": to}

    add = []
    # 边界:恰好在 0001-01-01 与 9999-12-31 上下
    for d, n in [
        (dt.date.max, 1), (dt.date.max, 0), (dt.date.max, -1),
        (dt.date.min, -1), (dt.date.min, 0), (dt.date.min, 1),
        (dt.date(1970, 1, 1), -719162), (dt.date(1970, 1, 1), -719163),
        (dt.date(1970, 1, 1), 2932896), (dt.date(1970, 1, 1), 2932897),
    ]:
        add.append(add_record(d, n))
    for _ in range(2000):
        d = pool[rng.randrange(len(pool))]
        n = rng.randint(-400, 400) if rng.random() < 0.5 else rng.randint(-3_700_000, 3_700_000)
        add.append(add_record(d, n))

    invalid = [
        [2023, 2, 29], [1900, 2, 29], [2100, 2, 29], [2023, 4, 31], [2023, 6, 31],
        [2023, 9, 31], [2023, 11, 31], [2023, 1, 32], [2023, 0, 1], [2023, 13, 1],
        [2023, 1, 0], [2023, 1, -1], [0, 1, 1], [-1, 1, 1], [10000, 1, 1], [2023, -5, 10],
    ]
    for y, m, d in invalid:
        try:
            dt.date(y, m, d)
        except (ValueError, OverflowError):
            continue
        raise SystemExit("%s 其实是合法日期,不能放进 invalid 列表" % ((y, m, d),))

    leap = [
        [y, calendar.isleap(y)]
        for y in (1, 4, 100, 400, 1600, 1700, 1800, 1900, 2000, 2023, 2024, 2100, 2400, 9999)
    ]

    meta = {
        "generator": "scripts/gen_expected.py date",
        "reference": "Python 标准库 datetime / calendar",
        "seed": SEED,
        "epoch": "1970-01-01",
        "days_formula": "date.toordinal() - 719163",
    }
    write_sectioned_json(
        "testdata/date_cases.json",
        [("meta", meta), ("valid", valid), ("add", add), ("invalid", invalid), ("leap", leap)],
    )
    print("testdata/date_cases.json:", len(valid), "个合法日期,", len(add), "个加减天数,", len(invalid), "个非法日期")


GENERATORS = {
    "date": gen_date,
}


def main(argv):
    names = argv or ["all"]
    if "all" in names:
        names = list(GENERATORS)
    for name in names:
        if name not in GENERATORS:
            sys.exit("未知的数据集 %r,可选:%s" % (name, ", ".join(GENERATORS)))
        GENERATORS[name]()


if __name__ == "__main__":
    main(sys.argv[1:])
```

- [ ] **步骤 5:生成预期数据并嵌入,检查可重复性**

```bash
cd /d/moonbitsource && export PYTHONUTF8=1
python scripts/gen_expected.py date
sha256sum testdata/date_cases.json > "$TEMP/date_cases.sha"
python scripts/gen_expected.py date && sha256sum -c "$TEMP/date_cases.sha"
python scripts/embed_data.py
wc -l testdata/date_cases.json date/date_cases_test.mbt
head -c 400 date/date_cases_test.mbt
```
预期:
- 第一条输出 `testdata/date_cases.json: 1825 个合法日期, 2010 个加减天数, 16 个非法日期`;
- `sha256sum -c` 输出 `OK`(两次生成逐字节相同);
- 两个文件的行数都远少于 16000;
- `date_cases_test.mbt` 开头是 `// Generated by \`moon tool embed --text\`, do not edit.`,随后是 `let date_cases_json : String =` 与 `#|` 行。

- [ ] **步骤 6:写 `date` 包的测试(此时实现还不存在,会编译失败)**

先把测试用到的包加进 `date/moon.pkg`:
```
warnings = "-implicit_impl_as_method"

import {
  "sayoi7799/cncal/internal/jsonx",
} for "test"
```

`date/date_test.mbt`:
```moonbit
///|
fn expect_invalid(
  f : () -> @date.Date raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.InvalidDate(_) => ()
    e => fail("\{what}: 期望 InvalidDate,实际 \{e}")
  } noraise {
    d => fail("\{what}: 期望 InvalidDate,实际得到 \{d}")
  }
}

///|
fn expect_out_of_range(
  f : () -> @date.Date raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.OutOfRange(_) => ()
    e => fail("\{what}: 期望 OutOfRange,实际 \{e}")
  } noraise {
    d => fail("\{what}: 期望 OutOfRange,实际得到 \{d}")
  }
}

///|
test "合法日期:天数、星期、字符串与 Python datetime 一致" {
  let root = @jsonx.parse(date_cases_json)
  let valid = @jsonx.as_array(@jsonx.field(root, "valid"))
  assert_true(valid.length() >= 1000)
  for rec in valid {
    let y = @jsonx.as_int(@jsonx.field(rec, "y"))
    let m = @jsonx.as_int(@jsonx.field(rec, "m"))
    let d = @jsonx.as_int(@jsonx.field(rec, "d"))
    let days = @jsonx.as_int(@jsonx.field(rec, "days"))
    let wd = @jsonx.as_int(@jsonx.field(rec, "wd"))
    let iso = @jsonx.as_string(@jsonx.field(rec, "iso"))
    let date = @date.Date::new(y, m, d)
    assert_eq(date.to_days(), days, msg="to_days \{iso}")
    assert_eq(date.weekday().iso_number(), wd, msg="weekday \{iso}")
    assert_eq("\{date}", iso)
    assert_eq(@date.Date::from_days(days), date, msg="from_days \{iso}")
    assert_eq(@date.Date::from_iso(iso), date, msg="from_iso \{iso}")
  }
}

///|
test "add_days 与 Python date 运算一致,越界报 OutOfRange" {
  let root = @jsonx.parse(date_cases_json)
  let adds = @jsonx.as_array(@jsonx.field(root, "add"))
  assert_true(adds.length() >= 1000)
  let mut out_of_range = 0
  for rec in adds {
    let from = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "from")))
    let n = @jsonx.as_int(@jsonx.field(rec, "n"))
    let to = @jsonx.field(rec, "to")
    if @jsonx.is_null(to) {
      out_of_range += 1
      expect_out_of_range(() => from.add_days(n), "\{from} + \{n}")
    } else {
      let expected = @date.Date::from_iso(@jsonx.as_string(to))
      assert_eq(from.add_days(n), expected, msg="\{from} + \{n}")
      assert_eq(
        from.days_between(expected),
        n,
        msg="days_between \{from} \{expected}",
      )
    }
  }
  // 数据里确实包含越界的用例,防止生成器悄悄漏掉这一类
  assert_true(out_of_range > 0)
}

///|
test "非法日期报 InvalidDate" {
  let root = @jsonx.parse(date_cases_json)
  let invalid = @jsonx.as_array(@jsonx.field(root, "invalid"))
  assert_true(invalid.length() > 0)
  for rec in invalid {
    let parts = @jsonx.as_array(rec)
    let y = @jsonx.as_int(parts[0])
    let m = @jsonx.as_int(parts[1])
    let d = @jsonx.as_int(parts[2])
    expect_invalid(() => @date.Date::new(y, m, d), "\{y}-\{m}-\{d}")
  }
}

///|
test "闰年判断与 Python calendar 一致" {
  let root = @jsonx.parse(date_cases_json)
  for rec in @jsonx.as_array(@jsonx.field(root, "leap")) {
    let parts = @jsonx.as_array(rec)
    let y = @jsonx.as_int(parts[0])
    assert_eq(@date.is_leap_year(y), @jsonx.as_bool(parts[1]), msg="闰年 \{y}")
  }
}

///|
test "审查重点:畸形日期字符串一律报 InvalidDate" {
  let bad = [
    "", "2026", "2026-1-1", "2026/10/01", " 2026-10-01", "2026-10-01 ", "2026-10-01T00:00",
    "２０２６-10-01", "2026-10-0a", "2026-13-01", "2026-02-30", "abcd-ef-gh", "0000-01-01",
    "10000-01-01", "2026-10--1", "+026-10-01", "2026-１0-01",
  ]
  for s in bad {
    expect_invalid(() => @date.Date::from_iso(s), "from_iso(\"\{s}\")")
  }
  // 严格格式的合法字符串仍然可以解析
  assert_eq("\{@date.Date::from_iso("2026-10-01")}", "2026-10-01")
}

///|
test "审查重点:极端整数不会回绕成合法日期" {
  let max_n = 2147483647
  let min_n = -2147483648
  let mid = @date.Date::new(2026, 1, 1)
  expect_out_of_range(() => mid.add_days(max_n), "2026-01-01 + Int 最大值")
  expect_out_of_range(() => mid.add_days(min_n), "2026-01-01 + Int 最小值")
  let last = @date.Date::new(9999, 12, 31)
  let first = @date.Date::new(1, 1, 1)
  expect_out_of_range(() => last.add_days(max_n), "9999-12-31 + Int 最大值")
  expect_out_of_range(() => first.add_days(min_n), "0001-01-01 + Int 最小值")
  expect_out_of_range(() => last.add_days(1), "9999-12-31 + 1")
  expect_out_of_range(() => first.add_days(-1), "0001-01-01 - 1")
  expect_out_of_range(() => @date.Date::from_days(max_n), "from_days(Int 最大值)")
  expect_out_of_range(() => @date.Date::from_days(min_n), "from_days(Int 最小值)")
  // 边界本身是合法的
  assert_eq("\{last.add_days(0)}", "9999-12-31")
  assert_eq("\{first.add_days(0)}", "0001-01-01")
}
```

- [ ] **步骤 7:运行测试,确认失败**

```bash
cd /d/moonbitsource && moon check 2>&1 | grep -E "Error" | head -5
```
预期:编译错误,指出 `Date::new`、`Date::from_iso` 等方法未定义(例如 `Date::new` is not found)。

- [ ] **步骤 8:实现 `date` 包**

把下面的代码追加到 `date/date.mbt` 末尾:
```moonbit
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
pub fn Date::new(year : Int, month : Int, day : Int) -> Date raise CalendarError {
  if year < 1 || year > 9999 {
    raise InvalidDate("年份必须在 1 到 9999 之间: \{year}")
  }
  let dim = days_in_month(year, month)
  if day < 1 || day > dim {
    raise InvalidDate("\{year} 年 \{month} 月没有 \{day} 日")
  }
  { year, month, day }
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
  { year, month, day }
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
```

- [ ] **步骤 9:运行测试,确认通过**

```bash
cd /d/moonbitsource && moon fmt && moon info && moon check 2>&1 | grep -E "^Error" ; for t in js wasm-gc native; do echo "== $t"; moon test --target $t 2>&1 | grep -E "Total tests|rror|FAIL"; done
```
预期:三个后端都输出 `Total tests: 8, passed: 8, failed: 0.`(`date` 6 个 + `jsonx` 2 个)。

如果失败,先看是哪个断言(`msg=` 里有日期),再判断是实现错了还是预期数据错了;预期数据来自 Python,以它为准。

- [ ] **步骤 10:确认生成文件经过格式化后仍然是最新的**

```bash
cd /d/moonbitsource && python scripts/embed_data.py --check && git status --short
```
预期:输出 `嵌入文件全部是最新的`(说明 `moon fmt` 没有改动嵌入文件);`git status` 里能看到新增的文件和 `pkg.generated.mbti`。

- [ ] **步骤 11:提交**

```bash
cd /d/moonbitsource && git add -A && git commit -q -F - <<'EOF'
feat(date): 添加 Date 类型、CalendarError 与测试数据生成/嵌入脚本

- date 包:合法性检查、星期、日期加减,内部以「距 1970-01-01 的天数」运算
  (Hinnant 的 days_from_civil 算法,纯 Int,无浮点),范围 0001–9999 年
- CalendarError 声明为 pub(all) suberror,兄弟包可以 raise 它的变体
- internal/jsonx:模块内部的 JSON 读取小工具,出错统一抛 DataCorrupt
- scripts/gen_expected.py date:用 Python datetime 生成 3000+ 条预期值
- scripts/embed_data.py:用 moon tool embed 把 JSON 嵌入测试,支持 --check
- 审查重点:畸形日期字符串、Int 极端值的加减天数均有测试

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git log --oneline | head -3
```

- [ ] **步骤 12:向用户讲解 `date` 的核心逻辑(3–5 句)**

1. `Date` 的内部表示是年月日,但所有运算都通过「距 1970-01-01 的天数」完成。
2. 日期 → 天数用 Howard Hinnant 的 `days_from_civil` 算法,以 400 年(146097 天)为一个纪元,把闰年规则折算成纯整数运算;天数 → 日期是它的逆运算。
3. 星期由天数直接得出(1970-01-01 是星期四),用向下取整的取模,所以负的天数也正确。
4. 整个包只用 `Int`,没有浮点,所以三个后端的结果一致。
5. 构造函数是唯一入口(包外无法直接写 `{ year: …}`,编译器会拒绝),所以持有 `Date` 值就等于合法性已经被检查过。

---

### Task 3:农历表与节气表生成器、农历/节气期望数据生成器

**文件:**
- 创建:`scripts/gen_tables.py`、`lunar/moon.pkg`、`lunar/tables_gen.mbt`(生成)
- 创建(生成):`testdata/lunar_samples.json`、`testdata/lunar_month_starts.json`、`testdata/solar_terms.json`
- 创建(生成):`lunar/lunar_samples_test.mbt`、`lunar/lunar_month_starts_test.mbt`、`lunar/solar_terms_test.mbt`
- 修改:`scripts/gencommon.py`(追加 `LUNAR_PYTHON_VERSION`、`require_lunar_python`)、`scripts/gen_expected.py`(加入 `lunar`、`terms`)、`scripts/embed_data.py`(追加三个 `EMBEDS` 条目)

**接口:**
- 消费:任务 2 的 `gencommon.write_sectioned_json`、`gencommon.write_text`、`gencommon.read_text`、`gen_expected.GENERATORS`、`embed_data.EMBEDS`
- 产出:
  - `lunar/tables_gen.mbt`(包 `lunar` 内私有):`let lunar_info : FixedArray[Int]`(201 项,下标 `年份 - 1900`)、`let solar_term_days : FixedArray[Int]`(4824 项,下标 `(年份 - 1900) * 24 + k`)。位域见设计文档 §5.2.1
  - 测试专用的嵌入常量:`lunar_samples_json`、`lunar_month_starts_json`、`solar_terms_json`(`String`)
  - `testdata/lunar_samples.json`:`{"meta":…, "samples":[{"s":"YYYY-MM-DD","y":农历年,"m":农历月,"leap":0或1,"d":农历日,"t":"sample"} ×1000], "edges":[同样的字段,"t" 为标签 range_first / range_last / new_year / new_year_eve / leap_first / leap_last / solar_jan1 / term_edge(term_edge 另有 "jq" 节气名)]}`
  - `testdata/lunar_month_starts.json`:`{"meta":…, "years":[{"y":年,"months":[[月, 闰标记0或1, "YYYY-MM-DD"(该月初一), 月长], …]} ×201]}`
  - `testdata/solar_terms.json`:`{"meta":{…, "names":[24 个节气名]}, "years":[{"y":年,"t":[[公历月, 日] ×24]} ×201]}`

- [ ] **步骤 1:创建项目内的 Python 虚拟环境并安装 lunar_python**

```bash
cd /d/moonbitsource && python -m venv .venv && .venv/Scripts/python -m pip install -q -r scripts/requirements.txt -i https://pypi.org/simple && .venv/Scripts/python -c "import importlib.metadata as m; print(m.version('lunar_python'))"
```
预期输出:`1.4.8`。(`.venv/` 已在 `.gitignore` 中。)

- [ ] **步骤 2:在 `scripts/gencommon.py` 末尾追加版本检查**

```python


LUNAR_PYTHON_VERSION = "1.4.8"


def require_lunar_python():
    """确认安装的 lunar_python 与固定版本一致,返回版本号。"""
    import importlib.metadata as metadata

    try:
        version = metadata.version("lunar_python")
    except metadata.PackageNotFoundError:
        raise SystemExit(
            "未安装 lunar_python。请运行:\n"
            "  python -m venv .venv\n"
            "  .venv/Scripts/python -m pip install -r scripts/requirements.txt -i https://pypi.org/simple"
        )
    if version != LUNAR_PYTHON_VERSION:
        raise SystemExit("需要 lunar_python==%s,当前是 %s" % (LUNAR_PYTHON_VERSION, version))
    return version
```

- [ ] **步骤 3:写 `scripts/gen_tables.py`**

```python
#!/usr/bin/env python3
"""从 lunar-python 生成 lunar/tables_gen.mbt(农历年表与节气表)。

用法:
    python scripts/gen_tables.py           重新生成
    python scripts/gen_tables.py --check   只检查已提交的文件是否与重新生成的结果一致

表是用 lunar-python 的 LunarYear 接口生成的;测试预期值(gen_expected.py)用的是它的逐日接口。
注意:这两个入口共用同一套天文计算,所以它们一致只能说明接口用对了,
不能证明 lunar-python 自身正确(见设计文档 §7.1)。
"""
import datetime as dt
import sys

from gencommon import read_text, require_lunar_python, write_text

FIRST_YEAR, LAST_YEAR = 1900, 2100
OUT = "lunar/tables_gen.mbt"


def lunar_info(year):
    from lunar_python import LunarYear, Solar

    ly = LunarYear.fromYear(year)
    leap = ly.getLeapMonth()
    months = [m for m in ly.getMonths() if m.getYear() == year]
    assert len(months) == (13 if leap else 12), (year, len(months), leap)
    # 月份顺序:1..leap,闰 leap(负数),leap+1..12
    expected_order = []
    for month in range(1, 13):
        expected_order.append(month)
        if month == leap:
            expected_order.append(-leap)
    assert [m.getMonth() for m in months] == expected_order, (year, "月份顺序")
    bits = 0
    for slot, m in enumerate(months):
        days = m.getDayCount()
        assert days in (29, 30), (year, slot, days)
        if days == 30:
            bits |= 1 << slot
    new_year = Solar.fromJulianDay(months[0].getFirstJulianDay())
    assert new_year.getYear() == year, (year, new_year.toYmd())
    offset = (
        dt.date(new_year.getYear(), new_year.getMonth(), new_year.getDay())
        - dt.date(year, 1, 21)
    ).days
    assert 0 <= offset < 32, (year, offset)
    return leap | (bits << 4) | (offset << 17)


def solar_term_days(year):
    from lunar_python import LunarYear, Solar

    # 下标 2..25 依次是:小寒、大寒、…、大雪、当年的冬至
    jds = LunarYear.fromYear(year).getJieQiJulianDays()[2:26]
    assert len(jds) == 24, year
    days = []
    for k, jd in enumerate(jds):
        s = Solar.fromJulianDay(jd)
        assert s.getYear() == year and s.getMonth() == k // 2 + 1, (year, k, s.toYmd())
        assert 3 <= s.getDay() <= 24, (year, k, s.getDay())
        days.append(s.getDay())
    return days


def render(version):
    years = range(FIRST_YEAR, LAST_YEAR + 1)
    infos = [lunar_info(y) for y in years]
    terms = [solar_term_days(y) for y in years]
    lines = [
        "// 由 scripts/gen_tables.py 生成,请勿手工修改(DO NOT EDIT)。",
        "// 数据来源:lunar_python==%s(MIT 许可,版权 6tail),范围 %d–%d 年。"
        % (version, FIRST_YEAR, LAST_YEAR),
        "",
        "///|",
        "/// 农历年表,下标为「年份 - 1900」,共 201 项。每项的位域:",
        "///   bit 0–3    闰月月份(0 表示无闰月)",
        "///   bit 4–16   13 个月槽位,按月份出现的顺序(闰月紧跟同数字的正常月);"
        "为 1 表示该月 30 天,为 0 表示 29 天",
        "///   bit 17–21  正月初一相对当年 1 月 21 日的偏移天数",
        "let lunar_info : FixedArray[Int] = [",
    ]
    lines += ["  %d," % v for v in infos]
    lines += [
        "]",
        "",
        "///|",
        "/// 二十四节气表,下标为「(年份 - 1900) * 24 + k」,k = 0 为小寒,k = 23 为冬至;值是几号。",
        "/// 第 k 个节气所在的公历月固定为 k / 2 + 1。",
        "let solar_term_days : FixedArray[Int] = [",
    ]
    for year_days in terms:
        lines.append("  " + ", ".join(str(v) for v in year_days) + ",")
    lines.append("]")
    return "\n".join(lines) + "\n"


def main(argv):
    version = require_lunar_python()
    text = render(version)
    if "--check" in argv:
        if read_text(OUT) != text:
            print(OUT, "已过期,请运行 python scripts/gen_tables.py")
            return 1
        print(OUT, "是最新的")
        return 0
    write_text(OUT, text)
    print("已生成", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **步骤 4:运行表生成器,检查可重复性与格式稳定性**

```bash
cd /d/moonbitsource && export PYTHONUTF8=1 && mkdir -p lunar && printf 'warnings = "-implicit_impl_as_method"\n' > lunar/moon.pkg
.venv/Scripts/python scripts/gen_tables.py
.venv/Scripts/python scripts/gen_tables.py --check
sha256sum lunar/tables_gen.mbt > "$TEMP/tables.sha" && moon fmt && sha256sum -c "$TEMP/tables.sha"
wc -l lunar/tables_gen.mbt && sed -n 1,12p lunar/tables_gen.mbt | cut -c1-110
```
预期:
- 脚本没有 `AssertionError`(它在生成时自检了 201 年的月份顺序、月长、正月初一偏移、节气所在月和日的范围);
- `--check` 输出 `lunar/tables_gen.mbt 是最新的`;
- `sha256sum -c` 输出 `OK`(`moon fmt` 没有改动生成文件;如果它改了,调整 `render` 的输出格式使其与 `moon fmt` 的结果一致,再重新生成);
- 文件约 420 行,开头是 `// 由 scripts/gen_tables.py 生成…`。

- [ ] **步骤 5:在 `scripts/gen_expected.py` 中加入农历与节气的生成器**

(a) 把文件顶部的导入区改成:
```python
import calendar
import datetime as dt
import functools
import random
import sys
from collections import namedtuple

from gencommon import LUNAR_PYTHON_VERSION, require_lunar_python, write_sectioned_json
```

(b) 在 `GENERATORS = {` 之前插入:
```python
FIRST_YEAR, LAST_YEAR = 1900, 2100
DOMAIN_FIRST = dt.date(1900, 1, 31)  # 农历 1900 年正月初一
DOMAIN_LAST = dt.date(2101, 1, 28)  # 农历 2100 年最后一天

Row = namedtuple("Row", "date ly lm leap ld jq")


@functools.lru_cache(maxsize=None)
def scan():
    """逐日扫描 1900-01-01 ~ 2101-01-28,记录 lunar-python 给出的农历日期与节气(约一分钟)。"""
    from lunar_python import Solar

    require_lunar_python()
    rows = []
    d = dt.date(1900, 1, 1)
    while d <= DOMAIN_LAST:
        lunar = Solar.fromYmd(d.year, d.month, d.day).getLunar()
        m = lunar.getMonth()
        rows.append(Row(d, lunar.getYear(), abs(m), m < 0, lunar.getDay(), lunar.getJieQi()))
        d += dt.timedelta(days=1)
    # 自检:农历日期逐日连续(同月内日加一,换月从初一开始)
    for prev, cur in zip(rows, rows[1:]):
        same_month = (cur.ly, cur.lm, cur.leap) == (prev.ly, prev.lm, prev.leap)
        assert (same_month and cur.ld == prev.ld + 1) or (not same_month and cur.ld == 1), (prev, cur)
    return rows


def lunar_meta(extra=None):
    meta = {
        "generator": "scripts/gen_expected.py",
        "reference": "lunar_python==%s 的逐日接口(Solar.getLunar / Lunar.getSolar / Lunar.getJieQi)"
        % LUNAR_PYTHON_VERSION,
        "seed": SEED,
        "domain": [DOMAIN_FIRST.isoformat(), DOMAIN_LAST.isoformat()],
    }
    if extra:
        meta.update(extra)
    return meta


def lunar_record(row, tag, **extra):
    rec = {
        "s": row.date.isoformat(),
        "y": row.ly,
        "m": row.lm,
        "leap": 1 if row.leap else 0,
        "d": row.ld,
        "t": tag,
    }
    rec.update(extra)
    return rec


def gen_lunar():
    """农历转换的随机样本与边界集合 + 每个农历月的初一与月长。"""
    from lunar_python import Lunar

    rows = scan()
    dom = [r for r in rows if r.date >= DOMAIN_FIRST]
    rng = random.Random(SEED)

    def reverse_ok(r):
        # 反方向再问一次 lunar-python:农历 → 公历必须回到同一天
        s = Lunar.fromYmd(r.ly, -r.lm if r.leap else r.lm, r.ld).getSolar()
        assert (s.getYear(), s.getMonth(), s.getDay()) == (r.date.year, r.date.month, r.date.day), r

    samples = []
    for i in sorted(rng.sample(range(len(dom)), 1000)):
        reverse_ok(dom[i])
        samples.append(lunar_record(dom[i], "sample"))

    edges = []

    def edge(row, tag, **extra):
        reverse_ok(row)
        edges.append(lunar_record(row, tag, **extra))

    edge(dom[0], "range_first")
    edge(dom[-1], "range_last")
    by_year = {}
    for r in dom:
        by_year.setdefault(r.ly, []).append(r)
    for y in sorted(by_year):
        edge(by_year[y][0], "new_year")
        edge(by_year[y][-1], "new_year_eve")
    leap_groups = {}
    for r in dom:
        if r.leap:
            leap_groups.setdefault((r.ly, r.lm), []).append(r)
    for key in sorted(leap_groups):
        edge(leap_groups[key][0], "leap_first")
        edge(leap_groups[key][-1], "leap_last")
    for r in dom:
        if r.date.month == 1 and r.date.day == 1 and r.date > DOMAIN_FIRST:
            edge(r, "solar_jan1")
    for i, r in enumerate(dom):
        if r.jq and r.date.year <= LAST_YEAR:
            is_month_end = i + 1 < len(dom) and dom[i + 1].ld == 1
            if r.ld == 1 or is_month_end:
                edge(r, "term_edge", jq=r.jq)

    counts = {}
    for e in edges:
        counts[e["t"]] = counts.get(e["t"], 0) + 1
    write_sectioned_json(
        "testdata/lunar_samples.json",
        [("meta", lunar_meta({"edge_counts": counts})), ("samples", samples), ("edges", edges)],
    )
    print("testdata/lunar_samples.json:", len(samples), "个随机样本,", len(edges), "个边界用例", counts)

    # 每个农历月的初一与月长
    months_by_year = {}
    cur = None
    for r in dom:
        key = (r.ly, r.lm, r.leap)
        if cur is None or cur[0] != key:
            cur = [key, r.date, 0]
            months_by_year.setdefault(r.ly, []).append(cur)
        cur[2] += 1
    lines = []
    for y in sorted(months_by_year):
        months = [
            [k[1], 1 if k[2] else 0, start.isoformat(), n] for (k, start, n) in months_by_year[y]
        ]
        assert all(m[3] in (29, 30) for m in months), y
        lines.append({"y": y, "months": months})
    assert len(lines) == LAST_YEAR - FIRST_YEAR + 1
    write_sectioned_json(
        "testdata/lunar_month_starts.json",
        [("meta", lunar_meta()), ("years", lines)],
    )
    print("testdata/lunar_month_starts.json:", len(lines), "个农历年")


def gen_terms():
    """1900–2100 年每年 24 个节气的(公历月, 日)。"""
    rows = scan()
    per_year = {}
    for r in rows:
        if r.jq and r.date.year <= LAST_YEAR:
            per_year.setdefault(r.date.year, []).append((r.jq, r.date.month, r.date.day))
    names = [n for (n, _, _) in per_year[2024]]
    assert len(names) == 24, names
    lines = []
    for y in range(FIRST_YEAR, LAST_YEAR + 1):
        v = per_year[y]
        assert len(v) == 24 and [n for (n, _, _) in v] == names, y
        assert all(m == k // 2 + 1 for k, (_, m, _) in enumerate(v)), y
        lines.append({"y": y, "t": [[m, d] for (_, m, d) in v]})
    write_sectioned_json(
        "testdata/solar_terms.json",
        [("meta", lunar_meta({"names": names})), ("years", lines)],
    )
    print("testdata/solar_terms.json:", len(lines), "年 × 24 个节气")
```

(c) 把 `GENERATORS` 改成:
```python
GENERATORS = {
    "date": gen_date,
    "lunar": gen_lunar,
    "terms": gen_terms,
}
```

- [ ] **步骤 6:在 `scripts/embed_data.py` 的 `EMBEDS` 里追加三项**

```python
    ("testdata/lunar_samples.json", "lunar/lunar_samples_test.mbt", "lunar_samples_json"),
    ("testdata/lunar_month_starts.json", "lunar/lunar_month_starts_test.mbt", "lunar_month_starts_json"),
    ("testdata/solar_terms.json", "lunar/solar_terms_test.mbt", "solar_terms_json"),
```

- [ ] **步骤 7:生成预期数据(约 1 分钟)并检查可重复性**

```bash
cd /d/moonbitsource && export PYTHONUTF8=1
.venv/Scripts/python scripts/gen_expected.py lunar terms
sha256sum testdata/lunar_samples.json testdata/lunar_month_starts.json testdata/solar_terms.json > "$TEMP/lunar.sha"
.venv/Scripts/python scripts/gen_expected.py lunar terms && sha256sum -c "$TEMP/lunar.sha"
python scripts/embed_data.py
wc -l testdata/lunar_samples.json testdata/lunar_month_starts.json testdata/solar_terms.json lunar/*_test.mbt
```
预期:
- 输出 `1000 个随机样本` 与一千多个边界用例,并打印各类标签的个数(总数以实际输出为准;预期 `new_year` 与 `new_year_eve` 各 201,`solar_jan1` 为 201,`term_edge` 为 326,`leap_first` 与 `leap_last` 个数相同);
- `sha256sum -c` 三个文件都是 `OK`;
- 所有文件的行数都远小于 16000(最大的是 `lunar_samples.json`,约 2100 行)。

- [ ] **步骤 8:用 Python 独立解码生成的表,与预期数据交叉核对**

这一步在 MoonBit 实现之前先确认:表和预期数据在 201 年内逐年一致。它是一次性检查,不提交。

```bash
cd /d/moonbitsource && PYTHONUTF8=1 .venv/Scripts/python - <<'PY'
import datetime as dt, json, re
text = open("lunar/tables_gen.mbt", encoding="utf-8").read()
info_block = text.split("let lunar_info : FixedArray[Int] = [")[1].split("]")[0]
infos = [int(x) for x in re.findall(r"\d+", info_block)]
term_block = text.split("let solar_term_days : FixedArray[Int] = [")[1].split("]")[0]
terms = [int(x) for x in re.findall(r"\d+", term_block)]
assert len(infos) == 201 and len(terms) == 4824
ms = json.load(open("testdata/lunar_month_starts.json", encoding="utf-8"))["years"]
bad = 0
for rec in ms:
    y = rec["y"]; info = infos[y - 1900]
    leap = info & 15; slots = 13 if leap else 12
    start = dt.date(y, 1, 21) + dt.timedelta(days=(info >> 17) & 31)
    expect = []
    for s in range(slots):
        if leap == 0 or s < leap: m, lp = s + 1, 0
        elif s == leap: m, lp = leap, 1
        else: m, lp = s, 0
        days = 30 if (info >> (4 + s)) & 1 else 29
        expect.append([m, lp, start.isoformat(), days])
        start += dt.timedelta(days=days)
    if expect != rec["months"]:
        bad += 1; print("农历表不一致:", y)
st = json.load(open("testdata/solar_terms.json", encoding="utf-8"))["years"]
for rec in st:
    y = rec["y"]
    got = [[k // 2 + 1, terms[(y - 1900) * 24 + k]] for k in range(24)]
    if got != rec["t"]:
        bad += 1; print("节气表不一致:", y)
print("不一致的年份数:", bad)
assert bad == 0
PY
```
预期:最后一行 `不一致的年份数: 0`。

- [ ] **步骤 9:编译检查与三后端测试**

```bash
cd /d/moonbitsource && moon fmt && moon info && moon check 2>&1 | grep -E "^Error"; for t in js wasm-gc native; do echo "== $t"; moon test --target $t 2>&1 | grep -E "Total tests|rror|FAIL"; done
python scripts/embed_data.py --check && .venv/Scripts/python scripts/gen_tables.py --check
```
预期:无 `Error`;三个后端都输出 `Total tests: 8, passed: 8, failed: 0.`(`lunar` 目前没有测试,只有生成的表和嵌入常量参与编译,可能有「未使用」警告,这是正常的);两个 `--check` 都输出「是最新的」。

- [ ] **步骤 10:提交**

```bash
cd /d/moonbitsource && git add -A && git status --short | head -20 && git commit -q -F - <<'EOF'
feat(scripts): 添加农历表/节气表生成器与农历、节气期望数据生成器

- scripts/gen_tables.py:用 lunar-python 的 LunarYear 接口生成 lunar/tables_gen.mbt
  (201 个农历年的闰月/月大小/正月初一偏移,以及 201×24 个节气的日期),
  生成时自检月份顺序、月长、偏移范围、节气所在月;支持 --check
- scripts/gen_expected.py lunar terms:用 lunar-python 的逐日接口扫描 1900–2101,
  生成 1000 个随机样本、约千条边界用例(闰月首尾、除夕、正月初一、元旦、
  节气落在农历月初/月末)、每个农历月的初一与月长、201 年×24 个节气
- 生成时对每条记录反向查询一次(农历→公历)自检;输出不含时间戳,可逐字节重现
- 已用 Python 独立解码生成的表,与预期数据在 201 年内逐年核对一致

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git log --oneline | head -3
```

---

### Task 4:`lunar` 包:公历 ↔ 农历

**文件:**
- 创建:`lunar/lunar.mbt`、`lunar/lunar_test.mbt`、`lunar/lunar_wbtest.mbt`
- 修改:`lunar/moon.pkg`(加入 `date` 依赖与测试依赖)

**接口:**
- 消费:任务 2 的 `@date.Date`、`@date.CalendarError`、`Date::new` / `to_days` / `from_days`;`@jsonx.*`;任务 3 的 `lunar_info`、`lunar_samples_json`、`lunar_month_starts_json`
- 产出(任务 5、9 依赖):
  - `LunarDate`:`pub struct`,字段 `year`、`month`、`is_leap`、`day`(包外只读);`derive(Eq, Compare, Debug)`;`Show` 输出 `2023-闰02-01` 这样的格式
  - `LunarDate::new(year : Int, month : Int, is_leap : Bool, day : Int) -> LunarDate raise @date.CalendarError`(年份越界 `OutOfRange`,其余不合法 `InvalidDate`)
  - `solar_to_lunar(d : @date.Date) -> LunarDate raise @date.CalendarError`
  - `lunar_to_solar(l : LunarDate) -> @date.Date raise @date.CalendarError`
  - `leap_month(year : Int) -> Int raise @date.CalendarError`(0 表示该年无闰月)
  - `month_days(year : Int, month : Int, is_leap : Bool) -> Int raise @date.CalendarError`
  - 包内私有:常量 `FIRST_YEAR`(1900)、`LAST_YEAR`(2100);`info_of`、`leap_of`、`slot_count`、`slot_days`、`new_year_days`

- [ ] **步骤 1:更新 `lunar/moon.pkg`**

```
warnings = "-implicit_impl_as_method"

import {
  "sayoi7799/cncal/date",
}

import {
  "sayoi7799/cncal/internal/jsonx",
} for "test"
```

- [ ] **步骤 2:写测试 `lunar/lunar_test.mbt`**

```moonbit
///|
fn[T : Show] expect_invalid(
  f : () -> T raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.InvalidDate(_) => ()
    e => fail("\{what}: 期望 InvalidDate,实际 \{e}")
  } noraise {
    v => fail("\{what}: 期望 InvalidDate,实际得到 \{v}")
  }
}

///|
fn[T : Show] expect_out_of_range(
  f : () -> T raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.OutOfRange(_) => ()
    e => fail("\{what}: 期望 OutOfRange,实际 \{e}")
  } noraise {
    v => fail("\{what}: 期望 OutOfRange,实际得到 \{v}")
  }
}

///|
/// 一条预期记录:公历日期 ↔ 农历日期必须双向一致。
fn check_conversion(rec : Json) -> Unit raise {
  let s = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "s")))
  let y = @jsonx.as_int(@jsonx.field(rec, "y"))
  let m = @jsonx.as_int(@jsonx.field(rec, "m"))
  let leap = @jsonx.as_int(@jsonx.field(rec, "leap")) == 1
  let d = @jsonx.as_int(@jsonx.field(rec, "d"))
  let tag = @jsonx.as_string(@jsonx.field(rec, "t"))
  let expected = @lunar.LunarDate::new(y, m, leap, d)
  assert_eq(@lunar.solar_to_lunar(s), expected, msg="公历→农历 \{s} (\{tag})")
  assert_eq(@lunar.lunar_to_solar(expected), s, msg="农历→公历 \{expected} (\{tag})")
}

///|
test "1000 个随机日期的公历与农历互转和 lunar-python 一致" {
  let root = @jsonx.parse(lunar_samples_json)
  let samples = @jsonx.as_array(@jsonx.field(root, "samples"))
  assert_eq(samples.length(), 1000)
  for rec in samples {
    check_conversion(rec)
  }
}

///|
test "边界集合:闰月首尾、除夕、正月初一、元旦、节气落在农历月初月末" {
  let root = @jsonx.parse(lunar_samples_json)
  let edges = @jsonx.as_array(@jsonx.field(root, "edges"))
  let counts : Map[String, Int] = Map([])
  for rec in edges {
    check_conversion(rec)
    let tag = @jsonx.as_string(@jsonx.field(rec, "t"))
    counts[tag] = counts.get(tag).unwrap_or(0) + 1
  }
  // 每一类边界都确实出现过,防止生成器悄悄漏掉某一类
  for tag in [
    "range_first", "range_last", "new_year", "new_year_eve", "leap_first", "leap_last",
    "solar_jan1", "term_edge",
  ] {
    assert_true(counts.get(tag).unwrap_or(0) > 0, msg="缺少边界类别 \{tag}")
  }
  // 201 个农历年各有一个正月初一与一个除夕
  assert_eq(counts.get("new_year"), Some(201))
  assert_eq(counts.get("new_year_eve"), Some(201))
  assert_eq(counts.get("leap_first"), counts.get("leap_last"))
}

///|
test "每个农历月的初一与月长和 lunar-python 一致(覆盖整个农历域)" {
  let root = @jsonx.parse(lunar_month_starts_json)
  let years = @jsonx.as_array(@jsonx.field(root, "years"))
  assert_eq(years.length(), 201)
  for rec in years {
    let y = @jsonx.as_int(@jsonx.field(rec, "y"))
    let months = @jsonx.as_array(@jsonx.field(rec, "months"))
    let mut leap_in_data = 0
    for item in months {
      let parts = @jsonx.as_array(item)
      let m = @jsonx.as_int(parts[0])
      let leap = @jsonx.as_int(parts[1]) == 1
      let start = @date.Date::from_iso(@jsonx.as_string(parts[2]))
      let days = @jsonx.as_int(parts[3])
      if leap {
        leap_in_data = m
      }
      let first_day = @lunar.LunarDate::new(y, m, leap, 1)
      assert_eq(@lunar.lunar_to_solar(first_day), start, msg="初一 \{first_day}")
      assert_eq(@lunar.month_days(y, m, leap), days, msg="月长 \{first_day}")
    }
    assert_eq(@lunar.leap_month(y), leap_in_data, msg="闰月 \{y}")
    assert_eq(months.length(), if leap_in_data == 0 { 12 } else { 13 })
  }
}

///|
test "农历域内逐日往返恒等且逐日连续(约 73000 天)" {
  let first = @date.Date::new(1900, 1, 31)
  let last = @date.Date::new(2101, 1, 28)
  let total = first.days_between(last)
  let mut prev : @lunar.LunarDate? = None
  for i in 0..=total {
    let d = first.add_days(i)
    let l = @lunar.solar_to_lunar(d)
    assert_eq(@lunar.lunar_to_solar(l), d, msg="往返 \{d}")
    match prev {
      Some(p) =>
        if l.year == p.year && l.month == p.month && l.is_leap == p.is_leap {
          assert_eq(l.day, p.day + 1, msg="同月内日期应逐日加一: \{d}")
        } else {
          assert_eq(l.day, 1, msg="换月应从初一开始: \{d}")
          assert_eq(
            p.day,
            @lunar.month_days(p.year, p.month, p.is_leap),
            msg="换月前一天应是月末: \{d}",
          )
        }
      None => ()
    }
    prev = Some(l)
  }
}

///|
test "农历域边界:域外的日期报 OutOfRange" {
  // 域内首尾(1900-01-31 与 2101-01-28)的预期值来自生成的 range_first / range_last 用例
  expect_out_of_range(() => @lunar.solar_to_lunar(@date.Date::new(1900, 1, 30)), "1900-01-30")
  expect_out_of_range(() => @lunar.solar_to_lunar(@date.Date::new(2101, 1, 29)), "2101-01-29")
  expect_out_of_range(() => @lunar.solar_to_lunar(@date.Date::new(1899, 12, 31)), "1899-12-31")
  expect_out_of_range(() => @lunar.solar_to_lunar(@date.Date::new(1, 1, 1)), "0001-01-01")
  expect_out_of_range(() => @lunar.solar_to_lunar(@date.Date::new(9999, 12, 31)), "9999-12-31")
}

///|
test "审查重点:闰月标记、月份、日期、年份的误用一律报错" {
  let root = @jsonx.parse(lunar_month_starts_json)
  for rec in @jsonx.as_array(@jsonx.field(root, "years")) {
    let y = @jsonx.as_int(@jsonx.field(rec, "y"))
    let leap_months : Array[Int] = []
    for item in @jsonx.as_array(@jsonx.field(rec, "months")) {
      let parts = @jsonx.as_array(item)
      let m = @jsonx.as_int(parts[0])
      let leap = @jsonx.as_int(parts[1]) == 1
      let days = @jsonx.as_int(parts[3])
      if leap {
        leap_months.push(m)
      }
      // 月内最后一天合法;再往后一天、第 0 天、负数天都不合法
      assert_eq(@lunar.LunarDate::new(y, m, leap, days).day, days)
      expect_invalid(() => @lunar.LunarDate::new(y, m, leap, days + 1), "\{y}-\{m} 第 \{days + 1} 天")
      expect_invalid(() => @lunar.LunarDate::new(y, m, leap, 0), "\{y}-\{m} 第 0 天")
      expect_invalid(() => @lunar.LunarDate::new(y, m, leap, -1), "\{y}-\{m} 第 -1 天")
    }
    // 没有闰月的月份,加上闰标记必须报错,不能换算成别的合法日期
    for m in 1..=12 {
      if not(leap_months.contains(m)) {
        expect_invalid(() => @lunar.LunarDate::new(y, m, true, 1), "\{y} 年没有闰 \{m} 月")
      }
    }
    expect_invalid(() => @lunar.LunarDate::new(y, 0, false, 1), "\{y} 年 0 月")
    expect_invalid(() => @lunar.LunarDate::new(y, 13, false, 1), "\{y} 年 13 月")
    expect_invalid(() => @lunar.LunarDate::new(y, -1, false, 1), "\{y} 年 -1 月")
  }
  // 年份越界
  for y in [1899, 2101, 0, -1, 2147483647, -2147483648] {
    expect_out_of_range(() => @lunar.LunarDate::new(y, 1, false, 1), "LunarDate::new 年份 \{y}")
    expect_out_of_range(() => @lunar.leap_month(y), "leap_month 年份 \{y}")
    expect_out_of_range(() => @lunar.month_days(y, 1, false), "month_days 年份 \{y}")
  }
}
```

`lunar/lunar_wbtest.mbt`(白盒测试,可以访问包内私有的表):
```moonbit
///|
test "农历表自洽:相邻两年正月初一之差等于上一年各月天数之和" {
  for year in 1900..<2100 {
    let info = lunar_info[year - FIRST_YEAR]
    let next = lunar_info[year + 1 - FIRST_YEAR]
    let mut total = 0
    for slot in 0..<slot_count(info) {
      let days = slot_days(info, slot)
      assert_true(days == 29 || days == 30, msg="\{year} 年第 \{slot} 个月槽位的天数")
      total += days
    }
    if leap_of(info) == 0 {
      assert_true(total >= 353 && total <= 355, msg="\{year} 年共 \{total} 天")
    } else {
      assert_true(total >= 383 && total <= 385, msg="\{year} 年(有闰月)共 \{total} 天")
    }
    assert_eq(
      new_year_days(year + 1, next) - new_year_days(year, info),
      total,
      msg="\{year} 年的天数应等于两个正月初一之差",
    )
  }
}

///|
test "农历表自洽:闰月在 0–12 之间,表的长度正确" {
  assert_eq(lunar_info.length(), 201)
  for info in lunar_info {
    assert_true(leap_of(info) >= 0 && leap_of(info) <= 12)
  }
}
```

- [ ] **步骤 3:运行测试,确认失败**

```bash
cd /d/moonbitsource && moon check 2>&1 | grep -E "^Error" | head -5
```
预期:编译错误,指出 `FIRST_YEAR`、`LunarDate`、`solar_to_lunar` 等未定义。

- [ ] **步骤 4:实现 `lunar/lunar.mbt`**

```moonbit
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
  if leap == 0 || month < leap || (month == leap && not(is_leap)) {
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
  { year, month, is_leap, day }
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
    raise @date.OutOfRange("日期超出农历支持范围 \{first} 至 \{last}: \{d}")
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
  { year, month, is_leap, day: rest + 1 }
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
```

- [ ] **步骤 5:运行测试,确认通过**

```bash
cd /d/moonbitsource && moon fmt && moon info && moon check 2>&1 | grep -E "^Error"; for t in js wasm-gc native; do echo "== $t"; moon test --target $t 2>&1 | grep -E "Total tests|rror|FAIL"; done
```
预期:三个后端都输出 `Total tests: 16, passed: 16, failed: 0.`(之前的 8 个 + 本任务的 6 个黑盒 + 2 个白盒)。逐日往返那条测试在 js 后端可能需要几秒。

如果某条断言失败,`msg=` 里有日期和标签。先判断是实现错了还是预期数据错了:预期数据来自 lunar-python,以它为准;实现与预期不一致时,先检查实现里的槽位换算与「2101 年归入 2100」的特例。

- [ ] **步骤 6:提交**

```bash
cd /d/moonbitsource && git add -A && git commit -q -F - <<'EOF'
feat(lunar): 添加公历与农历互转(含闰月),域外报 OutOfRange

- 农历年表每年一个 Int:闰月、13 个月槽位的大小、正月初一偏移;全程纯 Int
- 公历转农历:正月初一一定在 1 月 21 日~2 月 20 日,先把农历年缩小到两个候选,
  再用天数差逐个月槽位扣除;闰月紧跟同数字的正常月,换算只需一个分支
- 农历域:公历 1900-01-31 ~ 2101-01-28(与 lunar-python 的实测边界一致)
- 测试:1000 个随机日期 + 约千条边界用例(闰月首尾、除夕、正月初一、元旦、
  节气落在农历月初月末)双向比对;201 年每个农历月的初一与月长比对;
  域内约 73000 天逐日往返恒等且逐日连续;表自洽性白盒测试
- 审查重点:闰月标记误用、月/日越界、年份越界、Int 极端年份均有测试

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git log --oneline | head -3
```

- [ ] **步骤 7:向用户讲解公历 ↔ 农历的核心逻辑(3–5 句)**

1. 农历的所有信息只有一张表:每年一个整数,里面存着闰月是几月、各个月是大月还是小月、正月初一落在公历几月几日。
2. 这张表不是手写的,而是 `scripts/gen_tables.py` 从 lunar-python 生成的,所以可以复现、可以逐位核对。
3. 公历转农历时,先利用「正月初一一定在 1 月 21 日到 2 月 20 日」把农历年缩小到两个候选,再用天数差逐个月扣除,扣到哪个月就是哪个月;农历转公历是同一计算的逆过程。
4. 闰月在「月槽位」里紧跟同数字的正常月,所以月份和槽位的换算只需要一个分支。
5. 库内没有浮点运算,三个后端不可能因为数学函数的实现差异而出现不同结果。

---

### Task 5:`lunar` 包:二十四节气

**文件:**
- 创建:`lunar/solar_term.mbt`、`lunar/solar_term_test.mbt`
- 修改:`lunar/lunar_wbtest.mbt`(追加节气表的白盒测试)

**接口:**
- 消费:任务 3 的 `solar_term_days`、`solar_terms_json`;任务 4 的 `FIRST_YEAR`、`LAST_YEAR`、`expect_invalid` / `expect_out_of_range`(定义在 `lunar_test.mbt`,同一个黑盒测试包共享)
- 产出(任务 9 依赖):
  - `SolarTerm`:`pub(all) enum`,24 个变体(`XiaoHan` 小寒 … `DongZhi` 冬至);`derive(Eq, Compare, Debug)`
  - `SolarTerm::index(self) -> Int`(小寒为 0,冬至为 23)、`SolarTerm::name(self) -> String`("小寒" … "冬至")
  - `SolarTermDate`:`pub struct`,字段 `term : SolarTerm`、`date : @date.Date`;`derive(Eq, Debug)`;`Show`
  - `solar_terms(year : Int) -> Array[SolarTermDate] raise @date.CalendarError`(24 个,按日期升序,从小寒到冬至;年份不在 1900–2100 报 `OutOfRange`)

- [ ] **步骤 1:写测试 `lunar/solar_term_test.mbt`**

```moonbit
///|
test "二十四节气在 1900–2100 全部年份与 lunar-python 一致" {
  let root = @jsonx.parse(solar_terms_json)
  let names = @jsonx.as_array(@jsonx.field(@jsonx.field(root, "meta"), "names"))
  assert_eq(names.length(), 24)
  let years = @jsonx.as_array(@jsonx.field(root, "years"))
  assert_eq(years.length(), 201)
  for rec in years {
    let y = @jsonx.as_int(@jsonx.field(rec, "y"))
    let expected = @jsonx.as_array(@jsonx.field(rec, "t"))
    let actual = @lunar.solar_terms(y)
    assert_eq(actual.length(), 24, msg="\{y} 年的节气个数")
    for k in 0..<24 {
      let pair = @jsonx.as_array(expected[k])
      let month = @jsonx.as_int(pair[0])
      let day = @jsonx.as_int(pair[1])
      assert_eq(
        actual[k].date,
        @date.Date::new(y, month, day),
        msg="\{y} 年第 \{k} 个节气的日期",
      )
      assert_eq(
        actual[k].term.name(),
        @jsonx.as_string(names[k]),
        msg="\{y} 年第 \{k} 个节气的名称",
      )
      assert_eq(actual[k].term.index(), k)
    }
  }
}

///|
test "每年的节气按日期严格递增,小寒在前,冬至在后" {
  for y in 1900..=2100 {
    let terms = @lunar.solar_terms(y)
    assert_eq(terms[0].term, @lunar.XiaoHan)
    assert_eq(terms[23].term, @lunar.DongZhi)
    for k in 0..<23 {
      assert_true(terms[k].date < terms[k + 1].date, msg="\{y} 年第 \{k} 个节气")
    }
  }
}

///|
test "节气只依赖公历年,不受农历域边界限制(1900 年的小寒在 1900-01-31 之前)" {
  let terms = @lunar.solar_terms(1900)
  assert_true(terms[0].date < @date.Date::new(1900, 1, 31))
}

///|
test "审查重点:节气年份越界报 OutOfRange" {
  for y in [1899, 2101, 0, -1, 2147483647, -2147483648] {
    expect_out_of_range(() => @lunar.solar_terms(y), "solar_terms(\{y})")
  }
}
```

在 `lunar/lunar_wbtest.mbt` 末尾追加:
```moonbit

///|
test "节气表自洽:长度正确,日期落在 3–24 号" {
  assert_eq(solar_term_days.length(), 201 * 24)
  assert_eq(term_names.length(), 24)
  for v in solar_term_days {
    assert_true(v >= 3 && v <= 24, msg="节气日期 \{v}")
  }
}
```

- [ ] **步骤 2:运行测试,确认失败**

```bash
cd /d/moonbitsource && moon check 2>&1 | grep -E "^Error" | head -5
```
预期:编译错误,指出 `solar_terms`、`SolarTerm`、`term_names` 等未定义。

- [ ] **步骤 3:实现 `lunar/solar_term.mbt`**

```moonbit
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
  XiaoHan, DaHan, LiChun, YuShui, JingZhe, ChunFen, QingMing, GuYu, LiXia, XiaoMan,
  MangZhong, XiaZhi, XiaoShu, DaShu, LiQiu, ChuShu, BaiLu, QiuFen, HanLu, ShuangJiang,
  LiDong, XiaoXue, DaXue, DongZhi,
]

///|
let term_names : FixedArray[String] = [
  "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨", "立夏", "小满", "芒种",
  "夏至", "小暑", "大暑", "立秋", "处暑", "白露", "秋分", "寒露", "霜降", "立冬", "小雪",
  "大雪", "冬至",
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
pub fn solar_terms(year : Int) -> Array[SolarTermDate] raise @date.CalendarError {
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
```

- [ ] **步骤 4:运行测试,确认通过**

```bash
cd /d/moonbitsource && moon fmt && moon info && moon check 2>&1 | grep -E "^Error"; for t in js wasm-gc native; do echo "== $t"; moon test --target $t 2>&1 | grep -E "Total tests|rror|FAIL"; done
```
预期:三个后端都输出 `Total tests: 21, passed: 21, failed: 0.`(之前的 16 个 + 本任务的 4 个黑盒 + 1 个白盒)。

- [ ] **步骤 5:提交**

```bash
cd /d/moonbitsource && git add -A && git commit -q -F - <<'EOF'
feat(lunar): 添加二十四节气查询(1900–2100 年,与 lunar-python 全部一致)

- solar_terms(year) 返回该公历年的 24 个节气,按日期升序,从小寒到冬至
- 节气表只存「几号」:第 k 个节气所在的公历月固定为 k/2+1
- 节气按公历年查询,不受农历域边界限制(1900 年小寒在 1900-01-31 之前)
- 测试:201 年 × 24 个节气的日期与名称逐一比对;严格递增;年份越界(含 Int 极端值)报 OutOfRange

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git log --oneline | head -3
```

- [ ] **步骤 6:向用户讲解节气的核心逻辑(3–5 句)**

1. 节气表同样由 `scripts/gen_tables.py` 从 lunar-python 生成,每年 24 个数字,表示该年每个节气落在几号。
2. 24 个节气里,第 k 个所在的公历月是固定的(小寒、大寒在 1 月,立春、雨水在 2 月……冬至在 12 月),所以表里只存「几号」,月份由序号推出。
3. 实测 1900–2100 年所有节气的日期都在 3 号到 24 号之间,所以公历意义上「节气落在月初月末」不会发生;真正有意义的边界是节气落在农历月的初一或月末,这会影响闰月的判定,测试里专门收录了全部 326 次。
4. 查询按公历年进行,所以不受农历域从 1900-01-31 开始的限制。
5. 同样没有浮点运算,三个后端结果一致。

---

### Task 6:节假日数据导入,并对照国务院通知原文核对

**文件:**
- 创建:`scripts/import_holidays.py`、`data/holidays.json`(生成)、`docs/data-verification.md`
- 修改:`scripts/gencommon.py`(追加 `CHINESE_DAYS_VERSION`、`CACHE`、`chinese_days_dir`)

**接口:**
- 消费:任务 2 的 `gencommon.write_sectioned_json`
- 产出(任务 7 依赖):`data/holidays.json`,格式见设计文档 §5.3.1:`{"schema_version":1, "data_version":"2026.10.01", "coverage":{"from":"2004-01-01","through":"2026-12-31"}, "sources":[{"year":2004,"url":"…"} …], "holidays":[{"name":"元旦","from":"2004-01-01","to":"2004-01-01"} …], "workdays":[{"name":"春节","date":"2004-01-17"} …]}`;每个元素独占一行,`holidays` 与 `workdays` 按日期升序
- 产出:`gencommon.chinese_days_dir() -> str`(已解压的 `chinese-days@1.5.9` 包目录)

- [ ] **步骤 1:在 `scripts/gencommon.py` 中加入 chinese-days 包的下载与定位**

把文件顶部的 `import json\nimport os` 改成:
```python
import json
import os
import shutil
import subprocess
import tarfile
```
并在文件末尾追加:
```python


CHINESE_DAYS_VERSION = "1.5.9"
CACHE = os.path.join(ROOT, "scripts", ".cache")


def chinese_days_dir():
    """返回已解压的 chinese-days 包目录;首次使用时用 npm 下载到 scripts/.cache(需要 Python 3.12+)。"""
    base = os.path.join(CACHE, "chinese-days-" + CHINESE_DAYS_VERSION)
    pkg = os.path.join(base, "package")
    if os.path.isfile(os.path.join(pkg, "package.json")):
        return pkg
    npm = shutil.which("npm")
    if not npm:
        raise SystemExit("需要 Node.js 与 npm(用于下载 chinese-days 包)")
    os.makedirs(base, exist_ok=True)
    subprocess.run(
        [npm, "pack", "chinese-days@" + CHINESE_DAYS_VERSION, "--silent"],
        cwd=base,
        check=True,
    )
    tgz = os.path.join(base, "chinese-days-%s.tgz" % CHINESE_DAYS_VERSION)
    with tarfile.open(tgz) as tf:
        tf.extractall(base, filter="data")
    return pkg
```

- [ ] **步骤 2:写 `scripts/import_holidays.py`**

```python
#!/usr/bin/env python3
"""从 chinese-days@1.5.9 导入节假日数据,生成 data/holidays.json。

用法:
    python scripts/import_holidays.py [--data-version 2026.10.01]

只使用 chinese-days 包里随包发布的两个文件:
  - dist/chinese-days.json    按日期逐天列出放假日与补班日
  - src/holidays/generate.ts  每年一段注释,里面有国务院通知的出处链接
生成后会把区间重新展开,与来源逐日比对,并检查数据不变量,有任何不一致都会失败。

这个脚本记录的是数据的来历。以后每年的更新是直接编辑 data/holidays.json(见设计文档 §5.3.4),
不需要再运行它。
"""
import datetime as dt
import json
import os
import re
import sys

from gencommon import chinese_days_dir, write_sectioned_json

DEFAULT_DATA_VERSION = "2026.10.01"

# 对 chinese-days 给出的出处链接不满意时(例如不是一手来源),在这里按年份覆盖。
SOURCE_OVERRIDES = {}


def zh_name(value):
    parts = value.split(",")
    assert len(parts) == 3, value  # 「英文名,中文名,序号」
    return parts[1]


def load_days(pkg):
    with open(os.path.join(pkg, "dist", "chinese-days.json"), encoding="utf-8") as f:
        raw = json.load(f)
    holidays = {k: zh_name(v) for k, v in raw["holidays"].items()}
    workdays = {k: zh_name(v) for k, v in raw["workdays"].items()}
    return holidays, workdays


def load_sources(pkg):
    """每个年份块之前最近一段注释里的第一个链接。"""
    with open(os.path.join(pkg, "src", "holidays", "generate.ts"), encoding="utf-8") as f:
        text = f.read()
    result = {}
    for m in re.finditer(r"\.y\((\d{4})\)", text):
        year = int(m.group(1))
        head = text[max(0, m.start() - 6000) : m.start()]
        start = head.rfind("/**")
        url = re.search(r"https?://\S+", head[start:] if start >= 0 else "")
        assert url, "找不到 %d 年的出处链接" % year
        result[year] = url.group(0)
    result.update(SOURCE_OVERRIDES)
    return result


def to_ranges(holidays):
    """把逐日的放假日合并成「同名且连续」的区间。"""
    one = dt.timedelta(days=1)
    ranges = []
    for d in sorted(dt.date.fromisoformat(k) for k in holidays):
        name = holidays[d.isoformat()]
        if ranges and ranges[-1][0] == name and ranges[-1][2] + one == d:
            ranges[-1][2] = d
        else:
            ranges.append([name, d, d])
    return [
        {"name": n, "from": a.isoformat(), "to": b.isoformat()} for (n, a, b) in ranges
    ]


def expand(doc):
    hol = {}
    for r in doc["holidays"]:
        d = dt.date.fromisoformat(r["from"])
        end = dt.date.fromisoformat(r["to"])
        while d <= end:
            assert d.isoformat() not in hol, "区间重叠 " + d.isoformat()
            hol[d.isoformat()] = r["name"]
            d += dt.timedelta(days=1)
    wrk = {}
    for w in doc["workdays"]:
        assert w["date"] not in wrk, "补班日重复 " + w["date"]
        wrk[w["date"]] = w["name"]
    return hol, wrk


def build(data_version):
    pkg = chinese_days_dir()
    holidays, workdays = load_days(pkg)
    sources = load_sources(pkg)
    years = sorted(sources)
    assert years == list(range(years[0], years[-1] + 1)), "出处链接的年份不连续"
    doc = {
        "schema_version": 1,
        "data_version": data_version,
        "coverage": {"from": "%d-01-01" % years[0], "through": "%d-12-31" % years[-1]},
        "sources": [{"year": y, "url": sources[y]} for y in years],
        "holidays": to_ranges(holidays),
        "workdays": [
            {"name": workdays[k], "date": k} for k in sorted(workdays)
        ],
    }
    verify(doc, holidays, workdays)
    return doc


def verify(doc, holidays, workdays):
    # 1. 区间展开后与来源逐日一致
    hol, wrk = expand(doc)
    assert hol == holidays, "放假日与来源不一致"
    assert wrk == workdays, "补班日与来源不一致"
    # 2. 数据不变量(与 holiday 包的加载校验一致)
    first = dt.date.fromisoformat(doc["coverage"]["from"])
    last = dt.date.fromisoformat(doc["coverage"]["through"])
    for k in wrk:
        d = dt.date.fromisoformat(k)
        assert d.weekday() >= 5, "补班日不是周末: " + k
        assert k not in hol, "补班日在放假区间内: " + k
        assert first <= d <= last, "补班日越出覆盖范围: " + k
    prev_to = first - dt.timedelta(days=1)
    for r in doc["holidays"]:
        a = dt.date.fromisoformat(r["from"])
        b = dt.date.fromisoformat(r["to"])
        assert prev_to < a <= b <= last, "放假区间次序或范围不对: %r" % (r,)
        assert r["name"], "名称为空"
        prev_to = b
    # 3. 覆盖范围内的每个年份都有出处
    assert {s["year"] for s in doc["sources"]} == set(range(first.year, last.year + 1))


def main(argv):
    data_version = DEFAULT_DATA_VERSION
    if "--data-version" in argv:
        data_version = argv[argv.index("--data-version") + 1]
    doc = build(data_version)
    write_sectioned_json(
        "data/holidays.json",
        [
            ("schema_version", doc["schema_version"]),
            ("data_version", doc["data_version"]),
            ("coverage", doc["coverage"]),
            ("sources", doc["sources"]),
            ("holidays", doc["holidays"]),
            ("workdays", doc["workdays"]),
        ],
    )
    names = sorted({r["name"] for r in doc["holidays"]})
    print(
        "data/holidays.json:",
        len(doc["holidays"]), "个放假区间,",
        len(doc["workdays"]), "个补班日,",
        "覆盖", doc["coverage"]["from"], "至", doc["coverage"]["through"],
    )
    print("节日名称:", "、".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **步骤 3:运行导入脚本并检查结果**

```bash
cd /d/moonbitsource && export PYTHONUTF8=1
python scripts/import_holidays.py
sha256sum data/holidays.json > "$TEMP/holidays.sha" && python scripts/import_holidays.py >/dev/null && sha256sum -c "$TEMP/holidays.sha"
wc -l data/holidays.json && head -8 data/holidays.json | cut -c1-160 && grep -c '"year"' data/holidays.json
```
预期:
- 没有 `AssertionError`(脚本在写文件前已经把区间展开,与 chinese-days 的 619 个放假日、150 个补班日逐日比对,并检查了补班日必须是周末、不与放假区间重叠、区间有序、每个年份有出处);
- 输出形如 `data/holidays.json: …个放假区间, 150 个补班日, 覆盖 2004-01-01 至 2026-12-31`,并列出节日名称(应当是元旦、春节、清明、劳动节、端午、国庆节、中秋,以及抗战胜利纪念日那一条的长名称);
- `sha256sum -c` 输出 `OK`;
- `grep -c '"year"'` 输出 `23`(23 个年份各一条出处)。

- [ ] **步骤 4:尝试为 2004、2005 年补充一手出处**

chinese-days 给出的 2005 年出处是百度知道、2004 年是维基文库,都不是一手来源。用 WebSearch 查找「国务院办公厅关于2005年部分节假日安排的通知」「国务院办公厅关于2004年部分节假日安排的通知」在 `gov.cn`(或 `www.gov.cn`)上的页面;用 WebFetch 打开候选链接,确认标题和日期与 `data/holidays.json` 里该年的条目一致后,把链接写进 `scripts/import_holidays.py` 的 `SOURCE_OVERRIDES`,例如:
```python
SOURCE_OVERRIDES = {
    2005: "https://www.gov.cn/…",
}
```
然后重新运行 `python scripts/import_holidays.py`。找不到一手链接时保持 `SOURCE_OVERRIDES` 为空,并在步骤 6 的核对记录里写明「2004、2005 年出处不是一手来源」。

- [ ] **步骤 5:对照国务院通知原文,核对 2024、2025、2026 三年**

先打印数据文件里这三年的条目:
```bash
cd /d/moonbitsource && PYTHONUTF8=1 python - <<'PY'
import json
d = json.load(open("data/holidays.json", encoding="utf-8"))
for y in ("2024", "2025", "2026"):
    print(y, "放假:", [(h["name"], h["from"], h["to"]) for h in d["holidays"] if h["from"].startswith(y)])
    print(y, "补班:", [(w["name"], w["date"]) for w in d["workdays"] if w["date"].startswith(y)])
    print(y, "出处:", [s["url"] for s in d["sources"] if s["year"] == int(y)])
PY
```
然后用 WebFetch 逐个打开通知原文(链接就是上面打印的出处),提示词用:「这是国务院办公厅关于部分节假日安排的通知。请逐条列出:发文字号、发布日期,每个节日的放假起止日期与天数、需要上班的日期。保持原文中的日期,不要推算。」

- 2026:https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm(发文字号已核实为「国办发明电〔2025〕7号」,2025-11-04 发布)
- 2025:https://www.gov.cn/zhengce/zhengceku/202411/content_6986383.htm
- 2024:https://www.gov.cn/zhengce/content/202310/content_6911527.htm

把原文中的每一条放假区间、每一个补班日,与数据文件里对应年份的条目逐条对照。特别注意:春节的起止、国庆与中秋合并时的区间划分(2025 年国庆与中秋合并放假,数据里 10 月 6 日的名称是否为中秋)、跨年的补班日(例如 2025-01-26 属于 2025 年春节安排,2026-01-04 属于 2026 年元旦安排)。**发现任何不一致,不要改动判定逻辑,而是改正 `data/holidays.json` 里的数据并记录下来。**

- [ ] **步骤 6:写核对记录 `docs/data-verification.md`**

按实际核对结果填写,保持下面的结构。「结果」一列要写明逐条核对的结论(一致,或列出不一致的条目及处理);不能留空。

```markdown
# 节假日数据核对记录

`data/holidays.json` 的初始数据由 chinese-days@1.5.9 导入(见 `scripts/import_holidays.py`)。
差分测试证明的是:本项目的加载、展开、校验与判定逻辑与 chinese-days 的结果一致;
它不能证明数据本身与国务院通知一致。所以对最近三年的数据对照通知原文做了人工核对。

| 年份 | 通知 | 核对结果 |
|---|---|---|
| 2026 | 国办发明电〔2025〕7号(2025-11-04 发布)<br>https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm | (逐条填写) |
| 2025 | (填写发文字号与发布日期)<br>https://www.gov.cn/zhengce/zhengceku/202411/content_6986383.htm | (逐条填写) |
| 2024 | (填写发文字号与发布日期)<br>https://www.gov.cn/zhengce/content/202310/content_6911527.htm | (逐条填写) |

核对日期:2026-10-01。

## 已知限制

- 其余年份的数据未逐年对照原文,以 chinese-days 的数据为准。
- 2004、2005 年的出处(填写最终采用的链接是否为一手来源)。
- 次年的通知常常调整上一年最后几天的安排;最新覆盖年份(2026)的年末几天,在 2027 年的通知发布后可能变化。
```

- [ ] **步骤 7:检查与提交**

```bash
cd /d/moonbitsource && moon fmt && moon info && moon check 2>&1 | grep -E "^Error"; for t in js wasm-gc native; do echo "== $t"; moon test --target $t 2>&1 | grep -E "Total tests|rror|FAIL"; done
git add -A && git status --short && git commit -q -F - <<'EOF'
feat(data): 从 chinese-days 导入 2004–2026 年节假日数据并核对国务院通知原文

- scripts/import_holidays.py:读取 chinese-days@1.5.9 随包发布的逐日数据,合并成
  「同名且连续」的放假区间,补班日逐日记录;写文件前把区间展开与来源逐日比对,
  并检查补班日必须是周末、不与放假区间重叠、区间有序、每个年份都有出处
- data/holidays.json:23 个年份的出处链接、放假区间、补班日;覆盖 2004-01-01 至 2026-12-31
- docs/data-verification.md:2024–2026 三年对照国务院通知原文的核对记录
  (差分测试只能证明代码与数据的读取一致,数据真伪靠这份核对)

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git log --oneline | head -3
```
预期:三个后端的测试数量与任务 5 结束时相同(`Total tests: 21, passed: 21, failed: 0.`)。

---

### Task 7:`holiday` 包:加载、校验与查询

**文件:**
- 创建:`holiday/moon.pkg`、`holiday/holiday.mbt`、`holiday/loader.mbt`、`holiday/holiday_test.mbt`、`holiday/loader_wbtest.mbt`
- 创建(生成):`holiday/data_gen.mbt`、`holiday/holiday_daily_test.mbt`、`testdata/holiday_daily.json`
- 创建:`scripts/cd_query.js`
- 修改:`scripts/gencommon.py`(追加 `node_query`)、`scripts/gen_expected.py`(加入 `holiday`)、`scripts/embed_data.py`(追加两个 `EMBEDS` 条目)

**接口:**
- 消费:任务 2 的 `@date.*`、`@jsonx.*`;任务 6 的 `data/holidays.json`、`gencommon.chinese_days_dir`
- 产出(任务 8、9 依赖):
  - `DayKind`:`pub(all) enum`,变体 `Workday`、`Weekend`、`Holiday(String)`、`MakeupWorkday(String)`;`derive(Eq, Debug)`
  - `DataInfo`:`pub struct`,字段 `schema_version : Int`、`data_version : String`、`from : @date.Date`、`through : @date.Date`;`derive(Eq, Debug)`
  - `day_kind(d : @date.Date) -> DayKind raise @date.CalendarError`(覆盖范围外报 `DataNotCovered(d, info.from, info.through)`)
  - `is_holiday(d) -> Bool`、`is_makeup_workday(d) -> Bool`、`holiday_name(d) -> String?`(`Holiday` 与 `MakeupWorkday` 都返回节日名),都 `raise @date.CalendarError`
  - `data_info() -> DataInfo raise @date.CalendarError`
  - 包内私有:`parse_table(raw : String) -> Table raise @date.CalendarError`(供白盒测试)、`holidays_json`(嵌入的原始 JSON)
  - `testdata/holiday_daily.json`:`{"meta":…, "from":"2004-01-01", "through":"2026-12-31", "years":[{"y":年,"k":"该年每一天的类型字符串(W 工作日 / E 周末 / H 放假日 / M 补班日)","n":{"YYYY-MM-DD":"节日名"}} …]}`
  - `scripts/cd_query.js` 与 `gencommon.node_query(pkg, request) -> dict`(请求可含 `daily`、`add`、`between` 三种查询,见步骤 1)

- [ ] **步骤 1:写 `scripts/cd_query.js` 与 `node_query`**

`scripts/cd_query.js`:
```javascript
// 通过真实的 chinese-days 包回答查询。
// 用法:node scripts/cd_query.js <包目录> < 请求.json > 响应.json
// 请求(都是可选的):
//   daily:   ["YYYY-MM-DD", …]          → [[日期, isWorkday(0/1), getDayDetail().work(0/1), getDayDetail().name], …]
//   add:     [["YYYY-MM-DD", n], …]     → findWorkday(n, 日期) 的结果日期
//   between: [["YYYY-MM-DD","YYYY-MM-DD"], …] → getWorkdaysInRange(起, 止) 的天数(两端都含)
const path = require("path");
const cd = require(path.resolve(process.argv[2]));
const api = cd.getDayDetail ? cd : cd.default;

const chunks = [];
process.stdin.on("data", (c) => chunks.push(c));
process.stdin.on("end", () => {
  const req = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  const res = {};
  if (req.daily) {
    res.daily = req.daily.map((d) => {
      const detail = api.getDayDetail(d);
      return [d, api.isWorkday(d) ? 1 : 0, detail.work ? 1 : 0, detail.name];
    });
  }
  if (req.add) {
    res.add = req.add.map(([d, n]) => api.findWorkday(n, d));
  }
  if (req.between) {
    res.between = req.between.map(([a, b]) => api.getWorkdaysInRange(a, b).length);
  }
  process.stdout.write(JSON.stringify(res));
});
```

在 `scripts/gencommon.py` 末尾追加:
```python


def node_query(pkg, request):
    """把请求交给 scripts/cd_query.js,由真实的 chinese-days 包回答。"""
    node = shutil.which("node")
    if not node:
        raise SystemExit("需要 Node.js")
    script = os.path.join(ROOT, "scripts", "cd_query.js")
    proc = subprocess.run(
        [node, script, pkg],
        input=json.dumps(request),
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    )
    return json.loads(proc.stdout)
```

- [ ] **步骤 2:在 `scripts/gen_expected.py` 中加入 `holiday` 生成器**

(a) 把 `from gencommon import …` 一行改成:
```python
from gencommon import (
    LUNAR_PYTHON_VERSION,
    CHINESE_DAYS_VERSION,
    chinese_days_dir,
    node_query,
    require_lunar_python,
    write_sectioned_json,
)
```
并在导入区加入 `import json`、`import os`。

(b) 在 `GENERATORS = {` 之前插入:
```python
@functools.lru_cache(maxsize=None)
def chinese_days_daily():
    """chinese-days 覆盖范围内每一天的类型、节日名与 isWorkday。

    类型与节日名取自包内的 dist/chinese-days.json,并与真实 API(isWorkday、getDayDetail)
    逐日交叉核对,不一致就失败。返回 (起, 止, 日期列表, 类型, 节日名, 是否工作日)。
    类型字符:W 普通工作日,E 普通周末,H 放假日,M 调休补班日。
    """
    pkg = chinese_days_dir()
    with open(os.path.join(pkg, "dist", "chinese-days.json"), encoding="utf-8") as f:
        raw = json.load(f)
    zh = lambda v: v.split(",")[1]
    hol = {k: zh(v) for k, v in raw["holidays"].items()}
    wrk = {k: zh(v) for k, v in raw["workdays"].items()}
    years = sorted({int(k[:4]) for k in list(hol) + list(wrk)})
    first, last = dt.date(years[0], 1, 1), dt.date(years[-1], 12, 31)
    days = [first + dt.timedelta(days=i) for i in range((last - first).days + 1)]
    answers = node_query(pkg, {"daily": [d.isoformat() for d in days]})["daily"]
    kinds, names, flags = {}, {}, {}
    for d, (iso, is_workday, work, _name) in zip(days, answers):
        assert iso == d.isoformat()
        if iso in wrk:
            kind, names[iso] = "M", wrk[iso]
        elif iso in hol:
            kind, names[iso] = "H", hol[iso]
        else:
            kind = "W" if d.weekday() < 5 else "E"
        expected_work = kind in ("W", "M")
        assert bool(is_workday) == expected_work and bool(work) == expected_work, (iso, kind, is_workday, work)
        kinds[iso] = kind
        flags[iso] = 1 if expected_work else 0
    return first, last, days, kinds, names, flags


def cd_meta(extra=None):
    meta = {
        "generator": "scripts/gen_expected.py",
        "reference": "chinese-days@%s(真实 npm 包,经 Node 调用 isWorkday / getDayDetail / findWorkday / getWorkdaysInRange)"
        % CHINESE_DAYS_VERSION,
        "seed": SEED,
    }
    if extra:
        meta.update(extra)
    return meta


def gen_holiday():
    first, last, days, kinds, names, _flags = chinese_days_daily()
    years = []
    for y in range(first.year, last.year + 1):
        ds = [d.isoformat() for d in days if d.year == y]
        years.append(
            {
                "y": y,
                "k": "".join(kinds[iso] for iso in ds),
                "n": {iso: names[iso] for iso in ds if iso in names},
            }
        )
    write_sectioned_json(
        "testdata/holiday_daily.json",
        [
            ("meta", cd_meta({"kinds": "W 工作日 / E 周末 / H 放假日 / M 调休补班日"})),
            ("from", first.isoformat()),
            ("through", last.isoformat()),
            ("years", years),
        ],
    )
    print("testdata/holiday_daily.json:", len(days), "天,", len(years), "个年份")
```

(c) 把 `GENERATORS` 改成:
```python
GENERATORS = {
    "date": gen_date,
    "lunar": gen_lunar,
    "terms": gen_terms,
    "holiday": gen_holiday,
}
```

- [ ] **步骤 3:在 `scripts/embed_data.py` 的 `EMBEDS` 里追加两项**

```python
    ("data/holidays.json", "holiday/data_gen.mbt", "holidays_json"),
    ("testdata/holiday_daily.json", "holiday/holiday_daily_test.mbt", "holiday_daily_json"),
```

- [ ] **步骤 4:生成预期数据并嵌入,检查可重复性**

```bash
cd /d/moonbitsource && export PYTHONUTF8=1
mkdir -p holiday && cat > holiday/moon.pkg <<'EOF'
warnings = "-implicit_impl_as_method"

import {
  "sayoi7799/cncal/date",
  "sayoi7799/cncal/internal/jsonx",
  "moonbitlang/core/lazy",
}
EOF
python scripts/gen_expected.py holiday
sha256sum testdata/holiday_daily.json > "$TEMP/hd.sha" && python scripts/gen_expected.py holiday >/dev/null && sha256sum -c "$TEMP/hd.sha"
python scripts/embed_data.py
wc -l testdata/holiday_daily.json holiday/data_gen.mbt holiday/holiday_daily_test.mbt
```
预期:`testdata/holiday_daily.json: 8401 天, 23 个年份`(2004-01-01 至 2026-12-31 共 8401 天);`sha256sum -c` 输出 `OK`(这一步也证明脚本里的交叉核对通过:包内数据与真实 API 对每一天都一致);嵌入文件行数都很少(几十到几百行)。

- [ ] **步骤 5:写测试(此时实现还不存在,会编译失败)**

`holiday/holiday_test.mbt`:
```moonbit
///|
fn expect_not_covered(
  f : () -> Unit raise @date.CalendarError,
  d : @date.Date,
  info : @holiday.DataInfo,
) -> Unit raise {
  try f() catch {
    @date.DataNotCovered(requested, from, through) => {
      assert_eq(requested, d)
      assert_eq(from, info.from)
      assert_eq(through, info.through)
    }
    e => fail("\{d}: 期望 DataNotCovered,实际 \{e}")
  } noraise {
    _ => fail("\{d}: 期望 DataNotCovered,但没有出错")
  }
}

///|
test "覆盖范围内每一天的类型与节日名和 chinese-days 一致" {
  let root = @jsonx.parse(holiday_daily_json)
  let expected_from = @date.Date::from_iso(
    @jsonx.as_string(@jsonx.field(root, "from")),
  )
  let expected_through = @date.Date::from_iso(
    @jsonx.as_string(@jsonx.field(root, "through")),
  )
  let info = @holiday.data_info()
  // 本项目的覆盖范围不能小于 chinese-days 的
  assert_true(info.from <= expected_from, msg="覆盖起点 \{info.from}")
  assert_true(info.through >= expected_through, msg="覆盖终点 \{info.through}")
  let mut checked = 0
  let mut makeup_saturdays = 0
  let mut makeup_sundays = 0
  for rec in @jsonx.as_array(@jsonx.field(root, "years")) {
    let year = @jsonx.as_int(@jsonx.field(rec, "y"))
    let kinds = @jsonx.as_string(@jsonx.field(rec, "k"))
    let names = @jsonx.as_object(@jsonx.field(rec, "n"))
    let mut d = @date.Date::new(year, 1, 1)
    for i in 0..<kinds.length() {
      let key = "\{d}"
      let kind = @holiday.day_kind(d)
      if kinds[i] == 'M' {
        // 调休补班日只会出现在周六或周日
        match d.weekday() {
          @date.Saturday => makeup_saturdays += 1
          @date.Sunday => makeup_sundays += 1
          _ => fail("补班日不是周末: \{key}")
        }
      }
      let name = match names.get(key) {
        Some(j) => @jsonx.as_string(j)
        None => ""
      }
      let c = kinds[i]
      match c {
        'W' => assert_eq(kind, @holiday.Workday, msg=key)
        'E' => assert_eq(kind, @holiday.Weekend, msg=key)
        'H' => assert_eq(kind, @holiday.Holiday(name), msg=key)
        'M' => assert_eq(kind, @holiday.MakeupWorkday(name), msg=key)
        _ => fail("未知的类型字符 \{c}")
      }
      assert_eq(@holiday.is_holiday(d), c == 'H', msg="is_holiday \{key}")
      assert_eq(
        @holiday.is_makeup_workday(d),
        c == 'M',
        msg="is_makeup_workday \{key}",
      )
      assert_eq(
        @holiday.holiday_name(d),
        if name == "" {
          None
        } else {
          Some(name)
        },
        msg="holiday_name \{key}",
      )
      checked += 1
      d = d.add_days(1)
    }
    assert_eq(d, @date.Date::new(year + 1, 1, 1), msg="\{year} 年的天数")
  }
  assert_eq(checked, expected_from.days_between(expected_through) + 1)
  // 周六的补班日和周日的补班日各自都出现过
  assert_true(makeup_saturdays > 0 && makeup_sundays > 0)
}

///|
test "数据版本信息" {
  let info = @holiday.data_info()
  assert_eq(info.schema_version, 1)
  assert_true(info.from < info.through)
  assert_true(info.data_version != "")
}

///|
test "审查重点:覆盖范围边界日的行为,错误里带着请求日期与覆盖范围" {
  let info = @holiday.data_info()
  // 边界当天可以查询
  ignore(@holiday.day_kind(info.from))
  ignore(@holiday.day_kind(info.through))
  // 紧邻覆盖范围的前一天、后一天,以及远处的日期,所有接口都报 DataNotCovered
  let before = info.from.add_days(-1)
  let after = info.through.add_days(1)
  for d in [before, after, @date.Date::new(1, 1, 1), @date.Date::new(9999, 12, 31)] {
    expect_not_covered(() => ignore(@holiday.day_kind(d)), d, info)
    expect_not_covered(() => ignore(@holiday.is_holiday(d)), d, info)
    expect_not_covered(() => ignore(@holiday.is_makeup_workday(d)), d, info)
    expect_not_covered(() => ignore(@holiday.holiday_name(d)), d, info)
  }
}
```

`holiday/loader_wbtest.mbt`:
```moonbit
///|
fn doc(
  version : Int,
  from : String,
  through : String,
  holidays : String,
  workdays : String,
) -> String {
  "{\"schema_version\":\{version},\"data_version\":\"t\",\"coverage\":{\"from\":\"\{from}\",\"through\":\"\{through}\"},\"sources\":[],\"holidays\":[\{holidays}],\"workdays\":[\{workdays}]}"
}

///|
fn hol(name : String, from : String, to : String) -> String {
  "{\"name\":\"\{name}\",\"from\":\"\{from}\",\"to\":\"\{to}\"}"
}

///|
fn wk(name : String, date : String) -> String {
  "{\"name\":\"\{name}\",\"date\":\"\{date}\"}"
}

///|
fn expect_corrupt(raw : String, what : String) -> Unit raise {
  try parse_table(raw) catch {
    @date.DataCorrupt(_) => ()
    e => fail("\{what}: 期望 DataCorrupt,实际 \{e}")
  } noraise {
    _ => fail("\{what}: 期望 DataCorrupt,但加载成功了")
  }
}

///|
test "合法的最小文档可以加载" {
  let raw = doc(
    1,
    "2026-01-01",
    "2026-12-31",
    hol("元旦", "2026-01-01", "2026-01-03"),
    wk("元旦", "2026-01-04"),
  )
  let t = parse_table(raw)
  assert_eq(t.info.from, @date.Date::new(2026, 1, 1))
  assert_eq(t.info.through, @date.Date::new(2026, 12, 31))
  assert_eq(t.days.length(), 4) // 3 个放假日 + 1 个补班日
  assert_eq(
    t.days.get(@date.Date::new(2026, 1, 3).to_days()),
    Some(Holiday("元旦")),
  )
  assert_eq(
    t.days.get(@date.Date::new(2026, 1, 4).to_days()),
    Some(MakeupWorkday("元旦")),
  )
  assert_eq(t.days.get(@date.Date::new(2026, 1, 5).to_days()), None)
}

///|
test "审查重点:损坏的数据一律返回 DataCorrupt,不会静默加载" {
  let a = "2026-01-01"
  let z = "2026-12-31"
  let h = hol("元旦", "2026-01-01", "2026-01-03")
  let w = wk("元旦", "2026-01-04")
  expect_corrupt(doc(2, a, z, h, w), "schema_version 不是 1")
  expect_corrupt(doc(1, z, a, h, w), "coverage 起止颠倒")
  expect_corrupt(doc(1, a, z, hol("元旦", "2026-01-03", "2026-01-01"), w), "放假区间起止颠倒")
  expect_corrupt(
    doc(1, a, z, h + "," + hol("春节", "2026-01-03", "2026-01-05"), w),
    "放假区间重叠",
  )
  expect_corrupt(
    doc(1, a, z, hol("春节", "2026-02-01", "2026-02-03") + "," + h, w),
    "放假区间未按日期升序",
  )
  expect_corrupt(
    doc(1, a, z, hol("元旦", "2025-12-31", "2026-01-01"), w),
    "放假区间超出 coverage",
  )
  expect_corrupt(doc(1, a, z, h, wk("元旦", "2026-01-07")), "补班日是星期三")
  expect_corrupt(doc(1, a, z, h, wk("元旦", "2026-01-03")), "补班日落在放假区间内")
  expect_corrupt(doc(1, a, z, h, w + "," + w), "补班日重复")
  expect_corrupt(doc(1, a, z, h, wk("元旦", "2027-01-03")), "补班日超出 coverage")
  expect_corrupt(doc(1, a, z, hol("", "2026-01-01", "2026-01-03"), w), "节日名称为空")
  expect_corrupt(doc(1, a, z, h, wk("", "2026-01-04")), "补班日名称为空")
  expect_corrupt(doc(1, a, z, hol("元旦", "2026-02-30", "2026-03-01"), w), "日期不存在")
  expect_corrupt(doc(1, a, z, hol("元旦", "2026-1-1", "2026-01-03"), w), "日期格式不对")
  expect_corrupt("not json", "不是 JSON")
  expect_corrupt("{}", "缺少字段")
  expect_corrupt("{\"schema_version\":1}", "缺少 data_version 等字段")
  expect_corrupt("[1,2,3]", "根不是对象")
}
```

- [ ] **步骤 6:运行测试,确认失败**

```bash
cd /d/moonbitsource && moon check 2>&1 | grep -E "^Error" | head -5
```
预期:编译错误,指出 `parse_table`、`@holiday.day_kind`、`@holiday.DataInfo` 等未定义。

- [ ] **步骤 7:实现 `holiday/holiday.mbt` 与 `holiday/loader.mbt`**

`holiday/holiday.mbt`:
```moonbit
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
    None =>
      if d.weekday().is_weekend() {
        Weekend
      } else {
        Workday
      }
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
```

`holiday/loader.mbt`:
```moonbit
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
      raise @date.DataCorrupt("放假区间未按日期升序排列或发生重叠: \{name}")
    }
    if a < from_days || b > through_days {
      raise @date.DataCorrupt("放假区间超出 coverage: \{name}")
    }
    for n in a..=b {
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
    if not(date.weekday().is_weekend()) {
      raise @date.DataCorrupt("补班日必须是周六或周日: \{date}")
    }
    if days.contains(n) {
      raise @date.DataCorrupt("补班日与放假日或其他补班日重复: \{date}")
    }
    days[n] = MakeupWorkday(name)
  }
  {
    info: { schema_version: version, data_version, from, through },
    from_days,
    through_days,
    days,
  }
}
```

- [ ] **步骤 8:运行测试,确认通过**

```bash
cd /d/moonbitsource && moon fmt && moon info && moon check 2>&1 | grep -E "^Error"; for t in js wasm-gc native; do echo "== $t"; moon test --target $t 2>&1 | grep -E "Total tests|rror|FAIL"; done
python scripts/embed_data.py --check
```
预期:三个后端都输出 `Total tests: 26, passed: 26, failed: 0.`(之前的 21 个 + 本任务的 3 个黑盒 + 2 个白盒);`--check` 输出「嵌入文件全部是最新的」。

如果逐日比对失败,`msg=` 里有日期。先判断是加载器展开错了,还是预期数据有问题:预期来自真实的 chinese-days 包,以它为准。

- [ ] **步骤 9:提交**

```bash
cd /d/moonbitsource && git add -A && git commit -q -F - <<'EOF'
feat(holiday): 添加节假日数据加载、校验与查询,覆盖范围外报 DataNotCovered

- 数据与逻辑分离:data/holidays.json 是唯一数据源,构建时用 moon tool embed 嵌入,
  js / wasm-gc / native 读到同一份字节;首次使用时才解析并缓存
- 加载时校验不变量:schema_version、区间起止与顺序、不重叠、都在覆盖范围内;
  补班日必须是周六日、不在放假区间内、不重复;名称非空;日期合法。
  任何问题都返回 DataCorrupt,不会静默加载
- day_kind / is_holiday / is_makeup_workday / holiday_name / data_info;
  日期不在覆盖范围内一律 DataNotCovered(带请求日期与已覆盖范围),不会当成普通周末
- scripts/cd_query.js 调用真实的 chinese-days 包生成 8401 天的逐日预期值
  (类型字符 + 节日名),并与包内数据交叉核对
- 测试:2004-01-01 ~ 2026-12-31 逐日比对;覆盖范围边界日;18 种损坏数据均返回 DataCorrupt

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git log --oneline | head -3
```

- [ ] **步骤 10:向用户讲解 `holiday` 的核心逻辑(3–5 句)**

1. 数据与逻辑分离:唯一的数据源是一个 JSON 文件,放假通知里的区间原样记录,每年更新只追加数据,不改代码。
2. 构建时用 `moon tool embed` 把 JSON 变成字符串常量,所以 js、wasm-gc、native 读到的是同一份字节,不依赖任何文件系统。
3. 加载时把区间展开成「日期 → (放假日或补班日, 节日名)」的映射,并做一遍不变量校验(补班日必须是周末、不与放假区间重叠等),手工录入时的日期笔误会立刻被拦住。
4. 查询时先检查日期是否在覆盖范围内,不在就报错并带上已覆盖的范围,而不是默认当作周末;范围内没有记录的日子,才按周一到周五是工作日、周六日是周末处理。
5. 覆盖范围用日期区间而不是年份列表来表达,是因为次年通知常常会修改上一年最后几天的安排。

---

### Task 8:`workday` 包:工作日计算

**文件:**
- 创建:`workday/moon.pkg`、`workday/workday.mbt`、`workday/workday_test.mbt`
- 创建(生成):`workday/workday_cases_test.mbt`、`testdata/workday_cases.json`
- 修改:`scripts/gen_expected.py`(加入 `workday`)、`scripts/embed_data.py`(追加一个 `EMBEDS` 条目)

**接口:**
- 消费:任务 7 的 `@holiday.day_kind`、`@holiday.DayKind`(`Workday`、`Weekend`、`Holiday(String)`、`MakeupWorkday(String)`)、`@holiday.data_info`;任务 2 的 `@date.*`;任务 7 的 `gen_expected.chinese_days_daily`、`gencommon.node_query`
- 产出(任务 9 依赖):
  - `is_workday(d : @date.Date) -> Bool raise @date.CalendarError`
  - `add_workdays(d : @date.Date, n : Int) -> @date.Date raise @date.CalendarError`
  - `workdays_between(a : @date.Date, b : @date.Date) -> Int raise @date.CalendarError`
  - `testdata/workday_cases.json`:`{"meta":…, "from":…, "through":…, "add":[{"from":"YYYY-MM-DD","n":Int,"to":"YYYY-MM-DD","src":"cd"或"ref"} …], "between":[{"a":…,"b":…,"count":Int} …], "examples_add":[{"from":…,"n":…,"to":…} …], "examples_between":[{"a":…,"b":…,"count":…} …], "flags":[{"y":年,"f":"该年每天是否工作日的 1/0 字符串"} …]}`;`src` 为 `cd` 表示预期值来自真实 chinese-days 的 `findWorkday`,为 `ref` 表示来自 Python 暴力参考实现(`n = 0` 且起算日不是工作日,chinese-days 与本设计的语义不同,见设计文档 §5.4.4)

- [ ] **步骤 1:在 `scripts/gen_expected.py` 中加入 `workday` 生成器**

(a) 在 `GENERATORS = {` 之前插入:
```python
def ref_add(flags, first, last, start, n):
    """按设计文档 §5.4.1 的定义暴力计算 add_workdays;路径越出 [first, last] 返回 None。"""
    if n == 0:
        return start
    step = 1 if n > 0 else -1
    delta = dt.timedelta(days=step)
    remaining, cur = n, start
    while remaining != 0:
        cur += delta
        if cur < first or cur > last:
            return None
        if flags[cur.isoformat()]:
            remaining -= step
    return cur


def ref_between(flags, a, b):
    """[a, b) 内的工作日个数;a > b 时取相反数。a、b 必须在覆盖范围内。"""
    if a > b:
        return -ref_between(flags, b, a)
    return sum(flags[(a + dt.timedelta(days=i)).isoformat()] for i in range((b - a).days))


def gen_workday():
    pkg = chinese_days_dir()
    first, last, days, _kinds, _names, flags = chinese_days_daily()
    rng = random.Random(SEED)
    one = dt.timedelta(days=1)

    def is_wd(d):
        return flags[d.isoformat()] == 1

    # 连续 3 天及以上的非工作日区块(春节、国庆、五一……含前后相连的周末)
    runs, i = [], 0
    while i < len(days):
        if not is_wd(days[i]):
            j = i
            while j + 1 < len(days) and not is_wd(days[j + 1]):
                j += 1
            if j - i + 1 >= 3:
                runs.append((days[i], days[j]))
            i = j + 1
        else:
            i += 1

    # ---- add_workdays 用例 ----
    starts = []
    for a, b in runs:
        for s in (a - one, b + one, a, b):
            if first <= s <= last:
                starts.append(s)
    cases = [(s, n) for s in starts for n in (-5, -1, 0, 1, 5)]
    for _ in range(800):
        cases.append((days[rng.randrange(len(days))], rng.randint(-40, 40)))
    cases += [(first, 5000), (last, -5000), (dt.date(2010, 6, 1), 1500), (dt.date(2020, 1, 1), -800)]
    # 去重(保持顺序),并只保留全程都在覆盖范围内的用例
    cases = [c for c in dict.fromkeys(cases) if ref_add(flags, first, last, c[0], c[1]) is not None]

    # 真实 chinese-days 的 findWorkday 能回答:n != 0,或 n == 0 且起算日是工作日
    api_cases = [(s, n) for (s, n) in cases if n != 0 or is_wd(s)]
    answers = node_query(pkg, {"add": [[s.isoformat(), n] for (s, n) in api_cases]})["add"]
    api = dict(zip(api_cases, answers))
    add = []
    for s, n in cases:
        want = ref_add(flags, first, last, s, n).isoformat()
        if (s, n) in api:
            assert api[(s, n)] == want, ("findWorkday 与定义不一致", s, n, api[(s, n)], want)
            src = "cd"
        else:
            src = "ref"  # n == 0 且起算日不是工作日:chinese-days 会顺延,本设计原样返回(§5.4.4)
        add.append({"from": s.isoformat(), "n": n, "to": want, "src": src})

    # ---- workdays_between 用例 ----
    pairs = []
    for a, b in runs:
        for x, y in [(a - one, b + one), (a - one, b), (a, b + one), (a, b)]:
            if first <= x <= last and first <= y <= last:
                pairs += [(x, y), (y, x)]
    for _ in range(800):
        pairs.append((days[rng.randrange(len(days))], days[rng.randrange(len(days))]))
    pairs += [(first, last), (last, first), (first, first), (last, last)]
    pairs = list(dict.fromkeys(pairs))
    # chinese-days 的 getWorkdaysInRange(起, 止) 两端都含;[a, b) 对应 (a, b 的前一天)
    forward = [(x, y) for (x, y) in pairs if x < y]
    counts = node_query(
        pkg, {"between": [[x.isoformat(), (y - one).isoformat()] for (x, y) in forward]}
    )["between"]
    api_between = dict(zip(forward, counts))
    between = []
    for x, y in pairs:
        want = ref_between(flags, x, y)
        if (x, y) in api_between:
            assert api_between[(x, y)] == want, ("getWorkdaysInRange 与定义不一致", x, y)
        between.append({"a": x.isoformat(), "b": y.isoformat(), "count": want})

    # ---- 文档里的示例(设计文档 §5.4.3) ----
    examples_add = []
    for ds, n in [
        ("2026-09-30", 1), ("2026-10-09", 1), ("2026-10-10", 1), ("2026-10-03", 0),
        ("2026-10-03", 1), ("2026-10-03", -1), ("2026-10-08", -2),
    ]:
        want = ref_add(flags, first, last, dt.date.fromisoformat(ds), n)
        assert want is not None, (ds, n)
        examples_add.append({"from": ds, "n": n, "to": want.isoformat()})
    examples_between = []
    for da, db in [("2026-09-30", "2026-10-12"), ("2026-10-12", "2026-09-30")]:
        a, b = dt.date.fromisoformat(da), dt.date.fromisoformat(db)
        examples_between.append({"a": da, "b": db, "count": ref_between(flags, a, b)})

    year_flags = []
    for y in range(first.year, last.year + 1):
        year_flags.append(
            {"y": y, "f": "".join(str(flags[d.isoformat()]) for d in days if d.year == y)}
        )

    write_sectioned_json(
        "testdata/workday_cases.json",
        [
            ("meta", cd_meta({"semantics": "docs/superpowers/specs/2026-10-01-cncal-design.md §5.4.1"})),
            ("from", first.isoformat()),
            ("through", last.isoformat()),
            ("add", add),
            ("between", between),
            ("examples_add", examples_add),
            ("examples_between", examples_between),
            ("flags", year_flags),
        ],
    )
    print(
        "testdata/workday_cases.json:", len(add), "个 add_workdays 用例(其中",
        sum(1 for a in add if a["src"] == "cd"), "个来自 chinese-days),",
        len(between), "个 workdays_between 用例,", len(runs), "个连续非工作日区块",
    )
```

(b) 把 `GENERATORS` 改成:
```python
GENERATORS = {
    "date": gen_date,
    "lunar": gen_lunar,
    "terms": gen_terms,
    "holiday": gen_holiday,
    "workday": gen_workday,
}
```

(c) 在 `scripts/embed_data.py` 的 `EMBEDS` 里追加:
```python
    ("testdata/workday_cases.json", "workday/workday_cases_test.mbt", "workday_cases_json"),
```

- [ ] **步骤 2:生成预期数据并嵌入,检查可重复性**

```bash
cd /d/moonbitsource && export PYTHONUTF8=1
mkdir -p workday && cat > workday/moon.pkg <<'EOF'
warnings = "-implicit_impl_as_method"

import {
  "sayoi7799/cncal/date",
  "sayoi7799/cncal/holiday",
}

import {
  "sayoi7799/cncal/internal/jsonx",
} for "test"
EOF
python scripts/gen_expected.py workday
sha256sum testdata/workday_cases.json > "$TEMP/wd.sha" && python scripts/gen_expected.py workday >/dev/null && sha256sum -c "$TEMP/wd.sha"
python scripts/embed_data.py
wc -l testdata/workday_cases.json workday/workday_cases_test.mbt
```
预期:
- 脚本没有 `AssertionError`——这本身就是一个重要结论:真实 chinese-days 的 `findWorkday`(n ≠ 0 与「n=0 且为工作日」)和 `getWorkdaysInRange` 对几千个用例的结果与设计文档 §5.4.1 的定义完全一致;
- 输出形如 `testdata/workday_cases.json: 数千个 add_workdays 用例(其中…个来自 chinese-days), …个 workdays_between 用例, …个连续非工作日区块`;
- `sha256sum -c` 输出 `OK`;
- 两个文件的行数都远小于 16000(约几千行)。

如果脚本在 `findWorkday 与定义不一致` 处失败,说明设计文档 §5.4.1 的语义与 chinese-days 在这个用例上不同——**停下来,把该用例报告给用户**,不要改定义或改数据来迁就。

- [ ] **步骤 3:写测试 `workday/workday_test.mbt`(此时实现还不存在,会编译失败)**

```moonbit
///|
fn[T : Show] expect_not_covered(
  f : () -> T raise @date.CalendarError,
  what : String,
) -> Unit raise {
  try f() catch {
    @date.DataNotCovered(_, _, _) => ()
    e => fail("\{what}: 期望 DataNotCovered,实际 \{e}")
  } noraise {
    v => fail("\{what}: 期望 DataNotCovered,实际得到 \{v}")
  }
}

///|
/// 覆盖范围内的所有日期(升序)。
fn all_days() -> Array[@date.Date] raise {
  let info = @holiday.data_info()
  let result : Array[@date.Date] = []
  let mut d = info.from
  while d <= info.through {
    result.push(d)
    d = d.add_days(1)
  }
  result
}

///|
/// 结果会跑出覆盖范围时返回 `None`,其余错误照常抛出。
fn try_add(d : @date.Date, n : Int) -> @date.Date? raise {
  try @workday.add_workdays(d, n) catch {
    @date.DataNotCovered(_, _, _) => None
    e => raise e
  } noraise {
    r => Some(r)
  }
}

///|
test "add_workdays 与 chinese-days 的 findWorkday 及设计定义一致" {
  let root = @jsonx.parse(workday_cases_json)
  let adds = @jsonx.as_array(@jsonx.field(root, "add"))
  assert_true(adds.length() > 1000)
  let mut from_cd = 0
  let mut from_ref = 0
  for rec in adds {
    let from = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "from")))
    let n = @jsonx.as_int(@jsonx.field(rec, "n"))
    let to = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "to")))
    match @jsonx.as_string(@jsonx.field(rec, "src")) {
      "cd" => from_cd += 1
      _ => from_ref += 1
    }
    assert_eq(@workday.add_workdays(from, n), to, msg="\{from} + \{n} 个工作日")
  }
  // 两类用例都确实出现过
  assert_true(from_cd > 0 && from_ref > 0)
}

///|
test "workdays_between 与 chinese-days 的 getWorkdaysInRange 及设计定义一致" {
  let root = @jsonx.parse(workday_cases_json)
  let items = @jsonx.as_array(@jsonx.field(root, "between"))
  assert_true(items.length() > 500)
  for rec in items {
    let a = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "a")))
    let b = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "b")))
    let count = @jsonx.as_int(@jsonx.field(rec, "count"))
    assert_eq(@workday.workdays_between(a, b), count, msg="\{a} 到 \{b}")
  }
}

///|
test "is_workday 逐日与 chinese-days 的 isWorkday 一致(含调休补班的周六周日)" {
  let root = @jsonx.parse(workday_cases_json)
  let mut makeup_weekend = 0
  for rec in @jsonx.as_array(@jsonx.field(root, "flags")) {
    let year = @jsonx.as_int(@jsonx.field(rec, "y"))
    let flags = @jsonx.as_string(@jsonx.field(rec, "f"))
    let mut d = @date.Date::new(year, 1, 1)
    for i in 0..<flags.length() {
      let expected = flags[i] == '1'
      assert_eq(@workday.is_workday(d), expected, msg="is_workday \{d}")
      if expected && d.weekday().is_weekend() {
        makeup_weekend += 1
      }
      d = d.add_days(1)
    }
    assert_eq(d, @date.Date::new(year + 1, 1, 1), msg="\{year} 年的天数")
  }
  // 数据里确实有「周末上班」的日子,并且它们都被算作工作日
  assert_true(makeup_weekend > 100)
}

///|
test "文档示例(设计文档 §5.4.3):跨国庆长假、补班日、n=0 与负数" {
  let root = @jsonx.parse(workday_cases_json)
  for rec in @jsonx.as_array(@jsonx.field(root, "examples_add")) {
    let from = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "from")))
    let n = @jsonx.as_int(@jsonx.field(rec, "n"))
    let to = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "to")))
    assert_eq(@workday.add_workdays(from, n), to, msg="示例 \{from} + \{n}")
  }
  for rec in @jsonx.as_array(@jsonx.field(root, "examples_between")) {
    let a = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "a")))
    let b = @date.Date::from_iso(@jsonx.as_string(@jsonx.field(rec, "b")))
    let count = @jsonx.as_int(@jsonx.field(rec, "count"))
    assert_eq(@workday.workdays_between(a, b), count, msg="示例 \{a} 到 \{b}")
  }
}

///|
test "性质 P1 P2:n=0 返回自身;n≠0 的结果一定是工作日" {
  for d in all_days() {
    assert_eq(@workday.add_workdays(d, 0), d, msg="P1 \{d}")
    for n in [-3, -1, 1, 3] {
      match try_add(d, n) {
        Some(r) => assert_true(@workday.is_workday(r), msg="P2 \{d} + \{n} = \{r}")
        None => ()
      }
    }
  }
}

///|
test "性质 P3:add_workdays 随 n 严格递增" {
  let days = all_days()
  let mut i = 0
  while i < days.length() {
    let d = days[i]
    let mut prev : @date.Date? = None
    for n in -4..=4 {
      match try_add(d, n) {
        Some(r) => {
          match prev {
            Some(p) => assert_true(p < r, msg="P3 \{d}: n=\{n} 的结果 \{r} 不大于上一个 \{p}")
            None => ()
          }
          prev = Some(r)
        }
        None => ()
      }
    }
    i += 7
  }
}

///|
test "性质 P4 P5:workdays_between 反对称且可加" {
  let days = all_days()
  let steps = [1, 3, 10, 40]
  let mut i = 0
  while i < days.length() {
    let a = days[i]
    for x in steps {
      if i + x < days.length() {
        let b = days[i + x]
        assert_eq(
          @workday.workdays_between(a, b),
          -@workday.workdays_between(b, a),
          msg="P4 \{a} \{b}",
        )
        for y in steps {
          if i + x + y < days.length() {
            let c = days[i + x + y]
            assert_eq(
              @workday.workdays_between(a, c),
              @workday.workdays_between(a, b) + @workday.workdays_between(b, c),
              msg="P5 \{a} \{b} \{c}",
            )
          }
        }
      }
    }
    assert_eq(@workday.workdays_between(a, a), 0, msg="P4 \{a}")
    i += 11
  }
}

///|
test "性质 P6:workdays_between 与 add_workdays 互为逆运算(起算日是工作日时恒成立)" {
  let days = all_days()
  let mut i = 0
  while i < days.length() {
    let a = days[i]
    for n in [-7, -1, 1, 3, 7, 11] {
      match try_add(a, n) {
        Some(b) => {
          let c = @workday.workdays_between(a, b)
          if @workday.is_workday(a) || n < 0 {
            assert_eq(c, n, msg="P6 \{a} + \{n} = \{b}")
          } else {
            // 起算日不是工作日且向后加:[a, b) 里恰好少算了一个
            assert_eq(c, n - 1, msg="P6 \{a} + \{n} = \{b}")
          }
        }
        None => ()
      }
    }
    i += 5
  }
}

///|
test "审查重点:极端的 n 与覆盖范围边界,add_workdays 返回 DataNotCovered" {
  let info = @holiday.data_info()
  let mid = @date.Date::new(2015, 6, 15)
  // Int 的最大/最小值:走出覆盖范围就报错,不会回绕,也不会死循环
  expect_not_covered(() => @workday.add_workdays(mid, 2147483647), "mid + Int 最大值")
  expect_not_covered(() => @workday.add_workdays(mid, -2147483648), "mid + Int 最小值")
  // 覆盖范围末日再往后一个工作日,首日再往前一个工作日
  try @workday.add_workdays(info.through, 1) catch {
    @date.DataNotCovered(requested, from, through) => {
      assert_eq(requested, info.through.add_days(1))
      assert_eq(from, info.from)
      assert_eq(through, info.through)
    }
    e => fail("期望 DataNotCovered,实际 \{e}")
  } noraise {
    r => fail("期望 DataNotCovered,实际得到 \{r}")
  }
  expect_not_covered(() => @workday.add_workdays(info.from, -1), "首日 - 1")
  // 起算日本身不在覆盖范围内,即使 n = 0 也报错
  expect_not_covered(() => @workday.add_workdays(info.through.add_days(1), 0), "末日后一天 + 0")
  expect_not_covered(() => @workday.add_workdays(info.from.add_days(-1), 0), "首日前一天 + 0")
}

///|
test "审查重点:is_workday 与 workdays_between 在覆盖范围边界上的行为" {
  let info = @holiday.data_info()
  let before = info.from.add_days(-1)
  let after = info.through.add_days(1)
  expect_not_covered(() => @workday.is_workday(before), "首日前一天")
  expect_not_covered(() => @workday.is_workday(after), "末日后一天")
  // 结束日不参与计数([a, b) 不含 b),但也必须在覆盖范围内
  expect_not_covered(() => @workday.workdays_between(info.through, after), "[末日, 末日后一天)")
  expect_not_covered(() => @workday.workdays_between(before, info.from), "[首日前一天, 首日)")
  // 起止相同也要检查覆盖范围
  expect_not_covered(() => @workday.workdays_between(after, after), "[末日后一天, 末日后一天)")
  // 覆盖范围内的整段区间可以计算,正反相反
  let total = @workday.workdays_between(info.from, info.through)
  assert_true(total > 5000, msg="整个覆盖范围内应有数千个工作日,实际 \{total}")
  assert_eq(@workday.workdays_between(info.through, info.from), -total)
  assert_eq(@workday.workdays_between(info.through, info.through), 0)
}
```

- [ ] **步骤 4:运行测试,确认失败**

```bash
cd /d/moonbitsource && moon check 2>&1 | grep -E "^Error" | head -5
```
预期:编译错误,指出 `@workday.add_workdays` 等未定义。

- [ ] **步骤 5:实现 `workday/workday.mbt`**

```moonbit
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
```

- [ ] **步骤 6:运行测试,确认通过**

```bash
cd /d/moonbitsource && moon fmt && moon info && moon check 2>&1 | grep -E "^Error"; for t in js wasm-gc native; do echo "== $t"; moon test --target $t 2>&1 | grep -E "Total tests|rror|FAIL"; done
python scripts/embed_data.py --check
```
预期:三个后端都输出 `Total tests: 36, passed: 36, failed: 0.`(之前的 26 个 + 本任务的 10 个)。性质测试遍历数千个起点,在 js 后端可能需要几秒。

- [ ] **步骤 7:提交**

```bash
cd /d/moonbitsource && git add -A && git commit -q -F - <<'EOF'
feat(workday): 添加 is_workday / add_workdays / workdays_between

- 语义(已与用户确认):起算日不计入;n=0 原样返回起算日;
  workdays_between 为半开区间 [a, b) 且反向取相反数
- 逐日扫描,遇到工作日才消耗一步;走到没有数据的日期立即返回 DataNotCovered,
  起算日与结束日即使不参与计数也必须在覆盖范围内
- 预期值:真实 chinese-days 的 findWorkday / getWorkdaysInRange 与设计文档定义的
  Python 暴力参考实现,数千个用例逐一比对(两者在 n≠0 时完全一致);
  n=0 且起算日不是工作日时 chinese-days 会顺延,本设计不顺延,该类用例来自参考实现
- 属性测试:n=0 返回自身、结果是工作日、随 n 严格递增、反对称、可加、与 add_workdays 互为逆运算
- 审查重点:Int 极端的 n、覆盖范围边界日均有测试

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git log --oneline | head -3
```

- [ ] **步骤 8:向用户讲解 `workday` 的核心逻辑(3–5 句)**

1. 「是否工作日」只有一个判据:调休补班日,或者周一到周五且不在放假区间内;它完全由 `holiday` 提供的日期类型决定。
2. `add_workdays` 从起算日的下一天(或前一天)开始逐日扫描,每遇到一个工作日就消耗一步,起算日本身从不计数,所以不会出现「起算日算不算一天」的歧义。
3. `workdays_between` 是半开区间 `[a, b)`,并对反向区间取相反数,这样它自然满足反对称与可加性,从工作日起算时还与 `add_workdays` 互为逆运算。
4. 扫描到没有数据的日期时立即报错,所以「跨到没有数据的年份」绝不会静默得到一个错误答案。
5. 这套语义与 Excel 的 `WORKDAY`、numpy 的 `busday_count` 一致,唯一与 chinese-days 不同的是 `n=0` 且起算日不是工作日时不顺延,并通过属性测试验证。

---

### Task 9:根包、三后端脚本、README 与最终验证

**文件:**
- 创建:`cncal.mbt`、`cncal_test.mbt`、`scripts/run_all_backends.py`
- 修改:`moon.pkg`(根包依赖)、`README.md`(重写)

**接口:**
- 消费:任务 2–8 的全部公开接口
- 产出:根包 `@cncal` 重新导出的类型与函数:`Date`、`Weekday`、`CalendarError`、`is_leap_year`、`days_in_month`;`LunarDate`、`SolarTerm`、`SolarTermDate`、`solar_to_lunar`、`lunar_to_solar`、`leap_month`、`month_days`、`solar_terms`;`DayKind`、`DataInfo`、`day_kind`、`is_holiday`、`is_makeup_workday`、`holiday_name`、`data_info`;`is_workday`、`add_workdays`、`workdays_between`

- [ ] **步骤 1:根包的依赖与重新导出**

`moon.pkg`:
```
import {
  "sayoi7799/cncal/date",
  "sayoi7799/cncal/lunar",
  "sayoi7799/cncal/holiday",
  "sayoi7799/cncal/workday",
}
```

`cncal.mbt`:
```moonbit
///|
pub using @date {
  type Date,
  type Weekday,
  type CalendarError,
  is_leap_year,
  days_in_month,
}

///|
pub using @lunar {
  type LunarDate,
  type SolarTerm,
  type SolarTermDate,
  solar_to_lunar,
  lunar_to_solar,
  leap_month,
  month_days,
  solar_terms,
}

///|
pub using @holiday {
  type DayKind,
  type DataInfo,
  day_kind,
  is_holiday,
  is_makeup_workday,
  holiday_name,
  data_info,
}

///|
pub using @workday {is_workday, add_workdays, workdays_between}
```

- [ ] **步骤 2:写 README 示例对应的测试 `cncal_test.mbt`**

README 里的最小示例必须是经过测试的。下面的测试与 README 的示例逐行对应。

```moonbit
///|
test "README 最小示例:日期、农历、节气、节假日、工作日" {
  // 日期
  let d = @cncal.Date::new(2026, 9, 30)
  assert_eq("\{d.add_days(1)}", "2026-10-01")
  assert_eq(d.weekday(), @cncal.Wednesday)

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
    @cncal.DataNotCovered(_, _, _) => ()
    e => fail("期望 DataNotCovered,实际 \{e}")
  } noraise {
    _ => fail("期望 DataNotCovered")
  }
}
```
注意:`@cncal.DataNotCovered` 是通过 `CalendarError` 类型的变体访问的;如果编译器要求写 `@date.DataNotCovered`,就在根包的 `moon.pkg` 里保留 `date` 的导入并使用它,测试的意图不变。

- [ ] **步骤 3:运行根包测试**

```bash
cd /d/moonbitsource && moon fmt && moon info && moon check 2>&1 | grep -E "^Error"; for t in js wasm-gc native; do echo "== $t"; moon test --target $t 2>&1 | grep -E "Total tests|rror|FAIL"; done
```
预期:三个后端都输出 `Total tests: 37, passed: 37, failed: 0.`(之前的 36 个 + 1 个根包测试)。如果示例里的某个预期值不对(例如节日名不是「国庆节」),**以数据为准修正示例**,不要改数据。

- [ ] **步骤 4:写 `scripts/run_all_backends.py`**

```python
#!/usr/bin/env python3
"""依次运行 moon check,以及 js、wasm-gc、native 三个后端的 moon test,并汇总结果。

用法: python scripts/run_all_backends.py
全部通过则退出码为 0,否则为 1。
"""
import re
import shutil
import subprocess
import sys
import time

TARGETS = ["js", "wasm-gc", "native"]


def run(moon, args):
    start = time.time()
    p = subprocess.run(
        [moon] + args, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    return p.returncode, p.stdout + p.stderr, time.time() - start


def main():
    moon = shutil.which("moon")
    if not moon:
        sys.exit("找不到 moon 命令,请先安装 MoonBit 工具链")
    code, out, secs = run(moon, ["check"])
    ok = code == 0
    print("%-10s %s (%.1f 秒)" % ("moon check", "通过" if ok else "失败", secs))
    if not ok:
        print(out[-3000:])
    for target in TARGETS:
        code, out, secs = run(moon, ["test", "--target", target])
        totals = re.findall(r"Total tests: (\d+), passed: (\d+), failed: (\d+)", out)
        passed = code == 0 and bool(totals) and totals[-1][2] == "0"
        ok = ok and passed
        summary = "%s/%s 通过" % (totals[-1][1], totals[-1][0]) if totals else "没有找到测试汇总"
        print("%-10s %s (%.1f 秒) %s" % (target, "通过" if passed else "失败", secs, summary))
        if not passed:
            print(out[-3000:])
    print("全部通过" if ok else "存在失败")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **步骤 5:验证「从源码使用」的依赖写法(README 的安装一节要用)**

在临时目录(不在项目内)建一个最小的使用者模块,验证本地路径依赖。先在 moon 官方仓库的测试用例里查 `moon.mod` 中路径依赖的写法:

```bash
cd "$TEMP" && python - <<'PY'
import json
d = json.load(open("moon_tree.json"))
c = [x["path"] for x in d["tree"] if x["path"].split("/")[-1] == "moon.mod"]
print("\n".join(c))
PY
```
(如果 `$TEMP/moon_tree.json` 不存在,先用 `curl -sL "https://api.github.com/repos/moonbitlang/moon/git/trees/HEAD?recursive=1" -o "$TEMP/moon_tree.json"` 取得 moon 仓库的文件树。)再从 `https://raw.githubusercontent.com/moonbitlang/moon/main/<路径>` 读取含 `path` 依赖的 `moon.mod`,照着写一个使用者模块:

```bash
SP="$TEMP/consumer" && rm -rf "$SP" && mkdir -p "$SP" && cd "$SP"
# 写 moon.mod:导入 sayoi7799/cncal,路径指向 D:\moonbitsource(写法以上面查到的为准)
# 写 moon.pkg:import { "sayoi7799/cncal" }
# 写 main.mbt:用 @cncal.add_workdays 打印一个结果
moon check && moon run .
```
预期:`moon run` 打印 `2026-10-08`。把验证通过的 `moon.mod` 写法记下来,放进 README 的「从源码使用」。**如果无法让路径依赖工作,不要在 README 里写未经验证的写法**,而是只写「克隆仓库并运行 `moon test`」。

- [ ] **步骤 6:重写 `README.md`**

README 是面向使用者和评委的主要文档,必须是简体中文,并且所有声明都与实际结果一致。结构与要点如下(正文用完整的句子写出,不要留下占位):

1. **标题与简介**:`cncal`:用 MoonBit 编写的中国日历与工作日引擎;同一份代码编译到 js、wasm-gc、native,结果完全相同(库内只用整数运算,没有浮点)。
2. **解决什么问题**:三个痛点(设计文档 §1.1)。
3. **功能**:日期类型;公历农历互转(1900-01-31 ~ 2101-01-28,含闰月);二十四节气(1900–2100);法定节假日与调休(2004–2026,数据与逻辑分离);工作日计算。
4. **安装**:按步骤 5 验证过的写法写「从源码使用」;`moon add sayoi7799/cncal` 只有在发布到 mooncakes 之后才能写(见步骤 9 的询问),未发布时不要写。
5. **最小使用示例**:与 `cncal_test.mbt` 逐行相同的代码,并注明结果。
6. **工作日语义定义**:设计文档 §5.4.1 的定义表、§5.4.2 的性质(含 P6 的限制条件,不要宣称无条件成立)、§5.4.3 的示例、§5.4.4 与 chinese-days 的差异(`n=0` 不顺延;`is_holiday` 不含普通周末)。
7. **数据与更新**:数据格式的简述;每年更新只改 `data/holidays.json`(设计文档 §5.3.4 的四步);覆盖范围外一律报 `DataNotCovered`。
8. **正确性**:差分测试覆盖的内容(1000 个随机日期、整个农历域逐月比对加 73000 天逐日往返、201 年 × 24 个节气、8401 天逐日比对节假日、数千个工作日用例)和三后端结果;**已知限制**:lunar-python 与流行农历表在 1933、1996、2060 年不一致(本项目以 lunar-python 为准);最新覆盖年份的年末几天可能被下一年通知修改;差分测试验证的是代码而不是数据的真伪,真伪见 `docs/data-verification.md`;chinese-days 的节气公式有缺陷(立秋 1900–1999 年晚 20 天),所以节气不以它为参考。
9. **开发指南**:环境要求(MoonBit 工具链、Python 3.12+、Node.js);复现数据的命令(`python -m venv .venv`、`pip install -r scripts/requirements.txt -i https://pypi.org/simple`、`PYTHONUTF8=1 python scripts/gen_tables.py`、`gen_expected.py all`、`embed_data.py`、`--check`);运行三后端测试(`python scripts/run_all_backends.py` 或三条 `moon test --target …` 命令)。
10. **来源与致谢**:lunar-python(MIT,6tail)与 chinese-days(MIT,Yawei sun)的用途与链接,指向 `THIRD_PARTY_NOTICES.md`;放假安排来自国务院办公厅通知,`data/holidays.json` 记录了每年的出处。
11. **许可证**:MIT。

- [ ] **步骤 7:最终全量验证**

```bash
cd /d/moonbitsource && export PYTHONUTF8=1
# 1. 格式、接口、检查
moon fmt && moon info && moon check 2>&1 | grep -E "^Error|Failed"
git status --short   # 此时应当只有 README.md、cncal*.mbt、moon.pkg、scripts/run_all_backends.py、pkg.generated.mbti 的改动
# 2. 三个后端 + 汇总
python scripts/run_all_backends.py
# 3. 额外的后端(wasm、wasm-gc、js、native)
moon test --target all 2>&1 | grep -E "Total tests"
# 4. 生成物都是最新的
python scripts/embed_data.py --check && .venv/Scripts/python scripts/gen_tables.py --check
# 5. 重新生成全部预期数据,结果必须与已提交的逐字节相同(约 2 分钟)
.venv/Scripts/python scripts/gen_expected.py all && git status --short testdata/
```
预期:
- `run_all_backends.py` 对 `moon check` 与 js、wasm-gc、native 全部输出「通过」,并显示 `37/37 通过`;
- `moon test --target all` 输出 wasm、wasm-gc、js、native 四行,每行 `Total tests: 37, passed: 37, failed: 0.`;
- 两个 `--check` 都显示是最新的;
- 重新生成后 `git status --short testdata/` 没有任何输出(预期数据逐字节可重现)。

任何一项不满足,回到相应任务修复,不要降低标准。

- [ ] **步骤 8:提交**

```bash
cd /d/moonbitsource && git add -A && git commit -q -F - <<'EOF'
docs: 添加根包重新导出、三后端验证脚本与 README

- 根包 cncal 重新导出各子包的常用类型与函数,最小示例只需导入一个包
- cncal_test.mbt:README 最小示例的逐行对应测试
- scripts/run_all_backends.py:依次运行 moon check 与 js / wasm-gc / native 的 moon test 并汇总
- README:安装方式、最小使用示例、工作日语义定义、数据更新流程、
  正确性与已知限制、开发指南、来源与致谢

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
EOF
git log --oneline
```

- [ ] **步骤 9:向用户报告,并询问两件需要用户决定的事**

1. **是否发布到 mooncakes。** `moon publish` 会让模块公开可见,属于对外发布,必须得到用户明确同意后才能执行。用户同意并已 `moon login` 时,发布后再把 `moon add sayoi7799/cncal` 写进 README 的安装一节并提交;用户暂不发布时,README 保持只写「从源码使用」。
2. **如何合并分支。** 所有提交都在 `feat/mvp` 分支上,`main` 上只有设计文档那一个提交。调用 `superpowers:finishing-a-development-branch`,向用户给出合并选项(推荐 `git merge --ff-only feat/mvp` 合并到 `main`,保留逐步提交的历史)。

同时把最终结果汇总给用户:每个模块的测试数量、差分测试的覆盖范围、三后端的通过情况、已知限制,以及与 chinese-days 的两处有意差异。
