## MAS（多智能体协作系统）

### 可用子 Agent

| Agent ID | 名称 | 模型 | 用途 |
|----------|------|------|------|
| `coder` | Code Agent | Claude Opus 4.5 Thinking | 编写代码、架构设计、复杂逻辑 |
| `reviewer` | Review Agent | Claude Sonnet 4.5 | 代码审查、测试编写、质量检查 |
| `researcher` | Research Agent | Gemini 3 Pro High | 信息收集、网络搜索、资料整理 |

### 何时使用 MAS

当用户的任务满足以下条件时，自动启用 MAS 协作：
1. **任务可拆分**：任务包含 2 个以上独立子任务
2. **需要不同能力**：例如既要写代码又要搜索资料
3. **用户明确要求**：用户说"用多 agent"或"分工协作"

### 如何使用 sessions_spawn

```
sessions_spawn({
  task: "具体的子任务描述，要清晰完整",
  agentId: "coder",       // 指定子 agent
  label: "Code Agent",    // 显示名称
  runTimeoutSeconds: 120  // 超时时间
})
```

### MAS 工作流程

1. **分析任务**：判断是否需要 MAS，拆分为子任务
2. **生成子 agent**：用 sessions_spawn 生成子 agent，可以并行生成多个
3. **监控进度**：用 sessions_history 查看子 agent 的输出
4. **汇总结果**：子 agent 完成后，汇总所有结果
5. **报告**：生成协作报告表格，发送到当前频道

### MAS 协作报告格式

完成后输出以下格式的报告：

| 智能体 | 模型 | 任务 | 执行结果 |
|--------|------|------|----------|
| Code Agent | Claude Opus | [任务描述] | [状态 + 摘要] |
| Review Agent | Sonnet | [任务描述] | [状态 + 摘要] |
| Research Agent | Gemini Pro | [任务描述] | [状态 + 摘要] |

### 限制

- 子 agent 不能再生成子 agent（只有一层嵌套）
- 子 agent 没有 session 工具（不能互相通信）
- 子 agent 的结果通过 announce 自动回传
- 子 agent 默认 60 分钟后自动归档
