# 把闪念胶囊接入各种 Agent

MCP 服务命令统一是：

```
/path/to/feixunmai/dist/VibeDeckMCP
```

传输是 stdio，不需要端口，也不需要 VibeDeck.app 在运行（它只读磁盘上的胶囊）。

## 已接入并验证

| 工具 | 配置方式 | 状态 |
|---|---|---|
| **ZCode** | `~/.zcode/cli/config.json` → `mcp.servers.vibedeck-capsules` | 已写入，**新开一次会话生效** |
| **Claude Code** | `claude mcp add --scope user vibedeck-capsules <路径>` | `claude mcp list` 显示 **✔ Connected** |
| **Codex CLI** | `codex mcp add vibedeck-capsules -- <路径>`（写入 `~/.codex/config.toml` 的 `[mcp_servers.*]`） | `codex mcp list` 显示 **enabled** |
| **Qwen Code** | `qwen mcp add vibedeck-capsules <路径>`（用户级 settings） | `qwen mcp list` 显示 **✔ Connected** |
| **WorkBuddy** | `~/.workbuddy/mcp.json` → `mcpServers` | 已写入，重启 WorkBuddy 生效 |

ZCode 的配置结构：

```json
{
  "mcp": {
    "servers": {
      "vibedeck-capsules": {
        "command": "/绝对路径/VibeDeckMCP",
        "args": []
      }
    }
  }
}
```

WorkBuddy 的条目：

```json
{
  "mcpServers": {
    "vibedeck-capsules": {
      "type": "stdio",
      "command": "/绝对路径/VibeDeckMCP",
      "args": [],
      "timeout": 30000,
      "disabled": false
    }
  }
}
```

## 需要在 App 界面里加的工具

- **Qoder**：`~/.qoder` 下没有找到用户级 MCP 配置文件（只有插件缓存和日志）。在 Qoder 的 Settings / MCP 面板里新增一个 stdio 服务，命令填上面的绝对路径。
- **DeepSeek Harness.app**：应用数据目录里没有暴露 MCP 配置文件，同样在它的设置/工具面板里添加 stdio 命令；如果版本不支持 MCP，就只能用文件兜底。
- **Cursor**：按你的要求暂不接入。

通用 JSON（大多数支持 `mcpServers` 的客户端都能直接用）：

```json
{
  "mcpServers": {
    "vibedeck-capsules": {
      "command": "/绝对路径/VibeDeckMCP",
      "args": []
    }
  }
}
```

## Skill

另配了一个 Skill，告诉 Agent 闪念胶囊是什么、什么时候该查、怎么用三个 MCP 工具：

```
~/.agents/skills/vibedeck-capsules/SKILL.md   # ZCode / 共享
~/.claude/skills/vibedeck-capsules/SKILL.md   # Claude Code
~/.codex/skills/vibedeck-capsules/SKILL.md    # Codex
仓库内也保留一份：skills/vibedeck-capsules/SKILL.md
```

Skill 的核心不是“怎么读文件”，而是**胶囊是用户的灵感池**：Agent 读完后要按主题归纳、提炼用户想要什么、再主动追问“哪些灵感要推进、需要我做什么工作”，在用户确认前不擅自执行。Skill 里也写了数据目录、工具参数、引用规则、无 MCP 时的只读兜底和隐私约束。

MCP 同时带一个 `organize_inspirations` prompt，内容与 Skill 一致，支持 prompts 的客户端可以直接调用。Qoder / WorkBuddy / DeepSeek Harness 如果支持自定义 Skill/指令，把同一份 `SKILL.md` 放进它们的技能目录即可。

## 验证

```bash
python3 -I scripts/test-mcp.py dist/VibeDeckMCP
```

或用任意客户端检查：

```bash
claude mcp list
codex mcp list
qwen mcp list
```

ZCode 里新开一个会话后，可以直接说「列一下我最近的闪念胶囊」来验证。
