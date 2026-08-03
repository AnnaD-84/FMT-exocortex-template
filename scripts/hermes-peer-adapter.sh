#!/usr/bin/env bash
# hermes-peer-adapter.sh — адаптер Hermes для peer-conversation (роль напарника)
# see DP.SC.154, DP.SC.167 (симметричный аналог claude-peer-adapter.sh)
# WP-392 Ф10, WP-509
#
# Вызывается агентом-ПИСАТЕЛЕМ (Claude, Kimi или другим) когда Hermes выступает НАПАРНИКОМ.
# Читает промпт из stdin, отправляет в Hermes через нативный CLI `hermes chat -q`,
# возвращает ответ в stdout.
#
# Использование (из скрипта агента-писателя):
#   bash scripts/hermes-peer-adapter.sh [--session-id "$HERMES_SESSION_ID"] \
#     < "${SESSION_DIR}/peer-prompt.md" > "$PEER_FILE" 2>/dev/null
# Промпт передаётся файлом, не inline `echo "$peer_prompt" | ...` — иначе текст
# промпта попадает в командную строку и хук B7.7c ложно блокирует повторные
# вызовы (bug-2026-06-30-peer-adapter-b77c-block).
#
# Переменные окружения:
#   HERMES_BIN         — путь к hermes CLI (default: first `hermes` in PATH)
#   HERMES_SESSION_ID  — ID сессии для продолжения диалога (опционально)
#   HERMES_MAX_TURNS   — лимит итераций (default: 1, peer-сессия не использует инструменты)

set -euo pipefail

HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_HERMES_START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

SESSION_ID="${HERMES_SESSION_ID:-}"
MAX_TURNS="${HERMES_MAX_TURNS:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id) SESSION_ID="$2"; shift 2 ;;
    *)            shift ;;
  esac
done

if [ -z "$HERMES_BIN" ] || [ ! -x "$HERMES_BIN" ]; then
  echo "ERROR: hermes binary not found. Install Hermes Agent CLI or set HERMES_BIN env var." >&2
  exit 1
fi

# Читаем промпт из stdin
PROMPT=$(cat)

if [ -z "$PROMPT" ]; then
  echo "ERROR: empty prompt from stdin" >&2
  exit 1
fi

# === Запуск Hermes headless: `hermes chat -q ... -Q --max-turns 1` + 5min timeout ===
# -Q (quiet) убирает баннер/спиннер; --max-turns 1 ограничивает рамку одним ответом.
# Запрос обрезается до 4000 символов — симметрия с оригинальным MCP-адаптером.
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hermes-peer-XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

OUT_FILE="$TMP_ROOT/hermes-output.txt"
TRUNCATED_PROMPT=$(printf '%s' "$PROMPT" | head -c 4000)

HERMES_ARGS=(chat -q "$TRUNCATED_PROMPT" -Q --max-turns "$MAX_TURNS")
if [ -n "$SESSION_ID" ]; then
  HERMES_ARGS+=(--resume "$SESSION_ID")
fi

perl -e 'alarm 300; exec @ARGV' -- "$HERMES_BIN" "${HERMES_ARGS[@]}" > "$OUT_FILE" 2>&1
PERL_EXIT=$?

if [ "$PERL_EXIT" -eq 142 ]; then
  echo "ERROR: Hermes peer call timed out after 5 minutes (SIGALRM)" >&2
  exit 1
fi

if [ ! -s "$OUT_FILE" ]; then
  echo "ERROR: hermes returned empty output" >&2
  exit 1
fi

# Убираем служебную строку session_id из начала ответа (hermes -Q всё ещё печатает session_id)
# и ведущие пустые строки, но сохраняем внутренние переносы.
RESPONSE=$(tail -n +2 "$OUT_FILE" | sed -e '/./,$!d')

# === WP-454: write to agent-sessions journal (best-effort, non-blocking) ===
# Security: only timestamps and duration written — no content from RESPONSE.
{
  _HERMES_END_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  _SID="${SESSION_ID:-hermes-standalone-$$}"
  python3 -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR/lib')
from datetime import datetime
from agent_session_time import write_journal_entry

start_s, end_s, sid = sys.argv[1:4]
fmt = lambda s: datetime.fromisoformat(s.replace('Z', '+00:00'))
try:
    agent_h = round((fmt(end_s) - fmt(start_s)).total_seconds() / 3600, 4)
except ValueError:
    agent_h = 0.0
write_journal_entry('hermes', sid, start_s[:10], start_s, end_s, agent_active_h=agent_h)
" "$_HERMES_START_TIME" "$_HERMES_END_TIME" "$_SID"
} 2>/dev/null &

echo "$RESPONSE"
