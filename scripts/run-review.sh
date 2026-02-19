#!/usr/bin/env bash
# =============================================================================
# CodeReviewer — run-review.sh
# Revision manual: React Doctor detecta, tu editor AI aplica los fixes.
#
# Uso:
#   ./scripts/run-review.sh          → revision completa (Vercel + Doctor)
#   ./scripts/run-review.sh vercel   → solo Vercel React Review
#   ./scripts/run-review.sh doctor   → solo React Doctor
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(dirname "$SCRIPT_DIR")"
MODE="${1:-all}"

echo ""
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║   ⚡ CodeReviewer — Revision Manual              ║${RESET}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""

# ─── Detectar editor AI para fixes ───────────────────────────────────────────
if command -v claude &>/dev/null; then
  FIX_EDITOR="claude"
  echo -e "${CYAN}Editor para fixes: ${BOLD}Claude Code${RESET}"
elif command -v codex &>/dev/null; then
  FIX_EDITOR="codex"
  echo -e "${CYAN}Editor para fixes: ${BOLD}Codex CLI${RESET}"
elif [[ -d ".cursor" ]]; then
  FIX_EDITOR="cursor"
  echo -e "${CYAN}Editor para fixes: ${BOLD}Cursor${RESET} ${DIM}(modo archivo)${RESET}"
else
  FIX_EDITOR="none"
  echo -e "${YELLOW}No se detectó editor AI. Los fixes se mostrarán como reporte.${RESET}"
fi
echo ""

# ─── Detectar archivos a revisar ─────────────────────────────────────────────
if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
  FILES=$(git diff --name-only HEAD 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
  [[ -z "$FILES" ]] && FILES=$(git diff --name-only "$BASE" 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
fi

if [[ -z "${FILES:-}" ]]; then
  echo -e "${YELLOW}Sin archivos modificados detectados. Analizando src/...${RESET}"
  FILES=$(find src -name "*.tsx" -o -name "*.ts" 2>/dev/null | grep -v node_modules | head -15 || true)
fi

if [[ -z "${FILES:-}" ]]; then
  echo -e "${YELLOW}No se encontraron archivos React.${RESET}"
  exit 0
fi

FILE_COUNT=$(echo "$FILES" | grep -c . || echo 0)
echo -e "${CYAN}Archivos: ${BOLD}${FILE_COUNT}${RESET}"
echo "$FILES" | sed 's/^/  • /'
echo ""

# ─── Variables compartidas ────────────────────────────────────────────────────
ALL_ISSUES=""
VERCEL_JSON=""
DOCTOR_OUTPUT=""

# ─── Vercel React Review ──────────────────────────────────────────────────────
run_vercel() {
  echo -e "${CYAN}${BOLD}━━━ Vercel React Review ━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  if ! command -v claude &>/dev/null; then
    echo -e "${RED}✗ Claude Code CLI no encontrado.${RESET}"
    echo -e "  ${DIM}npm install -g @anthropic-ai/claude-code${RESET}"
    echo ""
    return 1
  fi

  local files_content=""
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    files_content+="### File: $file\n\`\`\`typescript\n$(cat "$file")\n\`\`\`\n\n"
  done <<< "$FILES"

  local prompt_file="$TOOLKIT_DIR/prompts/pre-commit-review.md"
  local prompt
  if [[ -f "$prompt_file" ]]; then
    prompt=$(sed "s|{{FILES_CONTENT}}|$files_content|g" "$prompt_file")
  else
    prompt="Review these React files. Output JSON: {has_critical, findings:[{file,line,rule,severity,problem,fix}], summary}. Files:\n$files_content"
  fi

  echo -e "${DIM}Consultando a Claude...${RESET}"
  local raw
  raw=$(echo "$prompt" | claude --no-header -p 2>/dev/null || echo '{"has_critical":false,"findings":[],"summary":"Error"}')

  VERCEL_JSON=$(echo "$raw" | python3 -c "
import sys, json, re
content = sys.stdin.read()
match = re.search(r'\{.*\}', content, re.DOTALL)
if match:
    try: print(json.dumps(json.loads(match.group())))
    except: print('{\"has_critical\":false,\"findings\":[],\"summary\":\"Parse error\"}')
else: print('{\"has_critical\":false,\"findings\":[],\"summary\":\"No JSON\"}')
" 2>/dev/null || echo '{"has_critical":false,"findings":[],"summary":"Error"}')

  local findings_count
  findings_count=$(echo "$VERCEL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('findings',[])))" 2>/dev/null || echo "0")

  echo ""
  if [[ "$findings_count" -eq 0 ]]; then
    echo -e "  ${GREEN}✓ Sin violaciones${RESET}"
  else
    echo "$VERCEL_JSON" | python3 - << 'PYEOF'
import sys, json
data = json.load(sys.stdin)
colors = {'CRITICAL':'\033[0;31m','HIGH':'\033[1;33m','MEDIUM':'\033[0;33m','LOW':'\033[0;37m'}
reset, bold, cyan = '\033[0m', '\033[1m', '\033[0;36m'
for f in data.get('findings', []):
    sev = f.get('severity','LOW')
    c = colors.get(sev, reset)
    print(f"  {c}[{sev}]{reset} {bold}{f.get('file','')}:{f.get('line','?')}{reset}")
    print(f"    Regla:    {cyan}{f.get('rule','')}{reset}")
    print(f"    Problema: {f.get('problem','')}")
    print(f"    Fix:      {f.get('fix','')}")
    print()
PYEOF

    # Acumular para fixes
    ALL_ISSUES+="=== Vercel React Review ===\n"
    ALL_ISSUES+=$(echo "$VERCEL_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for f in d.get('findings',[]):
    print(f\"[{f.get('severity')}] {f.get('file')}:{f.get('line')} — {f.get('rule')}\")
    print(f\"  Problema: {f.get('problem')}\")
    print(f\"  Fix: {f.get('fix')}\")
" 2>/dev/null)
    ALL_ISSUES+="\n\n"
  fi

  echo -e "  ${DIM}$(echo "$VERCEL_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('summary',''))" 2>/dev/null)${RESET}"
  echo ""
}

# ─── React Doctor ─────────────────────────────────────────────────────────────
run_doctor() {
  echo -e "${CYAN}${BOLD}━━━ React Doctor ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  if ! command -v npx &>/dev/null; then
    echo -e "${RED}✗ npx no encontrado. Instala Node.js.${RESET}"
    echo ""
    return 1
  fi

  DOCTOR_OUTPUT=$(npx react-doctor 2>/dev/null || echo "")

  if [[ -z "$DOCTOR_OUTPUT" ]]; then
    echo -e "${YELLOW}react-doctor sin output.${RESET}"
    echo ""
    return 0
  fi

  # Mostrar output completo de react-doctor
  echo "$DOCTOR_OUTPUT"
  echo ""

  # Acumular para fixes
  ALL_ISSUES+="=== React Doctor ===\n$DOCTOR_OUTPUT\n"
}

# ─── Aplicar fixes con el editor ─────────────────────────────────────────────
apply_fixes() {
  [[ -z "$ALL_ISSUES" ]] && return 0

  echo -e "${CYAN}${BOLD}━━━ Aplicar Fixes ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  case "$FIX_EDITOR" in
    claude)
      printf "  ${BOLD}¿Aplicar fixes con Claude Code? [s/N]:${RESET} "
      read -r ans </dev/tty || ans="n"
      ans=$(echo "${ans:-n}" | tr '[:upper:]' '[:lower:]')
      if [[ "$ans" == "s" || "$ans" == "si" || "$ans" == "y" ]]; then
        echo ""
        echo -e "  ${CYAN}Claude Code aplicando fixes...${RESET}"
        local fix_prompt="You are fixing a React/TypeScript project. Apply the following fixes found by React Doctor and Vercel React Review.

Rules:
- Fix CRITICAL and HIGH severity issues from Vercel Review
- Fix issues flagged by React Doctor
- Make minimal, surgical changes
- Never break existing functionality
- Apply each fix directly to the relevant file using your Edit tool

Issues to fix:
$(printf '%b' "$ALL_ISSUES")"

        echo "$fix_prompt" | claude --no-header -p 2>/dev/null && \
          echo -e "\n  ${GREEN}✓ Fixes aplicados. Revisa con 'git diff' antes de commitear.${RESET}" || \
          echo -e "\n  ${YELLOW}  Claude no pudo aplicar algunos fixes.${RESET}"
      fi
      ;;

    codex)
      printf "  ${BOLD}¿Aplicar fixes con Codex? [s/N]:${RESET} "
      read -r ans </dev/tty || ans="n"
      ans=$(echo "${ans:-n}" | tr '[:upper:]' '[:lower:]')
      if [[ "$ans" == "s" || "$ans" == "si" || "$ans" == "y" ]]; then
        echo ""
        printf '%b' "$ALL_ISSUES" | codex "Fix these React issues. Make minimal changes, never break functionality." 2>/dev/null && \
          echo -e "\n  ${GREEN}✓ Fixes aplicados por Codex.${RESET}" || \
          echo -e "\n  ${YELLOW}  Codex no pudo aplicar los fixes.${RESET}"
      fi
      ;;

    cursor)
      local report_dir=".claude-review"
      mkdir -p "$report_dir"
      local cursor_file="$report_dir/cursor-fixes-$(date +%Y%m%d-%H%M%S).md"
      {
        echo "# CodeReviewer — Fixes pendientes para Cursor"
        echo ""
        echo "> Selecciona todo este contenido, pégalo en Cursor Chat y di:"
        echo "> **\"Apply all these fixes to the project files\"**"
        echo ""
        printf '%b' "$ALL_ISSUES"
      } > "$cursor_file"
      echo -e "  ${CYAN}Archivo de fixes creado para Cursor:${RESET}"
      echo -e "  ${BOLD}$cursor_file${RESET}"
      echo -e "  ${DIM}Abre el archivo en Cursor y pide que aplique los fixes.${RESET}"
      ;;

    none)
      local report_dir=".claude-review"
      mkdir -p "$report_dir"
      local report_file="$report_dir/fixes-$(date +%Y%m%d-%H%M%S).txt"
      printf '%b' "$ALL_ISSUES" > "$report_file"
      echo -e "  ${DIM}Reporte de fixes: $report_file${RESET}"
      echo -e "  ${DIM}Instala Claude Code para aplicarlos automáticamente.${RESET}"
      ;;
  esac

  echo ""
}

# ─── Ejecutar segun modo ──────────────────────────────────────────────────────
case "$MODE" in
  vercel) run_vercel ;;
  doctor) run_doctor ;;
  all|*)  run_vercel; run_doctor ;;
esac

apply_fixes

echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${CYAN}Revision completada.${RESET}"
echo ""
