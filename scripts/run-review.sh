#!/usr/bin/env bash
# =============================================================================
# CodeReviewer — run-review.sh
# Revision manual completa:
#   [1] React Doctor  — gratis, siempre, score 0-100 + issues detallados
#   [2] Vercel Rules  — Claude Code, solo archivos del diff (max 10), a peticion
#
# Uso:
#   ./scripts/run-review.sh          → revision completa
#   ./scripts/run-review.sh doctor   → solo React Doctor
#   ./scripts/run-review.sh vercel   → solo Vercel Rules (Claude)
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
  echo -e "${CYAN}  Editor: ${BOLD}Claude Code${RESET}"
elif command -v codex &>/dev/null; then
  FIX_EDITOR="codex"
  echo -e "${CYAN}  Editor: ${BOLD}Codex CLI${RESET}"
elif [[ -d ".cursor" ]]; then
  FIX_EDITOR="cursor"
  echo -e "${CYAN}  Editor: ${BOLD}Cursor${RESET} ${DIM}(modo archivo)${RESET}"
else
  FIX_EDITOR="none"
  echo -e "${YELLOW}  Sin editor AI detectado.${RESET}"
fi
echo ""

# ─── Detectar archivos a revisar ─────────────────────────────────────────────
FILES=""
if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
  # Prioridad 1: cambios no commiteados
  FILES=$(git diff --name-only HEAD 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)

  # Prioridad 2: staged
  if [[ -z "$FILES" ]]; then
    FILES=$(git diff --cached --name-only 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
  fi

  # Prioridad 3: diff respecto al branch base
  if [[ -z "$FILES" ]]; then
    BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
    FILES=$(git diff --name-only "${BASE}" 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
  fi
fi

# Fallback: archivos recientes en src/
if [[ -z "${FILES:-}" ]]; then
  echo -e "${YELLOW}  Sin cambios Git. Analizando src/ (max 10 archivos)...${RESET}"
  FILES=$(find src -name "*.tsx" -o -name "*.ts" 2>/dev/null | grep -v node_modules | head -10 || true)
fi

if [[ -z "${FILES:-}" ]]; then
  echo -e "${YELLOW}  No se encontraron archivos React.${RESET}"
  exit 0
fi

# Limitar a 10 archivos para evitar overflow de contexto
FILE_COUNT=$(echo "$FILES" | grep -c . || echo 0)
if [[ "$FILE_COUNT" -gt 10 ]]; then
  FILES=$(echo "$FILES" | head -10)
  FILE_COUNT=10
  echo -e "${YELLOW}  ⚠ Mas de 10 archivos. Analizando los primeros 10.${RESET}"
fi

echo -e "${CYAN}  Archivos (${FILE_COUNT}):${RESET}"
echo "$FILES" | sed 's/^/    • /'
echo ""

# ─── Variables compartidas ────────────────────────────────────────────────────
ALL_ISSUES=""
DOCTOR_SCORE=-1
VERCEL_HAS_CRITICAL=false

# ─── [1] React Doctor ─────────────────────────────────────────────────────────
run_doctor() {
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}${BOLD}  [1/2] React Doctor${RESET}"
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  if ! command -v npx &>/dev/null; then
    echo -e "  ${RED}✗ npx no encontrado. Instala Node.js.${RESET}"
    echo ""
    return 1
  fi

  echo -e "  ${DIM}Ejecutando react-doctor...${RESET}"
  local doctor_output
  doctor_output=$(npx react-doctor 2>/dev/null || echo "")

  if [[ -z "$doctor_output" ]]; then
    echo -e "  ${YELLOW}⚠ react-doctor no devolvio output. ¿Esta instalado?${RESET}"
    echo -e "  ${DIM}Prueba: npx react-doctor${RESET}"
    echo ""
    return 0
  fi

  # Extraer score
  DOCTOR_SCORE=$(echo "$doctor_output" | python3 -c "
import sys, re, json
c = sys.stdin.read()
try:
    d = json.loads(c)
    print(d.get('score', d.get('totalScore', -1)))
except:
    m = re.search(r'(\d+)\s*/\s*100', c)
    print(m.group(1) if m else -1)
" 2>/dev/null || echo "-1")

  echo ""
  if [[ "$DOCTOR_SCORE" != "-1" ]]; then
    if [[ "$DOCTOR_SCORE" -ge 80 ]]; then
      echo -e "  ${GREEN}Score: ${BOLD}${DOCTOR_SCORE}/100${RESET} — Excelente"
    elif [[ "$DOCTOR_SCORE" -ge 60 ]]; then
      echo -e "  ${YELLOW}Score: ${BOLD}${DOCTOR_SCORE}/100${RESET} — Mejorable"
    else
      echo -e "  ${RED}Score: ${BOLD}${DOCTOR_SCORE}/100${RESET} — Necesita atencion"
    fi
    echo ""
  fi

  echo "$doctor_output"
  echo ""

  ALL_ISSUES+="=== React Doctor (Score: ${DOCTOR_SCORE}/100) ===
$doctor_output

"
}

# ─── [2] Vercel React Review (Claude, diff files only) ────────────────────────
run_vercel() {
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}${BOLD}  [2/2] Vercel React Review${RESET}"
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  if ! command -v claude &>/dev/null; then
    echo -e "  ${RED}✗ Claude Code CLI no encontrado.${RESET}"
    echo -e "  ${DIM}Instala: npm install -g @anthropic-ai/claude-code${RESET}"
    echo ""
    return 1
  fi

  # Construir contenido de archivos (truncar si son muy largos)
  local files_content=""
  local included=0
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    local lines
    lines=$(wc -l < "$file" 2>/dev/null || echo "0")
    if [[ "$lines" -gt 400 ]]; then
      files_content+="### File: $file (primeras 100 lineas de ${lines})\n\`\`\`typescript\n$(head -100 "$file")\n[...truncado - ${lines} lineas totales...]\n\`\`\`\n\n"
    else
      files_content+="### File: $file\n\`\`\`typescript\n$(cat "$file")\n\`\`\`\n\n"
    fi
    ((included++))
  done <<< "$FILES"

  if [[ "$included" -eq 0 ]]; then
    echo -e "  ${YELLOW}Sin archivos validos para analizar.${RESET}"
    echo ""
    return 0
  fi

  # Cargar prompt con reglas embebidas
  local prompt_file="$TOOLKIT_DIR/prompts/pre-commit-review.md"
  local prompt
  if [[ -f "$prompt_file" ]]; then
    prompt=$(sed "s|{{FILES_CONTENT}}|$files_content|g" "$prompt_file")
  else
    prompt="Review these React files against best practices. Output JSON: {has_critical, findings:[{file,line,rule,severity,problem,fix}], health:{score,issues,strengths}, summary}. Files:\n$files_content"
  fi

  echo -e "  ${DIM}Analizando ${included} archivo(s) con Claude...${RESET}"

  local raw
  raw=$(echo "$prompt" | claude --no-header -p 2>/dev/null || echo '{"has_critical":false,"findings":[],"health":{"score":-1,"issues":[],"strengths":[]},"summary":"Error al conectar con Claude"}')

  local vercel_json
  vercel_json=$(echo "$raw" | python3 -c "
import sys, json, re
content = sys.stdin.read()
match = re.search(r'\{.*\}', content, re.DOTALL)
if match:
    try: print(json.dumps(json.loads(match.group())))
    except: print('{\"has_critical\":false,\"findings\":[],\"health\":{\"score\":-1,\"issues\":[],\"strengths\":[]},\"summary\":\"Parse error\"}')
else: print('{\"has_critical\":false,\"findings\":[],\"health\":{\"score\":-1,\"issues\":[],\"strengths\":[]},\"summary\":\"Sin JSON en respuesta\"}')
" 2>/dev/null || echo '{"has_critical":false,"findings":[],"health":{"score":-1,"issues":[],"strengths":[]},"summary":"Error"}')

  local findings_count health_score
  findings_count=$(echo "$vercel_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('findings',[])))" 2>/dev/null || echo "0")
  health_score=$(echo "$vercel_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('health',{}).get('score',-1))" 2>/dev/null || echo "-1")

  echo ""
  if [[ "$health_score" != "-1" ]]; then
    if [[ "$health_score" -ge 80 ]]; then
      echo -e "  ${GREEN}Health: ${BOLD}${health_score}/100${RESET}"
    elif [[ "$health_score" -ge 60 ]]; then
      echo -e "  ${YELLOW}Health: ${BOLD}${health_score}/100${RESET}"
    else
      echo -e "  ${RED}Health: ${BOLD}${health_score}/100${RESET}"
    fi
  fi
  echo ""

  if [[ "$findings_count" -eq 0 ]]; then
    echo -e "  ${GREEN}✓ Sin violaciones detectadas${RESET}"
    echo "$vercel_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for s in d.get('health',{}).get('strengths',[])[:3]:
    print(f'  ✓ {s}')
" 2>/dev/null || true
  else
    VERCEL_HAS_CRITICAL=$(echo "$vercel_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print('true' if d.get('has_critical') else 'false')" 2>/dev/null || echo "false")

    echo "$vercel_json" | python3 - << 'PYEOF'
import sys, json
data = json.load(sys.stdin)
colors = {'CRITICAL':'\033[0;31m','HIGH':'\033[1;33m','MEDIUM':'\033[0;33m','LOW':'\033[0;37m'}
reset, bold, cyan, dim = '\033[0m', '\033[1m', '\033[0;36m', '\033[2m'
for f in data.get('findings', []):
    sev = f.get('severity','LOW')
    c = colors.get(sev, reset)
    print(f"  {c}[{sev}]{reset} {bold}{f.get('file','')}:{f.get('line','?')}{reset}")
    print(f"    Regla:    {cyan}{f.get('rule','')}{reset}")
    print(f"    Problema: {f.get('problem','')}")
    print(f"    Fix:      {f.get('fix','')}")
    print()
issues = data.get('health', {}).get('issues', [])
if issues:
    print(f"  {dim}Health issues:{reset}")
    for i in issues[:5]:
        print(f"    · {i}")
    print()
PYEOF

    local issues_text
    issues_text=$(echo "$vercel_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for f in d.get('findings',[]):
    print(f\"[{f.get('severity')}] {f.get('file')}:{f.get('line')} — {f.get('rule')}\")
    print(f\"  Problema: {f.get('problem')}\")
    print(f\"  Fix: {f.get('fix')}\")
    print()
" 2>/dev/null)
    ALL_ISSUES+="=== Vercel React Review ===
$issues_text
"
  fi

  local summary
  summary=$(echo "$vercel_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('summary',''))" 2>/dev/null || echo "")
  [[ -n "$summary" ]] && echo -e "  ${DIM}${summary}${RESET}"
  echo ""
}

# ─── Aplicar fixes con el editor ─────────────────────────────────────────────
apply_fixes() {
  if [[ -z "$ALL_ISSUES" ]]; then
    echo -e "  ${GREEN}✓ Sin issues acumulados. Nada que corregir.${RESET}"
    return 0
  fi

  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}${BOLD}  Aplicar Fixes${RESET}"
  echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  case "$FIX_EDITOR" in
    claude)
      printf "  ${BOLD}¿Aplicar fixes con Claude Code? [s/N]:${RESET} "
      read -r ans </dev/tty || ans="n"
      ans=$(echo "${ans:-n}" | tr '[:upper:]' '[:lower:]')
      if [[ "$ans" == "s" || "$ans" == "si" || "$ans" == "y" ]]; then
        echo ""
        echo -e "  ${CYAN}Claude aplicando fixes...${RESET}"
        local fix_prompt="You are fixing a React/TypeScript project. Apply the following fixes found by CodeReviewer.

Rules:
- Fix CRITICAL and HIGH severity issues first
- Make minimal, surgical changes only
- Never break existing functionality
- Apply each fix directly to the relevant file using your Edit tool
- After applying, show a summary of what was changed

Issues found:
$(printf '%b' "$ALL_ISSUES")"

        echo "$fix_prompt" | claude --no-header -p 2>/dev/null && \
          echo -e "\n  ${GREEN}✓ Fixes aplicados. Revisa con 'git diff' antes de commitear.${RESET}" || \
          echo -e "\n  ${YELLOW}⚠ Claude no pudo aplicar algunos fixes.${RESET}"
      else
        echo -e "  ${DIM}Omitido. Ejecuta 'npm run review' cuando quieras aplicar los fixes.${RESET}"
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
          echo -e "\n  ${YELLOW}⚠ Codex no pudo aplicar algunos fixes.${RESET}"
      fi
      ;;

    cursor)
      local report_dir=".claude-review"
      mkdir -p "$report_dir"
      local cursor_file="$report_dir/cursor-fixes-$(date +%Y%m%d-%H%M%S).md"
      {
        echo "# CodeReviewer — Fixes pendientes para Cursor"
        echo ""
        echo "> Selecciona todo este contenido y pegalo en Cursor Chat:"
        echo "> **\"Apply all these fixes to the project files\"**"
        echo ""
        printf '%b' "$ALL_ISSUES"
      } > "$cursor_file"
      echo -e "  ${CYAN}Archivo de fixes para Cursor:${RESET}"
      echo -e "  ${BOLD}$cursor_file${RESET}"
      echo -e "  ${DIM}Abre el archivo en Cursor y pide que aplique los fixes.${RESET}"
      ;;

    none)
      local report_dir=".claude-review"
      mkdir -p "$report_dir"
      local report_file="$report_dir/fixes-$(date +%Y%m%d-%H%M%S).txt"
      printf '%b' "$ALL_ISSUES" > "$report_file"
      echo -e "  ${DIM}Reporte guardado: ${CYAN}$report_file${RESET}"
      echo -e "  ${DIM}Instala Claude Code o Codex para aplicar fixes automaticamente.${RESET}"
      ;;
  esac

  echo ""
}

# ─── Ejecutar segun modo ──────────────────────────────────────────────────────
case "$MODE" in
  doctor)
    run_doctor
    ;;
  vercel)
    run_vercel
    ;;
  all|*)
    run_doctor
    run_vercel
    ;;
esac

apply_fixes

# ─── Resumen final ────────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║   Resumen                                        ║${RESET}"
echo -e "${CYAN}${BOLD}╠══════════════════════════════════════════════════╣${RESET}"
if [[ "$DOCTOR_SCORE" != "-1" ]]; then
  printf "${CYAN}${BOLD}║${RESET}  React Doctor:  "
  if [[ "$DOCTOR_SCORE" -ge 80 ]]; then
    printf "${GREEN}${BOLD}%d/100${RESET}" "$DOCTOR_SCORE"
  elif [[ "$DOCTOR_SCORE" -ge 60 ]]; then
    printf "${YELLOW}${BOLD}%d/100${RESET}" "$DOCTOR_SCORE"
  else
    printf "${RED}${BOLD}%d/100${RESET}" "$DOCTOR_SCORE"
  fi
  printf "                              %s\n" "${CYAN}${BOLD}║${RESET}"
fi
if [[ "$VERCEL_HAS_CRITICAL" == "true" ]]; then
  echo -e "${CYAN}${BOLD}║${RESET}  ${RED}⚠ Issues CRITICAL detectados por Vercel Rules${RESET}   ${CYAN}${BOLD}║${RESET}"
fi
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
