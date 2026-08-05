#!/bin/bash
# claude-peer-adapter.sh — адаптер Claude для peer-conversation (роль напарника)
# see DP.SC.154 (симметричный аналог kimi-peer-adapter.sh)
#
# Вызывается агентом-ПИСАТЕЛЕМ (Kimi или другим) когда Claude выступает НАПАРНИКОМ.
# Принимает аргументы в стиле kimi-peer-adapter.sh, читает промпт из stdin,
# передаёт Claude headless (-p), возвращает ответ в stdout.
#
# Контракт безопасности (WP-458, WP-510): адаптер принимает только текстовую
# проекцию через stdin. Он не получает рабочих каталогов и не даёт Claude
# файловые или shell-инструменты.
# Использование:
#   bash scripts/claude-peer-adapter.sh < peer-prompt.md > peer.md 2> peer.err
# Промпт передаётся файлом, не inline `echo "$peer_prompt" | ...` — иначе текст
# промпта попадает в командную строку и хук B7.7c ложно блокирует повторные
# вызовы (bug-2026-06-30-peer-adapter-b77c-block).

set -euo pipefail

# CLAUDE_BIN auto-detect: env override → PATH → user-local fallbacks.
# Системные пути (homebrew, /usr/local/bin) обычно в PATH и подхватываются через command -v.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
if [ -z "$CLAUDE_BIN" ]; then
  for candidate in \
    "$HOME/.local/bin/claude" \
    "$HOME/.npm-global/bin/claude" \
    "$HOME/.nvm/versions/node/*/bin/claude"; do
    # Expand glob (для nvm-paths)
    for resolved in $candidate; do
      [ -x "$resolved" ] && CLAUDE_BIN="$resolved" && break 2
    done
  done
fi
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
  echo "ERROR: claude binary not found. Install Claude CLI or set CLAUDE_BIN env var." >&2
  echo "  Install: https://docs.claude.com/en/docs/claude-code/setup" >&2
  exit 1
fi

# Модель не выбирает адаптер: без явного --model Claude CLI применяет свою
# настроенную по умолчанию модель. Это сохраняет разделение между личностью,
# каналом и конструктивной реализацией.
MODEL_ARG=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)              shift ;;
    --model)         MODEL_ARG=("--model" "$2"); shift 2 ;;
    --add-dir)
      echo "ERROR: --add-dir is disabled for claude-peer-adapter.sh. Put a minimal text projection in stdin instead." >&2
      exit 64
      ;;
    --permission-mode)
      echo "ERROR: permission mode is fixed to plan for claude-peer-adapter.sh." >&2
      exit 64
      ;;
    *)               shift ;;
  esac
done

# Модель передаётся только при явном выборе вызывающего агента. Адаптер не
# назначает и не подменяет конструктивную реализацию напарника.

# WP-394 Ф2.4: --exclude-dynamic-system-prompt-sections moves per-machine sections
# (cwd, env, memory paths, git status) from system prompt to first user message.
# → stable byte-identical prefix across turns → higher cross-turn prompt-cache reuse.
# Only applies with default system prompt (no --system-prompt passed here).
#
# `plan` plus an explicit deny-list makes the peer a text-only reviewer at the
# Claude Code tool-policy layer. --add-dir expands file access and must never be
# used as a claimed sandbox. Sensitive material still requires an OS-level
# isolated runner; this adapter is not such a runner.
#
# perl alarm 300: 5-minute hard timeout, same as kimi-peer-adapter.sh.
# On timeout: SIGALRM → exit 142 → caller sees exit≠0 + empty file → reports to pilot.
CLAUDE_STDERR="$(mktemp)"
trap 'rm -f "$CLAUDE_STDERR"' EXIT

CLAUDE_OUTPUT=$(perl -e 'alarm 300; exec @ARGV' -- \
  "$CLAUDE_BIN" -p \
  --exclude-dynamic-system-prompt-sections \
  --permission-mode plan \
  --max-turns 1 \
  --disallowedTools "Read,Edit,Write,Bash,Glob,Grep,WebFetch,WebSearch" \
  ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
  "$@" 2>"$CLAUDE_STDERR") && CLAUDE_EXIT=0 || CLAUDE_EXIT=$?

# Auth-failure detection (peer-session 2026-08-04-08-wp7-f44-sandbox-review):
# macOS Keychain can be unreachable from a sandboxed child process (e.g. a
# Codex workspace-write sandbox) even when the pilot's own Claude Code login
# is valid — that surfaces as literal "Not logged in" text, not necessarily a
# non-zero exit. stderr is checked unconditionally (diagnostic channel);
# stdout only when the process itself also exited non-zero, so a genuine
# reply that happens to discuss login/auth text isn't misclassified as a
# failure (this environment discusses login issues often).
AUTH_PATTERN='Not logged in|Please run.*login'
if grep -qE "$AUTH_PATTERN" "$CLAUDE_STDERR" 2>/dev/null || \
   { [ "$CLAUDE_EXIT" -ne 0 ] && printf '%s' "$CLAUDE_OUTPUT" | grep -qE "$AUTH_PATTERN"; }; then
  echo "ERROR: Claude peer call looks unauthenticated (Not logged in). Common sandbox/Keychain artifact, not necessarily lost login — verify from a trusted terminal before re-running /login." >&2
  if [ -s "$CLAUDE_STDERR" ]; then
    echo "--- claude stderr (tail) ---" >&2
    tail -20 "$CLAUDE_STDERR" >&2
  fi
  exit 4
fi

# Empty output must stay a zero-byte file (contract: exit≠0 + empty file →
# caller reports "peer didn't answer") — printf with %s\n would otherwise
# write a lone newline for a truly empty CLAUDE_OUTPUT, found in cold review
# of peer-session 2026-08-04-08-wp7-f44-sandbox-review.
[ -n "$CLAUDE_OUTPUT" ] && printf '%s\n' "$CLAUDE_OUTPUT"
exit "$CLAUDE_EXIT"
