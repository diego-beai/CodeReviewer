#!/usr/bin/env bash
# =============================================================================
# CodeReviewer — hooks/lib/runner.sh
# Nucleo de la revision. Llamado por pre-commit y pre-push.
# Lee .claude-toolkit.config.json y actua segun la configuracion del proyecto.
#
# Uso: runner.sh <ruta-config> <hook-name>
#   hook-name: "pre-commit" | "pre-push"
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
  local key="$1"
  local default="$2"
  if [[ -f "$CONFIG_PATH" ]] && command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
try:
    d = json.load(open('$CONFIG_PATH'))
    keys = '$key'.split('.')
    val = d
    for k in keys:
        val = val[k]
    print(str(val).lower() if isinstance(val, bool) else val)
except:
    print('$default')
" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

# Cargar config
TRIGGER=$(read_config "trigger" "pre-commit")
BLOCK_CRITICAL=$(read_config "blocking.on_critical_action" "block")
BLOCK_SCORE=$(read_config "blocking.on_low_doctor_score" "true")
SCORE_THRESHOLD=$(read_config "blocking.doctor_score_threshold" "50")
REPORT_LEVEL=$(read_config "reporting.level" "critical_high")
REPORT_DIR=$(read_config "reporting.report_dir" ".claude-review")
FIX_MODE=$(read_config "auto_fix.mode" "ask")
USE_VERCEL=$(read_config "tools.vercel_review" "true")
USE_DOCTOR=$(read_config "tools.react_doctor" "true")

# ─── Verificar que este hook debe ejecutarse segun la config ──────────────────
# Si el usuario configuro "pre-push", el pre-commit no debe ejecutarse
if [[ "$HOOK_NAME" == "pre-commit" && "$TRIGGER" == "pre-push" ]]; then exit 0; fi
if [[ "$HOOK_NAME" == "pre-push"   && "$TRIGGER" == "pre-commit" ]]; then exit 0; fi
if [[ "$TRIGGER" == "manual" ]]; then exit 0; fi

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────┐${RESET}"

if [[ "$HOOK_NAME" == "pre-commit" ]]; then
  echo -e "${CYAN}${BOLD}│  ⚡ Claude React Toolkit — Pre-commit Review     │${RESET}"
else
  echo -e "${CYAN}${BOLD}│  ⚡ Claude React Toolkit — Pre-push Review       │${RESET}"
fi
echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"

# ─── Detectar archivos a revisar ─────────────────────────────────────────────
get_files() {
  local files=""

  if [[ "$HOOK_NAME" == "pre-commit" ]]; then
    # Solo archivos en staging
    files=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
  else
    # Pre-push: archivos modificados vs remoto
    local remote="${1:-origin}"
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    files=$(git diff --name-only "${remote}/${branch}" 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || \
            git diff --name-only HEAD~1 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
  fi

  echo "$files"
}

FILES=$(get_files)

if [[ -z "$FILES" ]]; then
  echo -e "${GREEN}  ✓ Sin archivos React relevantes. Continuando...${RESET}"
  echo ""
  exit 0
fi

FILE_COUNT=$(echo "$FILES" | grep -c . || echo 0)
echo -e "${CYAN}  Analizando ${BOLD}${FILE_COUNT} archivo(s)${RESET}${CYAN} React...${RESET}"
echo ""

# ─── Variables de resultado ───────────────────────────────────────────────────
FOUND_CRITICAL=false
VERCEL_JSON=""
DOCTOR_SCORE=-1
ALL_FINDINGS=()

# ─── Filtrar por nivel de reporte ─────────────────────────────────────────────
should_report() {
  local severity="$1"
  case "$REPORT_LEVEL" in
    critical)              [[ "$severity" == "CRITICAL" ]] ;;
    critical_high)         [[ "$severity" == "CRITICAL" || "$severity" == "HIGH" ]] ;;
    critical_high_medium)  [[ "$severity" != "LOW" ]] ;;
    all)                   true ;;
    *)                     true ;;
  esac
}

# ─── [1] Vercel React Review ──────────────────────────────────────────────────
run_vercel_review() {
  [[ "$USE_VERCEL" != "true" ]] && return 0

  echo -e "${CYAN}${BOLD}  [1/2] Vercel React Review${RESET}"

  if ! command -v claude &>/dev/null; then
    echo -e "  ${YELLOW}  ⚠ Claude Code CLI no disponible (saltando)${RESET}"
    echo ""
    return 0
  fi

  # Leer y construir prompt
  local toolkit_dir
  toolkit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  local prompt_file="$toolkit_dir/prompts/pre-commit-review.md"

  local files_content=""
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    files_content+="### File: $file\n\`\`\`typescript\n$(cat "$file")\n\`\`\`\n\n"
  done <<< "$FILES"

  local prompt=""
  if [[ -f "$prompt_file" ]]; then
    prompt=$(sed "s|{{FILES_CONTENT}}|$files_content|g" "$prompt_file")
  else
    prompt="Review these React files for CRITICAL issues. Output JSON with has_critical (bool) and findings array [{file,line,rule,severity,problem,fix}]. Files:\n$files_content"
  fi

  # Llamar a Claude
  local raw_output
  raw_output=$(echo "$prompt" | claude --no-header -p 2>/dev/null || echo '{"has_critical":false,"findings":[],"summary":"Error"}')

  # Extraer JSON
  VERCEL_JSON=$(echo "$raw_output" | python3 -c "
import sys, json, re
content = sys.stdin.read()
match = re.search(r'\{.*\}', content, re.DOTALL)
if match:
    try:
        data = json.loads(match.group())
        print(json.dumps(data))
    except:
        print('{\"has_critical\":false,\"findings\":[],\"summary\":\"Parse error\"}')
else:
    print('{\"has_critical\":false,\"findings\":[],\"summary\":\"No JSON\"}')
" 2>/dev/null || echo '{"has_critical":false,"findings":[],"summary":"Error"}')

  local has_critical findings_count summary
  has_critical=$(echo "$VERCEL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('has_critical') else 'false')" 2>/dev/null || echo "false")
  findings_count=$(echo "$VERCEL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('findings',[])))" 2>/dev/null || echo "0")
  summary=$(echo "$VERCEL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('summary',''))" 2>/dev/null || echo "")

  [[ "$has_critical" == "true" ]] && FOUND_CRITICAL=true

  if [[ "$findings_count" -eq 0 ]]; then
    echo -e "      ${GREEN}✓ Sin violaciones${RESET}"
  else
    # Mostrar hallazgos segun nivel de reporte
    echo "$VERCEL_JSON" | python3 - << 'PYEOF'
import sys, json, os

data    = json.load(sys.stdin)
level   = os.environ.get('REPORT_LEVEL', 'critical_high')
findings = data.get('findings', [])

def should_show(sev):
    if level == 'critical':              return sev == 'CRITICAL'
    if level == 'critical_high':         return sev in ('CRITICAL', 'HIGH')
    if level == 'critical_high_medium':  return sev != 'LOW'
    return True

colors = {
    'CRITICAL': '\033[0;31m',
    'HIGH':     '\033[1;33m',
    'MEDIUM':   '\033[0;33m',
    'LOW':      '\033[0;37m',
}
reset = '\033[0m'
bold  = '\033[1m'

shown = [f for f in findings if should_show(f.get('severity','LOW'))]

for f in shown:
    sev   = f.get('severity','LOW')
    color = colors.get(sev, reset)
    print(f"      {color}[{sev}]{reset} {bold}{f.get('file','')}:{f.get('line','?')}{reset}")
    print(f"        Regla:    {f.get('rule','')}")
    print(f"        Problema: {f.get('problem','')}")
    print(f"        Fix:      {f.get('fix','')}")
    print()
PYEOF
    echo -e "      ${DIM}$summary${RESET}"
  fi
  echo ""
}

# ─── [2] React Doctor ─────────────────────────────────────────────────────────
run_doctor() {
  [[ "$USE_DOCTOR" != "true" ]] && return 0

  local label="[2/2]"
  [[ "$USE_VERCEL" != "true" ]] && label="[1/1]"

  echo -e "${CYAN}${BOLD}  $label React Doctor${RESET}"

  if ! command -v npx &>/dev/null; then
    echo -e "      ${YELLOW}⚠ npx no disponible (saltando)${RESET}"
    echo ""
    return 0
  fi

  local output
  output=$(npx react-doctor 2>/dev/null || echo "")

  if [[ -z "$output" ]]; then
    echo -e "      ${YELLOW}⚠ react-doctor sin output${RESET}"
    echo ""
    return 0
  fi

  DOCTOR_SCORE=$(echo "$output" | python3 -c "
import sys, re
content = sys.stdin.read()
try:
    import json
    data = json.loads(content)
    score = data.get('score', data.get('totalScore', -1))
    print(score)
except:
    match = re.search(r'[Ss]core[:\s]+(\d+)', content)
    print(match.group(1) if match else '-1')
" 2>/dev/null || echo "-1")

  if [[ "$DOCTOR_SCORE" != "-1" ]] && [[ "$BLOCK_SCORE" == "true" ]]; then
    if [[ "$DOCTOR_SCORE" -lt "$SCORE_THRESHOLD" ]]; then
      FOUND_CRITICAL=true
      echo -e "      ${RED}✗ Score critico: ${BOLD}${DOCTOR_SCORE}/100${RESET} ${RED}(umbral: ${SCORE_THRESHOLD})${RESET}"
    elif [[ "$DOCTOR_SCORE" -lt 70 ]]; then
      echo -e "      ${YELLOW}⚠ Score bajo: ${BOLD}${DOCTOR_SCORE}/100${RESET} ${YELLOW}(recomendado >70)${RESET}"
    else
      echo -e "      ${GREEN}✓ Score: ${BOLD}${DOCTOR_SCORE}/100${RESET}"
    fi
  elif [[ "$DOCTOR_SCORE" != "-1" ]]; then
    echo -e "      ${CYAN}Score: ${BOLD}${DOCTOR_SCORE}/100${RESET}"
  fi

  echo ""
}

# ─── Ejecutar revisiones ──────────────────────────────────────────────────────
export REPORT_LEVEL
run_vercel_review
run_doctor

# ─── Guardar reporte ──────────────────────────────────────────────────────────
save_report() {
  mkdir -p "$REPORT_DIR"
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local report_file="$REPORT_DIR/${HOOK_NAME}-${ts}.json"

  python3 - << PYEOF > "$report_file" 2>/dev/null || true
import json, sys

vercel = {}
try:
    vercel = json.loads('''${VERCEL_JSON:-{}}''')
except:
    pass

report = {
    "timestamp": "${ts}",
    "hook": "${HOOK_NAME}",
    "doctor_score": ${DOCTOR_SCORE},
    "found_critical": ${FOUND_CRITICAL},
    "vercel_review": vercel
}
print(json.dumps(report, indent=2))
PYEOF

  echo -e "  ${DIM}Reporte: ${report_file}${RESET}"
}

# ─── Decision final ───────────────────────────────────────────────────────────
save_report

echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────┐${RESET}"

if [[ "$FOUND_CRITICAL" == "true" ]]; then
  case "$BLOCK_CRITICAL" in
    block)
      echo -e "${CYAN}${BOLD}│  Resultado: ${RED}BLOQUEADO${CYAN} — Corrige los CRITICALs     │${RESET}"
      echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
      echo ""
      echo -e "  ${DIM}Para saltar esta revision: git ${HOOK_NAME/pre-/} --no-verify${RESET}"
      echo ""

      # Ofrecer auto-fix si esta configurado
      if [[ "$FIX_MODE" == "ask" ]] && [[ -n "$VERCEL_JSON" ]]; then
        printf "  ${BOLD}¿Quieres que Claude aplique los fixes automáticamente? [s/N]:${RESET} "
        read -r fix_ans </dev/tty || fix_ans="n"
        fix_ans=$(echo "${fix_ans:-n}" | tr '[:upper:]' '[:lower:]')
        if [[ "$fix_ans" == "s" || "$fix_ans" == "si" || "$fix_ans" == "y" ]]; then
          echo ""
          echo -e "  ${CYAN}Aplicando fixes con Claude Code...${RESET}"
          # Invocar Claude Code con el skill de fix
          local toolkit_dir
          toolkit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
          echo "$VERCEL_JSON" | claude --no-header -p "Apply the fixes described in this JSON to the project files. Only fix CRITICAL and HIGH severity issues. Do not break existing functionality. JSON: $(cat)" 2>/dev/null || \
            echo -e "  ${YELLOW}  Auto-fix no disponible en modo hook. Ejecuta '/vercel-react-review' en Claude Code.${RESET}"
        fi
      elif [[ "$FIX_MODE" == "auto" ]] && [[ -n "$VERCEL_JSON" ]]; then
        echo -e "  ${CYAN}Aplicando fixes automaticos (modo auto)...${RESET}"
        local toolkit_dir
        toolkit_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        echo "$VERCEL_JSON" | claude --no-header -p "Apply ONLY high-confidence fixes (async-parallel, derived-state) from this JSON. Do not break existing functionality. JSON: $(cat)" 2>/dev/null || true
      fi

      exit 1
      ;;

    warn)
      echo -e "${CYAN}${BOLD}│  Resultado: ${YELLOW}ADVERTENCIA${CYAN} — Commit permitido        │${RESET}"
      echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
      echo ""
      echo -e "  ${YELLOW}Se encontraron violaciones CRITICAL. Revisa el reporte.${RESET}"
      echo ""
      exit 0
      ;;

    ask)
      echo -e "${CYAN}${BOLD}│  Resultado: ${YELLOW}DECISION REQUERIDA${CYAN}                    │${RESET}"
      echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
      echo ""
      printf "  ${BOLD}¿Continuar con el commit de todas formas? [s/N]:${RESET} "
      read -r user_ans </dev/tty || user_ans="n"
      user_ans=$(echo "${user_ans:-n}" | tr '[:upper:]' '[:lower:]')
      if [[ "$user_ans" == "s" || "$user_ans" == "si" || "$user_ans" == "y" ]]; then
        echo -e "  ${YELLOW}Continuando a pesar de las violaciones CRITICAL...${RESET}"
        echo ""
        exit 0
      else
        echo -e "  ${RED}Commit cancelado. Corrige los problemas primero.${RESET}"
        echo ""
        exit 1
      fi
      ;;
  esac
else
  echo -e "${CYAN}${BOLD}│  Resultado: ${GREEN}APROBADO${CYAN} — Sin violaciones criticas   │${RESET}"
  echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────┘${RESET}"
  echo ""
  exit 0
fi
