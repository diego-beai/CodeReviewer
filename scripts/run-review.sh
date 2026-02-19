#!/usr/bin/env bash
# =============================================================================
# CodeReviewer — run-review.sh
# Ejecuta la revision React manualmente (sin necesidad de hacer commit)
# Uso:
#   ./scripts/run-review.sh           → ambas revisiones (Vercel + Doctor)
#   ./scripts/run-review.sh vercel    → solo Vercel React Review
#   ./scripts/run-review.sh doctor    → solo React Doctor
#   ./scripts/run-review.sh all       → ambas (igual que sin argumento)
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT_DIR="$(dirname "$SCRIPT_DIR")"
MODE="${1:-all}"

echo ""
echo -e "${CYAN}${BOLD}╔═══════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}${BOLD}║   🔍 Claude React Toolkit — Revision Manual       ║${RESET}"
echo -e "${CYAN}${BOLD}╚═══════════════════════════════════════════════════╝${RESET}"
echo ""

# ─────────────────────────────────────────────
# Determinar archivos a revisar
# ─────────────────────────────────────────────

# Prioridad: argumento de archivos > git diff > src/ completo
if [[ "$MODE" == "vercel" ]] || [[ "$MODE" == "doctor" ]] || [[ "$MODE" == "all" ]]; then
  TARGET_FILES=""

  # 1. Archivos modificados vs main/master (si hay git)
  if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
    TARGET_FILES=$(git diff --name-only HEAD 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)

    # Si no hay diff vs HEAD, intentar vs branch base
    if [[ -z "$TARGET_FILES" ]]; then
      TARGET_FILES=$(git diff --name-only "$BASE_BRANCH" 2>/dev/null | grep -E '\.(tsx?|jsx?)$' || true)
    fi
  fi

  # 2. Fallback: todos los .tsx/.ts en src/
  if [[ -z "$TARGET_FILES" ]]; then
    echo -e "${YELLOW}No se detectaron archivos modificados. Analizando src/ completo...${RESET}"
    if [[ -d "src" ]]; then
      TARGET_FILES=$(find src -name "*.tsx" -o -name "*.ts" | head -20)
    else
      TARGET_FILES=$(find . -name "*.tsx" -o -name "*.ts" | grep -v node_modules | grep -v dist | head -20)
    fi
  fi

  if [[ -z "$TARGET_FILES" ]]; then
    echo -e "${YELLOW}No se encontraron archivos React para analizar.${RESET}"
    exit 0
  fi

  FILE_COUNT=$(echo "$TARGET_FILES" | wc -l | tr -d ' ')
  echo -e "${CYAN}Archivos a revisar: ${BOLD}${FILE_COUNT} archivo(s)${RESET}"
  echo "$TARGET_FILES" | sed 's/^/  • /'
  echo ""
fi

# ─────────────────────────────────────────────
# Vercel React Review (Claude Code)
# ─────────────────────────────────────────────
run_vercel_review() {
  echo -e "${CYAN}${BOLD}━━━ Vercel React Review ━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  if ! command -v claude &>/dev/null; then
    echo -e "${RED}✗ Claude Code CLI no encontrado.${RESET}"
    echo -e "  Instala con: npm install -g @anthropic-ai/claude-code"
    return 1
  fi

  # Construir contenido de archivos
  FILES_CONTENT=""
  while IFS= read -r file; do
    if [[ -f "$file" ]]; then
      FILES_CONTENT+="### File: $file\n\`\`\`typescript\n$(cat "$file")\n\`\`\`\n\n"
    fi
  done <<< "$TARGET_FILES"

  # Cargar prompt template
  PROMPT_TEMPLATE="$TOOLKIT_DIR/prompts/pre-commit-review.md"
  if [[ -f "$PROMPT_TEMPLATE" ]]; then
    PROMPT=$(sed "s|{{FILES_CONTENT}}|$FILES_CONTENT|g" "$PROMPT_TEMPLATE")
  else
    PROMPT="Review these React/TypeScript files for performance issues and anti-patterns. Check for: async-parallel (sequential awaits), bundle-barrel-imports, boolean-props proliferation, derived-state-in-useEffect. Output JSON with has_critical, findings[], summary. Files:\n$FILES_CONTENT"
  fi

  echo -e "${CYAN}Consultando a Claude...${RESET}"
  CLAUDE_OUTPUT=$(echo "$PROMPT" | claude --no-header -p 2>/dev/null || echo '{"has_critical":false,"findings":[],"summary":"Error al ejecutar Claude"}')

  # Extraer y mostrar resultados
  JSON_OUTPUT=$(echo "$CLAUDE_OUTPUT" | python3 -c "
import sys, json, re
content = sys.stdin.read()
match = re.search(r'\{.*\}', content, re.DOTALL)
if match:
    try:
        data = json.loads(match.group())
        print(json.dumps(data, indent=2))
    except:
        print('{\"has_critical\":false,\"findings\":[],\"summary\":\"Parse error\"}')
else:
    print('{\"has_critical\":false,\"findings\":[],\"summary\":\"No JSON in response\"}')
" 2>/dev/null || echo '{"has_critical":false,"findings":[],"summary":"Error"}')

  SUMMARY=$(echo "$JSON_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('summary',''))" 2>/dev/null || echo "")
  FINDINGS_COUNT=$(echo "$JSON_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('findings',[])))" 2>/dev/null || echo "0")
  HAS_CRITICAL=$(echo "$JSON_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print('si' if d.get('has_critical') else 'no')" 2>/dev/null || echo "no")

  echo ""

  if [[ "$FINDINGS_COUNT" -eq "0" ]]; then
    echo -e "${GREEN}${BOLD}✓ Sin violaciones${RESET}"
    echo -e "${GREEN}Tu codigo cumple con las mejores practicas de Vercel.${RESET}"
  else
    # Tabla de hallazgos
    echo "$JSON_OUTPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
findings = data.get('findings', [])
colors = {
  'CRITICAL': '\033[0;31m',
  'HIGH':     '\033[1;33m',
  'MEDIUM':   '\033[0;33m',
  'LOW':      '\033[0;37m'
}
reset = '\033[0m'
bold  = '\033[1m'
cyan  = '\033[0;36m'

print(f'{bold}Hallazgos encontrados: {len(findings)}{reset}')
print()

for i, f in enumerate(findings, 1):
  sev   = f.get('severity', 'LOW')
  color = colors.get(sev, reset)
  print(f'{color}[{sev}]{reset} {bold}{f.get(\"file\",\"\")}:{f.get(\"line\",\"?\")}{reset}')
  print(f'  Regla:   {cyan}{f.get(\"rule\",\"\")}{reset}')
  print(f'  Problema: {f.get(\"problem\",\"\")}')
  print(f'  Fix:      {f.get(\"fix\",\"\")}')
  print()

print(f'{bold}Resumen:{reset} {data.get(\"summary\",\"\")}')
" 2>/dev/null || echo "$JSON_OUTPUT"
  fi

  # Guardar reporte
  REPORT_DIR=".claude-review"
  mkdir -p "$REPORT_DIR"
  REPORT_FILE="$REPORT_DIR/vercel-$(date +%Y%m%d-%H%M%S).json"
  echo "$JSON_OUTPUT" > "$REPORT_FILE" 2>/dev/null || true
  echo ""
  echo -e "${CYAN}Reporte guardado en: ${REPORT_FILE}${RESET}"
  echo ""
}

# ─────────────────────────────────────────────
# React Doctor
# ─────────────────────────────────────────────
run_doctor() {
  echo -e "${CYAN}${BOLD}━━━ React Doctor ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo ""

  if ! command -v npx &>/dev/null; then
    echo -e "${RED}✗ npx no encontrado. Instala Node.js.${RESET}"
    return 1
  fi

  npx react-doctor 2>/dev/null || echo -e "${YELLOW}react-doctor no disponible o sin package.json${RESET}"
  echo ""
}

# ─────────────────────────────────────────────
# Ejecutar segun modo
# ─────────────────────────────────────────────
case "$MODE" in
  vercel)
    run_vercel_review
    ;;
  doctor)
    run_doctor
    ;;
  all|*)
    run_vercel_review
    run_doctor
    ;;
esac

echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${CYAN}Revision completada.${RESET}"
echo ""
