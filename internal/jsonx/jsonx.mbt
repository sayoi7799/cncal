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
