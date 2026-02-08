# OpenClaw MAS (Multi-Agent System) Setup Guide

> 在 OpenClaw 上配置 `sessions_spawn` 多 Agent 协作的完整踩坑指南。

## 背景

OpenClaw 原生支持通过 `sessions_spawn` 生成子 agent session，实现多模型并行协作。但配置过程中有几个文档没写清楚的坑，这个仓库记录了从报错到跑通的完整过程。

**最终效果**：在 Discord 频道里说一句话，bot 自动 spawn 不同模型的子 agent 并行工作，汇总结果回来。

## 三个关键坑

### 坑一：`allowAgents` 放错位置

直觉上会放在 `agents.defaults.subagents` 下，但这会导致 config schema 验证失败，容器启动崩溃：

```
agents.defaults.subagents: Unrecognized key: "allowAgents"
```

**正确做法**：放在 `agents.list` 里发起 spawn 的 agent（通常是 `main`）的 `subagents` 下：

```json
{
  "id": "main",
  "subagents": {
    "allowAgents": ["coder", "reviewer", "researcher"]
  }
}
```

**原因**：`allowAgents` 在 schema 设计上是 per-agent 的，不支持全局 defaults。运行时代码通过 `resolveAgentConfig(cfg, requesterAgentId)` 读取发起者的 agent entry 配置。

### 坑二：模型 ID 必须精确匹配

配置里写 `claude-opus-4-5`，运行时报 `Unknown model`。API 返回的实际模型 ID 跟你以为的不一样：

| 你以为的 | 实际的 |
|---------|-------|
| `claude-opus-4-5` | `claude-opus-4-5-thinking` |
| `claude-sonnet` | `claude-sonnet-4-5` |
| `gemini-3-pro` | `gemini-3-pro-high` |

**解决方法**：先查实际可用模型：

```bash
docker exec <container> node openclaw.mjs models list --all --provider google-antigravity --json
```

### 坑三：子 agent 需要 auth

每个子 agent 有独立的 `agentDir`，auth 是 per-agent 的。需要把主 agent 的 `auth-profiles.json` 复制到子 agent 目录：

```bash
mkdir -p agents/coder/agent agents/reviewer/agent
cp agents/main/agent/auth-profiles.json agents/coder/agent/
cp agents/main/agent/auth-profiles.json agents/reviewer/agent/
```

## 完整配置示例

### openclaw.json

参见 [examples/openclaw.json](examples/openclaw.json)

### 目录结构

```
~/.openclaw/
├── openclaw.json
├── agents/
│   ├── main/
│   │   └── agent/
│   │       └── auth-profiles.json    # OAuth credentials
│   ├── coder/
│   │   └── agent/
│   │       └── auth-profiles.json    # 从 main 复制
│   └── reviewer/
│       └── agent/
│           └── auth-profiles.json    # 从 main 复制
├── workspace/                        # 主 agent workspace
│   └── MEMORY.md                     # 含 MAS 编排指令
├── workspace-coder/                  # Code Agent workspace
└── workspace-reviewer/               # Review Agent workspace
```

### MEMORY.md 添加内容

参见 [examples/MEMORY-MAS-section.md](examples/MEMORY-MAS-section.md)

Bot 需要在 MEMORY.md 里知道有哪些子 agent 可用、什么时候使用 MAS、怎么调用 `sessions_spawn`，否则它不会主动使用这个功能。

## 验证方法

在 Discord 频道对 bot 说：

```
用 MAS 写一个 Python 计算器程序，Code Agent 写代码，Review Agent 审查
```

预期行为：
- Bot 调用 `sessions_spawn` 生成 Code Agent（agentId: "coder"）
- Code Agent 完成后，Bot 再 spawn Review Agent（agentId: "reviewer"）
- Bot 汇总两个子 agent 的结果，输出协作报告

## 环境

- OpenClaw: 2026.2.6
- Provider: Google Antigravity（OAuth）
- Channel: Discord
- Platform: Docker

## 参考

- [OpenClaw Sub-Agents 官方文档](https://docs.openclaw.ai/tools/subagents)
- [OpenClaw Multi-Agent Routing](https://docs.openclaw.ai/concepts/multi-agent)
- [OpenClaw Model Providers](https://docs.openclaw.ai/concepts/model-providers)
- [AI超元域的 OpenClaw 中文教程](https://www.aivi.fyi/aiagents/introduce-OpenClaw-Agent)（Google Antigravity 接入方法参考）

## Related Issue

- [#11982](https://github.com/openclaw/openclaw/issues/11982) — docs(subagents): clarify allowAgents is per-agent only

## License

MIT
