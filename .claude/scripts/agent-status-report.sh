#!/usr/bin/env bash
# Запасной канал статуса агента (fail-safe status reporter)
# see WP-18 — ${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-18.md: Обещание §Фаза 1, Роль §Фаза 3
#
# Интерфейс:  agent-status-report.sh [--session-id ID] <agent> <status> [task] [files-csv]
#   agent   : claude-code | kimi | hermes
#   status  : idle | working | peer-session | blocked
#
# Назначение: детерминированно записать статус агента на сервер (MCP agent_status_update),
#             когда агент сам не вызвал primary-канал. Best-effort:
#             нет токена / нет сети / MCP не отвечает → тихий выход 0 (Stop не ломаем).
#
# Primary-канал этот скрипт НЕ отменяет (MCP-вызов agent_status_update самим агентом).

MCP_URL="https://mcp.aisystant.com/mcp"
TOKEN_PATH="${HOME}/.hermes/mcp-tokens/aisystant.json"

# --- разбор аргументов -------------------------------------------------------
if [ "${1:-}" = "--session-id" ]; then
  # session-id принимается для совместимости с kimi-peer-adapter, серверу не нужен
  shift 2 2>/dev/null || shift $#
fi
AGENT="${1:-}"
STATUS="${2:-}"
TASK="${3:-}"
FILES_CSV="${4:-}"

# Обязательны агент и статус. Иначе — fail-safe молчит.
[ -n "$AGENT" ] && [ -n "$STATUS" ] || exit 0

# --- токен: env → файл; нет токена → спящий режим ----------------------------
TOKEN="${AISYSTANT_MCP_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -r "$TOKEN_PATH" ]; then
  TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("access_token",""))' "$TOKEN_PATH" 2>/dev/null)" || TOKEN=""
fi
[ -n "$TOKEN" ] || exit 0

# --- сборка JSON-RPC тела (python3 — безопасное экранирование) ----------------
BODY="$(python3 - "$AGENT" "$STATUS" "$TASK" "$FILES_CSV" 2>/dev/null <<'PY'
import json, sys
agent, status, task, files = (list(sys.argv[1:5]) + ["", "", "", ""])[:4]
args = {"agent": agent, "status": status}
if task:
    args["task"] = task
if files:
    lst = [f for f in files.split(",") if f]
    if lst:
        args["files"] = lst
print(json.dumps({
    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
    "params": {"name": "agent_status_update", "arguments": args},
}))
PY
)" || exit 0
[ -n "$BODY" ] || exit 0

# --- вызов. Любая ошибка/таймаут → тихо, exit 0 ------------------------------
curl -sS --max-time 5 -X POST "$MCP_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/json, text/event-stream" \
  -H "User-Agent: IWE-Agent/1.0" \
  -d "$BODY" >/dev/null 2>&1 || true

exit 0
