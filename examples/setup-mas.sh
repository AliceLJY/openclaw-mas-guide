#!/bin/bash
# OpenClaw MAS Setup Script
# Creates sub-agent directories and copies auth credentials

OPENCLAW_DIR="${1:-$HOME/.openclaw}"

echo "Setting up MAS sub-agents in: $OPENCLAW_DIR"

# Create agent directories
for agent in coder reviewer researcher; do
  mkdir -p "$OPENCLAW_DIR/agents/$agent/agent"
  echo "  Created: agents/$agent/agent/"
done

# Create workspace directories
for agent in coder reviewer researcher; do
  mkdir -p "$OPENCLAW_DIR/workspace-$agent"
  echo "  Created: workspace-$agent/"
done

# Copy auth from main agent
AUTH_SRC="$OPENCLAW_DIR/agents/main/agent/auth-profiles.json"
if [ -f "$AUTH_SRC" ]; then
  for agent in coder reviewer researcher; do
    cp "$AUTH_SRC" "$OPENCLAW_DIR/agents/$agent/agent/"
    echo "  Copied auth to: agents/$agent/agent/"
  done
  echo ""
  echo "Done! Now add the agents to your openclaw.json (see examples/openclaw.json)"
else
  echo ""
  echo "Warning: $AUTH_SRC not found."
  echo "Run 'openclaw models auth login --provider google-antigravity' first."
fi
