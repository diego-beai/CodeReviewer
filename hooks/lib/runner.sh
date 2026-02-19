#!/usr/bin/env bash
# =============================================================================
# CodeReviewer — hooks/lib/runner.sh
# Hook ligero: sin API calls, sin tokens quemados en cada commit.
#
# Deteccion: React Doctor (gratis) + patron estatico CRITICAL (regex)
# Fixes:     el editor AI en uso, solo cuando el usuario lo pide
#
# Uso: runner.sh <ruta-config> <hook-name>
# =============================================================================

set -euo pipefail

CONFIG_PATH="${1:-}"
HOOK_NAME="${2:-pre-commit}"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Config ───────────────────────────────────────────────────────────────────
read_config() {
  local key="$1" default="$2"
  if [[ -f "$CONFIG_PATH" ]] && command -v python3 &>/dev/null; then
    python3 -c "
import json
try:
    d = json.load(open('$CONFIG_PATH'))
    val = d
    for k in '$key'.split('.'): val = val[k]
    print(str(val).lower() if isinstance(val, bool) else val)
except: print('$default')
" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

TRIGGER=$(read_config "trigger" "pre-commit")
BLOCK_CRITICAL=$(read_config "blocking.on_critical_action" "block")
SCORE_THRESHOLD=$(read_config "blocking.doctor_score_threshold" "50")
BLOCK_SCORE=$(read_config "blocking.on_low_doctor_score" "true")
REPORT_LEVEL=$(read_config "reporting.level" "critical_high")
REPORT_DIR=$(read_config "reporting.report_dir" ".claude-review")
FIX_MODE=$(read_config "auto_fix.mode" "ask")
USE_DOCTOR=$(read_config "tools.react_doctor" "true")

[[ "$HOOK_NAME" == "pre-commit" && "$TRIGGER" == "pre-push"   ]] && exit 0
[[ "$HOOK_NAME" == "pre-push"   && "$TRIGGER" == "pre-commit" ]] && exit 0
[[ "$TRIGGER" == "manual" ]] && exit 0

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────┐${RESET}"
echo -e "${CYAN}${BOLD}│  ⚡ CodeReviewer — ${HOOK_NAME} check           │${RESET}"
echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"

# ─── Archivos staged ─────────────────────────────────────────────────────────
if [[ "$HOOK_NAME" == "pre-commit" ]]; then
  FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
else
  LOCAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  FILES=$(git diff --name-only "origin/${LOCAL_BRANCH}" 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || \
          git diff --name-only HEAD~1 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
fi

if [[ -z "$FILES" ]]; then
  echo -e "${GREEN}  ✓ Sin archivos React. Continuando.${RESET}"
  echo ""
  exit 0
fi

FILE_COUNT=$(echo "$FILES" | grep -c . || echo 0)
echo -e "${CYAN}  ${FILE_COUNT} archivo(s) React en staging${RESET}"
echo ""

FOUND_CRITICAL=false
STATIC_ISSUES=""
DOCTOR_SCORE=-1
DOCTOR_ISSUES=""

# ─── [1] Deteccion estatica CRITICAL (sin API, sin tokens) ────────────────────
# Solo busca los dos patrones CRITICAL mas importantes con grep
echo -e "${CYAN}${BOLD}  [1/2] Deteccion estatica${RESET}"

while IFS= read -r file; do
  [[ -f "$file" ]] || continue

  # async-parallel: dos o mas awaits seguidos en el mismo bloque
  AWAIT_LINES=$(grep -n "^\s*\(const\|let\)\s.*=\s*await\s" "$file" 2>/dev/null || true)
  if [[ $(echo "$AWAIT_LINES" | grep -c . || echo 0) -ge 2 ]]; then
    # Verificar que son consecutivos (numeros de linea proximos)
    CONSECUTIVE=$(echo "$AWAIT_LINES" | awk -F: 'prev && $1-prev<=3{found=1} {prev=$1} END{print found+0}')
    if [[ "$CONSECUTIVE" -ge 1 ]]; then
      FOUND_CRITICAL=true
      STATIC_ISSUES+="  ${RED}[CRITICAL]${RESET} ${BOLD}${file}${RESET} — async-parallel\n"
      STATIC_ISSUES+="    Awaits secuenciales detectados. Usa Promise.all([...])\n\n"
    fi
  fi

  # bundle-barrel-imports: imports desde carpeta sin archivo especifico
  BARREL=$(grep -n "^import.*from '\.\./[a-zA-Z]*'" "$file" 2>/dev/null | grep -v "\.[a-zA-Z]*'" || true)
  if [[ -n "$BARREL" ]]; then
    # Comprobar que existe un index.ts en esa carpeta
    while IFS= read -r bline; do
      DIR=$(echo "$bline" | grep -o "'\.\./[a-zA-Z]*'" | tr -d "'" | sed "s|^\.\./||")
      BASEDIR=$(dirname "$file")
      if [[ -f "${BASEDIR}/../${DIR}/index.ts" ]] || [[ -f "${BASEDIR}/../${DIR}/index.tsx" ]]; then
        FOUND_CRITICAL=true
        STATIC_ISSUES+="  ${RED}[CRITICAL]${RESET} ${BOLD}${file}${RESET} — bundle-barrel-imports\n"
        STATIC_ISSUES+="    Import desde barrel detectado. Importa directamente desde el archivo fuente.\n\n"
        break
      fi
    done <<< "$BARREL"
  fi

done <<< "$FILES"

if [[ -z "$STATIC_ISSUES" ]]; then
  echo -e "  ${GREEN}  ✓ Sin violaciones CRITICAL${RESET}"
else
  printf '%b' "$STATIC_ISSUES"
fi
echo ""

# ─── [2] React Doctor (sin API, sin tokens) ───────────────────────────────────
if [[ "$USE_DOCTOR" == "true" ]]; then
  echo -e "${CYAN}${BOLD}  [2/2] React Doctor${RESET}"

  if ! command -v npx &>/dev/null; then
    echo -e "  ${YELLOW}  ⚠ npx no disponible${RESET}"
  else
    DOCTOR_RAW=$(npx react-doctor 2>/dev/null || echo "")

    if [[ -n "$DOCTOR_RAW" ]]; then
      DOCTOR_SCORE=$(echo "$DOCTOR_RAW" | python3 -c "
import sys, re, json
c = sys.stdin.read()
try:
    d = json.loads(c)
    print(d.get('score', d.get('totalScore', -1)))
except:
    m = re.search(r'(\d+)\s*/\s*100', c)
    print(m.group(1) if m else -1)
" 2>/dev/null || echo "-1")

      DOCTOR_ISSUES="$DOCTOR_RAW"

      if [[ "$DOCTOR_SCORE" != "-1" ]]; then
        if [[ "$BLOCK_SCORE" == "true" ]] && [[ "$DOCTOR_SCORE" -lt "$SCORE_THRESHOLD" ]]; then
          FOUND_CRITICAL=true
          echo -e "  ${RED}  ✗ Score: ${BOLD}${DOCTOR_SCORE}/100${RESET} ${RED}(umbral: ${SCORE_THRESHOLD})${RESET}"
        elif [[ "$DOCTOR_SCORE" -lt 70 ]]; then
          echo -e "  ${YELLOW}  ⚠ Score: ${BOLD}${DOCTOR_SCORE}/100${RESET}"
        else
          echo -e "  ${GREEN}  ✓ Score: ${BOLD}${DOCTOR_SCORE}/100${RESET}"
        fi

        # Mostrar solo los warnings relevantes del nivel configurado
        case "$REPORT_LEVEL" in
          critical)
            echo "$DOCTOR_RAW" | grep -i "error\|critical" | head -5 | sed 's/^/    /' || true ;;
          critical_high)
            echo "$DOCTOR_RAW" | grep -i "error\|critical\|warning" | head -8 | sed 's/^/    /' || true ;;
          *)
            echo "$DOCTOR_RAW" | grep -E "^  ⚠|^  ✓|^  ✗" | head -10 | sed 's/^/  /' || true ;;
        esac
      fi
    else
      echo -e "  ${YELLOW}  ⚠ react-doctor sin output${RESET}"
    fi
  fi
  echo ""
fi

# ─── Guardar reporte ligero ───────────────────────────────────────────────────
mkdir -p "$REPORT_DIR"
TS=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="$REPORT_DIR/${HOOK_NAME}-${TS}.txt"
{
  echo "CodeReviewer — $HOOK_NAME — $TS"
  echo "Files: $FILE_COUNT"
  echo "Doctor score: $DOCTOR_SCORE"
  echo "Found critical: $FOUND_CRITICAL"
  echo ""
  [[ -n "$STATIC_ISSUES" ]] && printf '%b' "$STATIC_ISSUES"
  [[ -n "$DOCTOR_ISSUES" ]] && echo "$DOCTOR_ISSUES"
} > "$REPORT_FILE" 2>/dev/null || true

# ─── Detectar editor para sugerir fix ────────────────────────────────────────
detect_editor() {
  command -v claude &>/dev/null && echo "claude" && return
  command -v codex  &>/dev/null && echo "codex"  && return
  [[ -d ".cursor" ]]            && echo "cursor" && return
  echo "none"
}
FIX_EDITOR=$(detect_editor)

suggest_fix_command() {
  # Solo sugiere el comando, NO lo ejecuta automaticamente
  # Los fixes con AI se hacen bajo demanda, no en cada commit
  case "$FIX_EDITOR" in
    claude)
      echo -e "  ${DIM}Para aplicar fixes: ${CYAN}npm run review${RESET}${DIM} o ${CYAN}/vercel-react-review${RESET}${DIM} en Claude Code${RESET}" ;;
    cursor)
      echo -e "  ${DIM}Para aplicar fixes: abre el reporte en Cursor → ${CYAN}${REPORT_FILE}${RESET}" ;;
    codex)
      echo -e "  ${DIM}Para aplicar fixes: ${CYAN}npm run review${RESET}" ;;
    none)
      echo -e "  ${DIM}Reporte en: ${CYAN}${REPORT_FILE}${RESET}" ;;
  esac
}

# ─── Decision final ───────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────┐${RESET}"

if [[ "$FOUND_CRITICAL" == "true" ]]; then
  case "$BLOCK_CRITICAL" in
    warn)
      echo -e "${CYAN}${BOLD}│  Resultado: ${YELLOW}ADVERTENCIA${CYAN} — Commit permitido        │${RESET}"
      echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
      echo ""
      suggest_fix_command
      echo ""
      exit 0
      ;;
    ask)
      echo -e "${CYAN}${BOLD}│  Resultado: ${YELLOW}DECISION REQUERIDA${CYAN}                    │${RESET}"
      echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
      echo ""
      printf "  ${BOLD}¿Continuar de todas formas? [s/N]:${RESET} "
      read -r ans </dev/tty || ans="n"
      ans=$(echo "${ans:-n}" | tr '[:upper:]' '[:lower:]')
      if [[ "$ans" == "s" || "$ans" == "si" || "$ans" == "y" ]]; then
        exit 0
      fi
      suggest_fix_command
      exit 1
      ;;
    block|*)
      echo -e "${CYAN}${BOLD}│  Resultado: ${RED}BLOQUEADO${CYAN} — Corrige antes de continuar │${RESET}"
      echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
      echo ""
      suggest_fix_command
      echo -e "  ${DIM}Para saltar: git commit --no-verify${RESET}"
      echo ""
      exit 1
      ;;
  esac
else
  score_txt=""
  [[ "$DOCTOR_SCORE" != "-1" ]] && score_txt=" — Doctor: ${DOCTOR_SCORE}/100"
  echo -e "${CYAN}${BOLD}│  Resultado: ${GREEN}APROBADO${CYAN}${score_txt}${RESET}"
  echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
  echo ""
  exit 0
fi
