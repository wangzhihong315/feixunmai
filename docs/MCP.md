# 闪念胶囊 MCP

VibeDeck 附带一个只读的 MCP 服务器，把手机录下、Mac 已同步（并尽量已转写）的闪念胶囊暴露给 Agent。

- 可执行文件：`dist/VibeDeckMCP`（App 包内也有一份：`VibeDeck.app/Contents/MacOS/VibeDeckMCP`）
- 数据目录：`~/Library/Application Support/VibeDeck/capsules/`
  - `<id>.json`：元数据 + 转写文本
  - `<id>.wav`：手机录的 16 kHz 单声道音频
- 传输：stdio（JSON-RPC 2.0，逐行）

## 工具

| 工具 | 参数 | 返回 |
|---|---|---|
| `list_capsules` | `limit`（默认 20）、`pending_only` | 最近的胶囊，按时间倒序；含总数与待转写数 |
| `search_capsules` | `query`（必填）、`limit` | 在转写文本里忽略大小写匹配，附命中片段 |
| `get_capsule` | `id`（必填） | 单条完整文本、时长、录制/转写时间、音频绝对路径 |

每条记录包含 `id`、`createdAt`、`durationSec`、`transcribed`、`text`、`audioPath`。

## 现成的整理 Prompt

MCP 还提供一个 prompt：`organize_inspirations`（整理闪念胶囊里的灵感）。它要求 Agent 先 `list_capsules`，然后：

1. 按主题归纳成 3–5 组，而不是逐条复述；
2. 每组一句话提炼“用户想要/担心什么”，引用原话和时间；
3. 指出重复、矛盾、可合并的想法；
4. 最后询问用户：哪些灵感现在想推进、需要做哪些工作、先做哪一个、交付物是什么。

用户确认之前，Agent 不应该直接执行。支持 MCP prompts 的客户端会在提示/命令列表里显示它。

## 客户端配置

把 `command` 换成你机器上的实际路径：

```json
{
  "mcpServers": {
    "vibedeck-capsules": {
      "command": "/path/to/feixunmai/dist/VibeDeckMCP",
      "args": []
    }
  }
}
```

Claude Desktop 放在 `~/Library/Application Support/Claude/claude_desktop_config.json`；其他客户端按其 `mcpServers` 格式填写。

## 自测

```bash
python3 -I scripts/test-mcp.py dist/VibeDeckMCP
```

会完整走一遍 `initialize → tools/list → list/search/get` 并打印结果。

## 说明

- 服务器只读，不会修改胶囊；删除/转写仍由 App 负责。
- 测试时可用 `VIBEDECK_CAPSULES_DIR=/tmp/capsules` 指向别的目录。
- 需要“一边说一边让 Agent 读”时，等下一次同步落盘后重新 `list_capsules` 即可；目前没有订阅/推送。
