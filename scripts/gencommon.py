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
