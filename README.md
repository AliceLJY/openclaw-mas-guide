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

## 进阶：模型容错（Fallback 链）

OpenClaw 原生支持 `model.fallbacks` 数组。当主模型挂了（认证失败、rate limit、额度耗尽），自动切换到下一个备选模型。

### 配置方法

把 `model` 从字符串改成对象：

```json
{
  "id": "coder",
  "name": "Code Agent",
  "model": {
    "primary": "google-antigravity/claude-opus-4-5-thinking",
    "fallbacks": ["google-antigravity/claude-sonnet-4-5", "google-antigravity/gemini-3-pro-high"]
  }
}
```

全局默认也可以加：

```json
"defaults": {
  "model": {
    "primary": "google-antigravity/gemini-3-flash",
    "fallbacks": ["google-antigravity/gemini-3-pro-high"]
  }
}
```

### 容错机制

OpenClaw 的故障恢复分两层：

1. **同 provider 内 auth profile 轮换**：如果有多个账号，先轮换 auth profile（冷却时间 1→5→25 分钟→1 小时上限）
2. **跨模型 fallback**：所有 profile 都挂了才跳到 fallbacks 里的下一个模型

计费额度耗尽的冷却更长：5 小时起步，翻倍到 24 小时封顶。

参考：[OpenClaw Model Failover 文档](https://docs.openclaw.ai/concepts/model-failover)

## 进阶：Discord 频道级路由（Bindings）

### 问题

默认情况下，所有 Discord 频道都路由到 `main` agent（通常是最便宜的模型）。想让 #work 频道直接用 Opus、#mean 用 Sonnet，靠 MEMORY.md 写 prompt 指引让 Flash 自己判断何时 spawn 子 agent——**不靠谱**，Flash 经常不主动 spawn。

### 解决方案：bindings

OpenClaw 的 `bindings` 数组可以把特定 Discord 频道直接路由到指定 agent，绕过 main agent：

```json
{
  "bindings": [
    {
      "agentId": "coder",
      "match": {
        "channel": "discord",
        "peer": { "kind": "channel", "id": "YOUR_WORK_CHANNEL_ID" }
      }
    },
    {
      "agentId": "reviewer",
      "match": {
        "channel": "discord",
        "peer": { "kind": "channel", "id": "YOUR_MEAN_CHANNEL_ID" }
      }
    }
  ]
}
```

### 获取 Discord 频道 ID

Discord 开启开发者模式后，右键频道名 → Copy Channel ID。

### 路由优先级（most-specific wins）

1. Peer match（频道 ID）← bindings 用的就是这个
2. Guild ID（Discord 服务器）
3. Team ID（Slack）
4. Account ID
5. Channel 类型
6. 默认 agent

### 注意事项

- 被绑定的频道**不经过 main agent**，该频道里不会有 MAS 协作（但通常不需要——#work 直接用 Opus 就够了）
- 每个绑定的 agent 需要自己的 `auth-profiles.json`（同坑三的处理方式）
- `peer.kind` 对 Discord 频道用 `"channel"`（经实测验证）
- 官方 per-channel model override [被拒了](https://github.com/openclaw/openclaw/issues/3742)，bindings 是目前唯一的系统级方案
- 未绑定的频道仍走 main agent，MAS 功能照常可用

### 架构效果

```
Discord 消息进入
    │
    ├─ #work ──→ coder agent (Opus 4.5) ──fallback→ Sonnet → Gemini Pro
    ├─ #mean ──→ reviewer agent (Sonnet 4.5) ──fallback→ Gemini Pro → Flash
    ├─ #nano ──→ nano agent (Gemini Pro) ──fallback→ Flash
    └─ 其他频道 ──→ main agent (Flash) ──fallback→ Gemini Pro
                        │
                        └─ MAS 可用：spawn coder/reviewer/researcher
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

## 版本记录

### v2 (2026-02-10)
- 新增：模型容错（fallback 链）配置方法
- 新增：Discord 频道级路由（bindings）方案，经实测 `peer.kind: "channel"` 可用
- 更新：示例 openclaw.json 包含 fallback + bindings 完整配置
- 记录：官方 per-channel model override 被拒（issue #3742），bindings 是替代方案

### v1 (2026-02-08)
- 初始版本：MAS 三大坑 + 完整配置示例

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
