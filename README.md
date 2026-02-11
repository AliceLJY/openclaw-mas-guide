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
| `claude-opus-4-6` | `claude-opus-4-6-thinking` |
| `claude-opus-4-5` | `claude-opus-4-5-thinking`（已下线） |
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
    "primary": "google-antigravity/claude-opus-4-6-thinking",
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
    ├─ #work ──→ coder agent (Opus 4.6) ──fallback→ Sonnet → Gemini Pro → Flash
    ├─ #mean ──→ reviewer agent (Sonnet 4.5) ──fallback→ Gemini Pro → Flash
    ├─ #nano ──→ nano agent (Gemini Pro) ──fallback→ Flash
    └─ 其他频道 ──→ main agent (Opus 4.6) ──fallback→ Sonnet → Gemini Pro → Flash
                        │
                        └─ MAS 可用：spawn coder/reviewer/researcher (subagents: Opus 4.6)
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

## 进阶：MAS 工作流模式

经实测，OpenClaw MAS 支持以下三种协作模式：

### Mode A：线性流水线（Linear Pipeline）

子 agent 按顺序执行，前一个的输出作为后一个的输入。

```
用户 → Agent A → Agent B → Agent C → 汇总
```

**用法**：Flash spawn Agent A，等完成后再 spawn Agent B（把 A 的结果写进 B 的 task 描述）。

### Mode B：DAG 并行（实测通过）

多个子 agent 同时执行不同的独立任务，最后汇总。类似 Claude Code 的 subagent 模式。

```
         ┌─ Coder → 写代码
用户 → Flash ├─ Reviewer → 列大纲
         └─ Researcher → 搜数据
                    ↓
              Flash 汇总
```

**测试 prompt**：
```
帮我准备一篇关于"AI 替代焦虑"的公众号文章素材，三个任务并行执行：
1. Code Agent：写一个 Python 情绪分析小工具的完整代码
2. Research Agent：搜集 AI 替代焦虑的数据、案例和权威报告
3. Review Agent：为这个话题列出公众号文章写作大纲和避坑建议
三个任务相互独立，请同时 spawn 三个子 agent 并行处理，完成后汇总所有结果。
```

**实测结果**：
- Flash 成功并行 spawn 3 个子 agent
- 全部完成后 Flash **一次性输出完整汇总表**，无需追问
- 速度较快，适合日常使用

### Mode C：辩论模式（Debate，实测通过）

多个子 agent 围绕同一话题从不同立场输出观点，最后由 Flash 综合。类似 Claude Code 的 teams 模式。

```
         ┌─ Coder（赋能派）→ 正方观点
用户 → Flash ├─ Reviewer（焦虑派）→ 反方观点
         └─ Researcher（调研员）→ 中立数据
                    ↓
              Flash 综合对比
```

**测试 prompt**：
```
我要在公众号写一篇"AI照见众生"板块的深度观察文章。话题：AI 到底是让普通人变强了，还是让普通人更焦虑了？
请用 MAS 多智能体辩论模式：
1. Code Agent 扮演"赋能派"（正方）
2. Review Agent 扮演"焦虑派"（反方）
3. Research Agent 扮演"调研员"（中立方）
三位同时发言，完成后你来做裁判，输出对比表、分歧点分析和文章框架。
```

**实测结果**：
- 3 个 agent 并行完成，各自输出风格鲜明的内容
- **已知问题**：Flash 汇总时可能说"请稍后"然后 run 结束，需要追问一句"请继续汇总"才输出完整对比表
- 原因：单个 turn 的输出 token 不够同时汇报 3 个 agent 的结果 + 生成综合报告

### 三种模式对比

| | Mode A 线性 | Mode B 并行 | Mode C 辩论 |
|---|---|---|---|
| 子 agent 关系 | 串行依赖 | 完全独立 | 独立但同话题 |
| 执行速度 | 最慢 | 快 | 快 |
| 汇总质量 | 高（有上下文传递） | 高（一次性输出） | 高（但可能需追问） |
| 适合场景 | 代码→审查→测试 | 素材搜集、多角度准备 | 观点碰撞、深度分析 |
| CC 类比 | — | subagent 模式 | teams 模式 |

## 进阶：MAS + 本地 Claude Code 集成

### 问题

MAS 擅长并行搜集素材和生成框架，但最终写成公众号文章需要特定的风格处理（去 AI 味、口语化等）。这些规则在本地 Claude Code 的 skill 和 CLAUDE.md 里，OpenClaw 容器内不知道。

### 解决方案：MAS → CC 流水线

通过 [openclaw-worker](https://github.com/AliceLJY/openclaw-worker) 桥接 OpenClaw 和本地 CC：

```
Discord 用户发指令
    │
    ├─ 1. Flash spawn MAS agents（并行出素材）
    │     ├─ Researcher → 数据/案例
    │     ├─ Reviewer → 大纲/避坑
    │     └─ Coder → 代码示例
    │
    ├─ 2. Flash 汇总 → 文章框架
    │
    ├─ 3. Flash 调用本地 CC（通过 Task API + session-id 多轮对话）
    │     └─ CC 跑 Content Alchemy skill
    │         → 多阶段精炼（分析→提炼→人话改写→去 AI 味→配图）
    │         → 遇到 checkpoint → Flash 转发给用户 → 用户 Discord 回复 → Flash 转发给 CC
    │
    └─ 4. CC 返回成品 → Flash 发到 Discord
```

**分工**：MAS 是大脑（搜集素材），CC 是笔杆子（写成用户风格）。

### 关键配置

Bot 的 MEMORY.md 需要包含：
1. CC 调用方式（API 地址、认证）
2. **Skill 调用规则**：prompt 必须以 `/content-alchemy` 开头，不能让 CC 裸写
3. **多轮对话说明**：首轮不带 sessionId，后续轮次带上返回的 sessionId
4. Bot 在 CC 交互中是传话人，不替用户做决定

### 已知问题

- Flash 可能不知道怎么调 skill，只是把素材作为普通 prompt 发给 CC → CC 裸写，质量差
- **解法**：在 MEMORY.md 的 CC 调用规则里明确写 skill 命令格式
- Researcher 的 `web_search` 需要 Brave API key 才能真正搜索，否则只用内部知识

## 验证方法

### 基础验证（MAS 协作）

在 Discord **未绑定频道**（如 #chat）对 bot 说：

```
用 MAS 写一个 Python 计算器程序，Code Agent 写代码，Review Agent 审查
```

预期行为：
- Bot 调用 `sessions_spawn` 生成 Code Agent（agentId: "coder"）
- Code Agent 完成后，Bot 再 spawn Review Agent（agentId: "reviewer"）
- Bot 汇总两个子 agent 的结果，输出协作报告

### Mode B 验证（并行素材搜集）

在 #chat 发送上面 Mode B 的测试 prompt，预期 3 个 agent 并行完成后一次性汇总。

### Mode C 验证（辩论模式）

在 #chat 发送上面 Mode C 的测试 prompt，预期 3 个 agent 各出观点，追问后 Flash 输出对比表。

### MAS + CC 验证（完整流水线）

在 #chat 发送：
```
用 MAS 搜集"AI 替代焦虑"素材（并行），然后调用本地 Claude Code 用 /content-alchemy skill 写一篇公众号文章
```

预期：MAS 出框架 → Flash 调 CC → CC 跑 skill 多阶段 → 成品返回 Discord。

## 版本记录

### v4 (2026-02-11)
- 升级：Opus 4.5 → Opus 4.6 Thinking（Antigravity 已上线，需 pi-ai 补丁）
- 更新：架构图反映最新模型分配（main/coder/MAS subagents 用 Opus 4.6，reviewer 用 Sonnet，研究/图片用 Gemini）
- 记录：pi-ai 模型目录补丁方法（volume mount `models.generated.js`）
- 环境版本更新至 OpenClaw 2026.2.9

### v3 (2026-02-10)
- 新增：MAS 三种工作流模式文档（Mode A 线性 / Mode B 并行 / Mode C 辩论），含实测 prompt 和结果
- 新增：MAS + 本地 Claude Code 集成方案（通过 openclaw-worker 桥接，session-id 多轮对话）
- 新增：Content Alchemy skill 调用规则（Bot MEMORY.md 配置方法）
- 记录：Mode C 已知问题（Flash 汇总可能需追问一句）
- 记录：Researcher web_search 需要 Brave API key

### v2 (2026-02-10)
- 新增：模型容错（fallback 链）配置方法
- 新增：Discord 频道级路由（bindings）方案，经实测 `peer.kind: "channel"` 可用
- 更新：示例 openclaw.json 包含 fallback + bindings 完整配置
- 记录：官方 per-channel model override 被拒（issue #3742），bindings 是替代方案

### v1 (2026-02-08)
- 初始版本：MAS 三大坑 + 完整配置示例

## 环境

- OpenClaw: 2026.2.9
- Provider: Google Antigravity（OAuth）
- Channel: Discord
- Platform: Docker

> **注意**：`claude-opus-4-6-thinking` 目前不在 pi-ai 内置模型目录中，需要通过补丁 `models.generated.js` 并用 Docker volume mount 挂载。详见 [openclaw-worker docker-compose.antigravity.yml](https://github.com/AliceLJY/openclaw-worker/blob/main/docker/docker-compose.antigravity.yml)。OpenClaw 上游更新 pi-ai 后可移除补丁。

## 参考

- [OpenClaw Sub-Agents 官方文档](https://docs.openclaw.ai/tools/subagents)
- [OpenClaw Multi-Agent Routing](https://docs.openclaw.ai/concepts/multi-agent)
- [OpenClaw Model Providers](https://docs.openclaw.ai/concepts/model-providers)
- [AI超元域的 OpenClaw 中文教程](https://www.aivi.fyi/aiagents/introduce-OpenClaw-Agent)（Google Antigravity 接入方法参考）

## Related Issue

- [#11982](https://github.com/openclaw/openclaw/issues/11982) — docs(subagents): clarify allowAgents is per-agent only

## License

MIT
