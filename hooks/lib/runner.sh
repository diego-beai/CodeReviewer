#!/usr/bin/env bash
# =============================================================================
# CodeReviewer — hooks/lib/runner.sh
# Deteccion: Vercel React Review + React Doctor
# Fixes: el editor AI en uso (Claude Code, Cursor, Codex)
#
# Uso: runner.sh <ruta-config> <hook-name>
# =============================================================================

set -euo pipefail

CONFIG_PATH="${1:-}"
HOOK_NAME="${2:-pre-commit}"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Leer configuracion ───────────────────────────────────────────────────────
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
USE_VERCEL=$(read_config "tools.vercel_review" "true")
USE_DOCTOR=$(read_config "tools.react_doctor" "true")

# ─── Verificar si este hook debe ejecutarse ───────────────────────────────────
[[ "$HOOK_NAME" == "pre-commit" && "$TRIGGER" == "pre-push" ]] && exit 0
[[ "$HOOK_NAME" == "pre-push"   && "$TRIGGER" == "pre-commit" ]] && exit 0
[[ "$TRIGGER" == "manual" ]] && exit 0

# ─── Detectar editor AI disponible para fixes ─────────────────────────────────
detect_fix_editor() {
  if command -v claude &>/dev/null; then
    echo "claude"
  elif command -v codex &>/dev/null; then
    echo "codex"
  elif [[ -d ".cursor" ]]; then
    echo "cursor"
  else
    echo "none"
  fi
}
FIX_EDITOR=$(detect_fix_editor)

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────┐${RESET}"
if [[ "$HOOK_NAME" == "pre-commit" ]]; then
  echo -e "${CYAN}${BOLD}│  ⚡ CodeReviewer — Pre-commit Review             │${RESET}"
else
  echo -e "${CYAN}${BOLD}│  ⚡ CodeReviewer — Pre-push Review               │${RESET}"
fi
echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"

# ─── Detectar archivos a revisar ─────────────────────────────────────────────
if [[ "$HOOK_NAME" == "pre-commit" ]]; then
  FILES=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
else
  LOCAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  FILES=$(git diff --name-only "origin/${LOCAL_BRANCH}" 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || \
          git diff --name-only HEAD~1 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
fi

if [[ -z "$FILES" ]]; then
  echo -e "${GREEN}  ✓ Sin archivos React en staging. Continuando...${RESET}"
  echo ""
  exit 0
fi

FILE_COUNT=$(echo "$FILES" | grep -c . || echo 0)
echo -e "${CYAN}  Analizando ${BOLD}${FILE_COUNT} archivo(s)${RESET}${CYAN} React...${RESET}"

# ─── Variables de resultado ───────────────────────────────────────────────────
FOUND_CRITICAL=false
DOCTOR_SCORE=-1
DOCTOR_ISSUES=""
VERCEL_JSON=""

# ─── [1/2] Vercel React Review (via Claude) ───────────────────────────────────
run_vercel_review() {
  [[ "$USE_VERCEL" != "true" ]] && return 0
  echo ""
  echo -e "${CYAN}${BOLD}  [1/2] Vercel React Review${RESET}"

  if ! command -v claude &>/dev/null; then
    echo -e "      ${YELLOW}⚠ Claude Code CLI no disponible — saltando${RESET}"
    return 0
  fi

  # Construir prompt con el contenido de los archivos
  local files_content=""
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    files_content+="### File: $file\n\`\`\`typescript\n$(cat "$file")\n\`\`\`\n\n"
  done <<< "$FILES"

  local toolkit_dir
  toolkit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local prompt_file="$toolkit_dir/prompts/pre-commit-review.md"
  local prompt

  if [[ -f "$prompt_file" ]]; then
    prompt=$(sed "s|{{FILES_CONTENT}}|$files_content|g" "$prompt_file")
  else
    prompt="Review these React files for async-parallel, bundle-barrel-imports, boolean-props, derived-state-in-useEffect violations. Output JSON: {has_critical, findings:[{file,line,rule,severity,problem,fix}], summary}. Files:\n$files_content"
  fi

  local raw_output
  raw_output=$(echo "$prompt" | claude --no-header -p 2>/dev/null || echo '{"has_critical":false,"findings":[],"summary":"Error"}')

  VERCEL_JSON=$(echo "$raw_output" | python3 -c "
import sys, json, re
content = sys.stdin.read()
match = re.search(r'\{.*\}', content, re.DOTALL)
if match:
    try: print(json.dumps(json.loads(match.group())))
    except: print('{\"has_critical\":false,\"findings\":[],\"summary\":\"Parse error\"}')
else:
    print('{\"has_critical\":false,\"findings\":[],\"summary\":\"No JSON\"}')
" 2>/dev/null || echo '{"has_critical":false,"findings":[],"summary":"Error"}')

  local has_critical findings_count summary
  has_critical=$(echo "$VERCEL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('has_critical') else 'false')" 2>/dev/null || echo "false")
  findings_count=$(echo "$VERCEL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('findings',[])))" 2>/dev/null || echo "0")
  summary=$(echo "$VERCEL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('summary',''))" 2>/dev/null || echo "")

  [[ "$has_critical" == "true" ]] && FOUND_CRITICAL=true

  if [[ "$findings_count" -eq 0 ]]; then
    echo -e "      ${GREEN}✓ Sin violaciones — $summary${RESET}"
  else
    export REPORT_LEVEL
    echo "$VERCEL_JSON" | python3 - << 'PYEOF'
import sys, json, os
data     = json.load(sys.stdin)
level    = os.environ.get('REPORT_LEVEL', 'critical_high')
findings = data.get('findings', [])
colors   = {'CRITICAL':'\033[0;31m','HIGH':'\033[1;33m','MEDIUM':'\033[0;33m','LOW':'\033[0;37m'}
reset, bold = '\033[0m', '\033[1m'

def show(sev):
    if level == 'critical':             return sev == 'CRITICAL'
    if level == 'critical_high':        return sev in ('CRITICAL','HIGH')
    if level == 'critical_high_medium': return sev != 'LOW'
    return True

for f in findings:
    sev = f.get('severity','LOW')
    if not show(sev): continue
    c = colors.get(sev, reset)
    print(f"      {c}[{sev}]{reset} {bold}{f.get('file','')}:{f.get('line','?')}{reset}")
    print(f"        Regla:    {f.get('rule','')}")
    print(f"        Problema: {f.get('problem','')}")
    print(f"        Fix:      {f.get('fix','')}")
    print()
PYEOF
    echo -e "      ${DIM}$summary${RESET}"
  fi
}

# ─── [2/2] React Doctor (deteccion) ──────────────────────────────────────────
run_doctor() {
  [[ "$USE_DOCTOR" != "true" ]] && return 0
  echo ""
  echo -e "${CYAN}${BOLD}  [2/2] React Doctor${RESET}"

  if ! command -v npx &>/dev/null; then
    echo -e "      ${YELLOW}⚠ npx no disponible — saltando${RESET}"
    return 0
  fi

  # Capturar output completo de react-doctor
  local raw_output
  raw_output=$(npx react-doctor 2>/dev/null || echo "")

  if [[ -z "$raw_output" ]]; then
    echo -e "      ${YELLOW}⚠ react-doctor sin output${RESET}"
    return 0
  fi

  # Extraer score
  DOCTOR_SCORE=$(echo "$raw_output" | python3 -c "
import sys, re, json
content = sys.stdin.read()
try:
    data = json.loads(content)
    print(data.get('score', data.get('totalScore', -1)))
except:
    m = re.search(r'[Ss]core[:\s]+(\d+)', content)
    print(m.group(1) if m else -1)
" 2>/dev/null || echo "-1")

  # Guardar issues para pasarlos al editor de fixes
  DOCTOR_ISSUES="$raw_output"

  # Mostrar score
  if [[ "$DOCTOR_SCORE" != "-1" ]]; then
    if [[ "$BLOCK_SCORE" == "true" ]] && [[ "$DOCTOR_SCORE" -lt "$SCORE_THRESHOLD" ]]; then
      FOUND_CRITICAL=true
      echo -e "      ${RED}✗ Score: ${BOLD}${DOCTOR_SCORE}/100${RESET} ${RED}(umbral: ${SCORE_THRESHOLD})${RESET}"
    elif [[ "$DOCTOR_SCORE" -lt 70 ]]; then
      echo -e "      ${YELLOW}⚠ Score: ${BOLD}${DOCTOR_SCORE}/100${RESET} ${DIM}(recomendado >70)${RESET}"
    else
      echo -e "      ${GREEN}✓ Score: ${BOLD}${DOCTOR_SCORE}/100${RESET}"
    fi
    # Mostrar primeras lineas del reporte (issues detectados)
    echo "$raw_output" | grep -E "(error|warning|issue|problem|fix)" -i | head -6 | sed 's/^/        /' || true
  fi
}

# ─── Ejecutar revisiones ──────────────────────────────────────────────────────
run_vercel_review
run_doctor

echo ""

# ─── Guardar reporte ──────────────────────────────────────────────────────────
mkdir -p "$REPORT_DIR"
TS=$(date +%Y%m%d-%H%M%S)
REPORT_FILE="$REPORT_DIR/${HOOK_NAME}-${TS}.json"
python3 - << PYEOF > "$REPORT_FILE" 2>/dev/null || true
import json
vercel = {}
try: vercel = json.loads('''${VERCEL_JSON:-{}}''')
except: pass
print(json.dumps({
    "timestamp": "${TS}",
    "hook": "${HOOK_NAME}",
    "doctor_score": ${DOCTOR_SCORE},
    "found_critical": ${FOUND_CRITICAL},
    "vercel_review": vercel
}, indent=2))
PYEOF

# ─── Aplicar fixes con el editor activo ───────────────────────────────────────
apply_fixes_with_editor() {
  # Construir lista de issues de ambas herramientas para el editor
  local issues_for_editor=""

  # Issues de Vercel Review
  if [[ -n "$VERCEL_JSON" ]]; then
    local vercel_issues
    vercel_issues=$(echo "$VERCEL_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
findings = [f for f in d.get('findings',[]) if f.get('severity') in ('CRITICAL','HIGH')]
for f in findings:
    print(f\"[{f.get('severity')}] {f.get('file')}:{f.get('line')} — {f.get('rule')}\")
    print(f\"  Problema: {f.get('problem')}\")
    print(f\"  Fix: {f.get('fix')}\")
    print()
" 2>/dev/null || true)
    [[ -n "$vercel_issues" ]] && issues_for_editor+="=== Vercel React Review ===\n$vercel_issues\n"
  fi

  # Issues de React Doctor
  if [[ -n "$DOCTOR_ISSUES" ]]; then
    issues_for_editor+="=== React Doctor ===\n$DOCTOR_ISSUES\n"
  fi

  [[ -z "$issues_for_editor" ]] && return 0

  echo -e "  ${CYAN}${BOLD}Fixes disponibles — Editor detectado: ${BOLD}${FIX_EDITOR}${RESET}"
  echo ""

  case "$FIX_EDITOR" in
    claude)
      local confirmed=false
      if [[ "$FIX_MODE" == "auto" ]]; then
        confirmed=true
      elif [[ "$FIX_MODE" == "ask" ]]; then
        printf "  ${BOLD}¿Aplicar fixes con Claude Code? [s/N]:${RESET} "
        read -r ans </dev/tty || ans="n"
        ans=$(echo "${ans:-n}" | tr '[:upper:]' '[:lower:]')
        [[ "$ans" == "s" || "$ans" == "si" || "$ans" == "y" ]] && confirmed=true
      fi

      if [[ "$confirmed" == "true" ]]; then
        echo ""
        echo -e "  ${CYAN}Claude Code aplicando fixes...${RESET}"
        local fix_prompt="You are fixing a React/TypeScript project. Apply the following fixes found by React Doctor and Vercel React Review.

Rules:
- Only fix CRITICAL and HIGH severity issues
- Make minimal, surgical changes — do not refactor surrounding code
- Never break existing functionality
- Apply each fix directly to its file using the Edit tool

Issues to fix:
$(printf '%b' "$issues_for_editor")"

        echo "$fix_prompt" | claude --no-header -p 2>/dev/null && \
          echo -e "\n  ${GREEN}✓ Fixes aplicados. Revisa los cambios y vuelve a hacer commit.${RESET}" || \
          echo -e "\n  ${YELLOW}  No se pudieron aplicar todos los fixes.${RESET}"
      fi
      ;;

    codex)
      if [[ "$FIX_MODE" != "report_only" ]]; then
        printf "  ${BOLD}¿Aplicar fixes con Codex? [s/N]:${RESET} "
        read -r ans </dev/tty || ans="n"
        ans=$(echo "${ans:-n}" | tr '[:upper:]' '[:lower:]')
        if [[ "$ans" == "s" || "$ans" == "si" || "$ans" == "y" ]]; then
          echo ""
          echo -e "  ${CYAN}Codex aplicando fixes...${RESET}"
          printf '%b' "$issues_for_editor" | codex "Fix these React issues in the project files. Only fix CRITICAL and HIGH severity. Make minimal changes." 2>/dev/null && \
            echo -e "\n  ${GREEN}✓ Fixes aplicados por Codex.${RESET}" || \
            echo -e "\n  ${YELLOW}  Codex no pudo aplicar los fixes.${RESET}"
        fi
      fi
      ;;

    cursor)
      # Cursor no tiene CLI — guardar issues en archivo para abrir en el editor
      local cursor_file="$REPORT_DIR/cursor-fixes-${TS}.md"
      {
        echo "# CodeReviewer — Fixes pendientes"
        echo ""
        echo "Abre este archivo en Cursor y pide: **\"Apply all fixes listed here\"**"
        echo ""
        printf '%b' "$issues_for_editor"
      } > "$cursor_file"
      echo -e "  ${CYAN}Abre en Cursor y pide que aplique los fixes:${RESET}"
      echo -e "  ${BOLD}${cursor_file}${RESET}"
      ;;

    none)
      echo -e "  ${YELLOW}No se detectó editor AI disponible.${RESET}"
      echo -e "  ${DIM}Instala Claude Code: npm install -g @anthropic-ai/claude-code${RESET}"
      echo -e "  ${DIM}O abre el reporte en tu editor: ${REPORT_FILE}${RESET}"
      ;;
  esac

  echo ""
}

# ─── Decision final ───────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────┐${RESET}"

if [[ "$FOUND_CRITICAL" == "true" ]]; then
  case "$BLOCK_CRITICAL" in
    warn)
      echo -e "${CYAN}${BOLD}│  Resultado: ${YELLOW}ADVERTENCIA${CYAN} — Commit permitido        │${RESET}"
      echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
      echo ""
      echo -e "  ${DIM}Reporte: ${REPORT_FILE}${RESET}"
      echo ""
      apply_fixes_with_editor
      exit 0
      ;;

    ask)
      echo -e "${CYAN}${BOLD}│  Resultado: ${YELLOW}DECISION REQUERIDA${CYAN}                    │${RESET}"
      echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
      echo ""
      printf "  ${BOLD}¿Continuar de todas formas? [s/N]:${RESET} "
      read -r user_ans </dev/tty || user_ans="n"
      user_ans=$(echo "${user_ans:-n}" | tr '[:upper:]' '[:lower:]')
      if [[ "$user_ans" == "s" || "$user_ans" == "si" || "$user_ans" == "y" ]]; then
        echo ""
        exit 0
      fi
      apply_fixes_with_editor
      exit 1
      ;;

    block|*)
      echo -e "${CYAN}${BOLD}│  Resultado: ${RED}BLOQUEADO${CYAN} — Corrige antes de continuar │${RESET}"
      echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
      echo ""
      echo -e "  ${DIM}Reporte: ${REPORT_FILE}${RESET}"
      echo -e "  ${DIM}Para saltar: git commit --no-verify${RESET}"
      echo ""
      apply_fixes_with_editor
      exit 1
      ;;
  esac
else
  local summary_text="Aprobado"
  [[ "$DOCTOR_SCORE" != "-1" ]] && summary_text="Score React Doctor: ${DOCTOR_SCORE}/100"
  echo -e "${CYAN}${BOLD}│  Resultado: ${GREEN}APROBADO${CYAN} — ${summary_text}${RESET}"
  echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
  echo -e "  ${DIM}Reporte: ${REPORT_FILE}${RESET}"
  echo ""
fi
