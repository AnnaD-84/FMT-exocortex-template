#!/usr/bin/env bash
# routing: utility  deterministic=true
# check-orphan-hooks.sh — каждый хук в .claude/hooks/ действительно вызывается
#
# Класс дефекта (issue #310, #323): скрипт-страж лежит в .claude/hooks/, объявлен в
# CLAUDE.md блокирующим, но не зарегистрирован ни в одном событии settings.json и не
# вызывается ни из одного другого хука. Он не срабатывает никогда — и об этом никто
# не узнаёт, потому что «не сработал» выглядит ровно как «нарушений не было».
# Так прожили IntegrationGate (rule-engine.sh) и ResidencyGate (residency-gate-*.sh).
#
# Достижимость считается транзитивно: хук из settings.json может запускать другие
# (capture-bus.sh → детекторы), такие вызовы тоже считаются подключением.
#
# Осознанно не подключённые хуки перечисляются в .claude/hooks/.orphan-allowlist
# (одна строка = имя файла, `#` — комментарий с причиной). Файл в allowlist остаётся
# видимым в отчёте, но не роняет проверку: цель сторожа — чтобы «не подключён»
# было решением, а не случайностью.
#
# Использование: bash scripts/check-orphan-hooks.sh [FMT_DIR]

set -uo pipefail

FMT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOKS_DIR="$FMT_DIR/.claude/hooks"
SETTINGS="$FMT_DIR/.claude/settings.json"
ALLOWLIST="$HOOKS_DIR/.orphan-allowlist"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "SKIP: $HOOKS_DIR не найден"
    exit 0
fi
if [ ! -f "$SETTINGS" ]; then
    echo "SKIP: $SETTINGS не найден — определить подключение невозможно"
    exit 0
fi

# Стартовое множество: всё, на что ссылается settings.json.
# Разделитель — пробел, а не перевод строки: членство проверяется шаблоном
# `*" $name "*`, и на переводах строк он не совпадал бы ни с чем (все хуки
# отчитывались как неподключённые при первом же прогоне).
reachable=" $(grep -oE '[A-Za-z0-9_.-]+\.sh' "$SETTINGS" | sort -u | tr '\n' ' ')"

# Транзитивное замыкание: хук, уже признанный достижимым, подтягивает те, что вызывает.
# Итераций ровно столько, сколько хуков — больше цепочка быть не может.
hook_count=$(find "$HOOKS_DIR" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')
for _ in $(seq 1 "$hook_count"); do
    added=""
    for name in $reachable; do
        src="$HOOKS_DIR/$name"
        [ -f "$src" ] || continue
        while IFS= read -r ref; do
            case " $reachable $added " in
                *" $ref "*) ;;
                *) [ -f "$HOOKS_DIR/$ref" ] && added="$added $ref" ;;
            esac
        done < <(grep -oE '[A-Za-z0-9_.-]+\.sh' "$src" | sort -u)
    done
    [ -z "$added" ] && break
    reachable="$reachable $added"
done

# Причина живёт в той же строке после `#`, поэтому имя — первое поле до комментария.
# `tr -d ' '` по всей строке склеивал бы имя с причиной и allowlist не срабатывал.
allow=" "
if [ -f "$ALLOWLIST" ]; then
    allow=" $(sed 's/#.*//' "$ALLOWLIST" | awk 'NF {print $1}' | tr '\n' ' ')"
fi

orphans=0
allowed=0
libraries=0
for path in "$HOOKS_DIR"/*.sh; do
    [ -f "$path" ] || continue
    name=$(basename "$path")
    case " $reachable " in *" $name "*) continue ;; esac
    # `claude-hook: false` in the header = library/CLI shipped alongside hooks,
    # not registerable in settings.json by contract (issues #310, #323).
    # Same marker setup/validate-template.sh honors — keep recognizers in sync.
    if head -3 "$path" | grep -q '^# claude-hook: false — '; then
        echo "LIBRARY: $name — не хук по контракту (claude-hook: false), подключение в settings.json не требуется"
        libraries=$((libraries + 1))
        continue
    fi
    case " $allow " in
        *" $name "*)
            echo "ALLOWED: $name — не подключён осознанно (см. .claude/hooks/.orphan-allowlist)"
            allowed=$((allowed + 1))
            continue ;;
    esac
    echo "FAIL: $name лежит в .claude/hooks/, но не вызывается ни из settings.json, ни из другого хука"
    echo "  Либо зарегистрируйте его в событии settings.json, либо удалите,"
    echo "  либо внесите в .claude/hooks/.orphan-allowlist с причиной."
    orphans=$((orphans + 1))
done

if [ "$orphans" -eq 0 ]; then
    echo "PASS: все хуки подключены ($allowed осознанно не подключены, $libraries библиотек вне контракта хуков)"
    exit 0
fi

echo ""
echo "Не подключено хуков: $orphans"
exit 1
