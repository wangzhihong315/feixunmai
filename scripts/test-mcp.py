#!/usr/bin/env python3
"""VibeDeck 胶囊 MCP 的端到端冒烟测试。

用法：
    python3 -I scripts/test-mcp.py [MCP 可执行文件路径]

默认使用 .build/release/VibeDeckMCP。会完整走一遍 initialize → tools/list →
list_capsules → search_capsules → get_capsule，并打印关键结果。
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "release", "VibeDeckMCP")


def main() -> int:
    if not os.path.exists(BIN):
        print(f"[FAIL] 找不到 MCP 可执行文件：{BIN}")
        return 1

    proc = subprocess.Popen(
        [BIN],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    def rpc(payload):
        proc.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
        proc.stdin.flush()
        if "id" not in payload:
            return None
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("服务器提前退出：" + proc.stderr.read())
        return json.loads(line)

    failures = []

    def check(name, ok, detail=""):
        print(("[PASS] " if ok else "[FAIL] ") + name + (f" · {detail}" if detail else ""))
        if not ok:
            failures.append(name)

    init = rpc({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "vibedeck-smoke", "version": "1.0"},
        },
    })
    check(
        "initialize",
        init.get("result", {}).get("protocolVersion") == "2024-11-05",
        init.get("result", {}).get("serverInfo", {}).get("name", ""),
    )
    rpc({"jsonrpc": "2.0", "method": "notifications/initialized"})

    prompts = rpc({"jsonrpc": "2.0", "id": 20, "method": "prompts/list"})
    prompt_names = [p["name"] for p in prompts.get("result", {}).get("prompts", [])]
    check("prompts/list", "organize_inspirations" in prompt_names, ", ".join(prompt_names))

    prompt = rpc({
        "jsonrpc": "2.0", "id": 21, "method": "prompts/get",
        "params": {"name": "organize_inspirations"},
    })
    prompt_text = prompt.get("result", {}).get("messages", [{}])[0].get("content", {}).get("text", "")
    check(
        "prompts/get",
        "哪些是我现在真正想推进的" in prompt_text,
        f"{len(prompt_text)} 字",
    )

    tools = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    names = [t["name"] for t in tools.get("result", {}).get("tools", [])]
    check(
        "tools/list",
        set(names) == {"list_capsules", "search_capsules", "get_capsule"},
        ", ".join(names),
    )

    listing = rpc({
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "list_capsules", "arguments": {"limit": 5}},
    })
    content = listing.get("result", {}).get("content", [])
    data = json.loads(content[0]["text"]) if content else {}
    check(
        "list_capsules",
        "capsules" in data,
        f"{data.get('count', 0)}/{data.get('total', 0)} 条，待转写 {data.get('pending', 0)}",
    )

    search = rpc({
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": {"name": "search_capsules", "arguments": {"query": "测试"}},
    })
    content = search.get("result", {}).get("content", [])
    hits = json.loads(content[0]["text"]) if content else {}
    check("search_capsules", hits.get("count", 0) >= 1, f"命中 {hits.get('count', 0)} 条")

    capsules = data.get("capsules", [])
    if capsules:
        capsule_id = capsules[0]["id"]
        detail = rpc({
            "jsonrpc": "2.0", "id": 5, "method": "tools/call",
            "params": {"name": "get_capsule", "arguments": {"id": capsule_id}},
        })
        content = detail.get("result", {}).get("content", [])
        record = json.loads(content[0]["text"]) if content else {}
        check(
            "get_capsule",
            record.get("id") == capsule_id and "audioPath" in record,
            record.get("text", "")[:40],
        )
    else:
        print("[SKIP] get_capsule · 当前没有胶囊")

    proc.stdin.close()
    proc.wait(timeout=5)
    err = proc.stderr.read().strip()
    if err:
        print("server stderr:", err.splitlines()[0])

    if failures:
        print(f"\n{len(failures)} 项失败：" + ", ".join(failures))
        return 1
    print("\n全部通过 ✔")
    return 0


if __name__ == "__main__":
    sys.exit(main())
