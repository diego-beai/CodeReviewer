#!/usr/bin/env bash
# =============================================================================
# CodeReviewer — install.sh
# Wizard de instalacion interactivo. Configura las revisiones React segun
# las preferencias de cada desarrollador y guarda la config en el proyecto.
#
# Uso:
#   ./install.sh                 → wizard interactivo completo
#   ./install.sh --quick         → instalacion rapida con defaults
#   ./install.sh --update-config → solo reconfigura (sin reinstalar archivos)
#   ./install.sh --uninstall     → elimina todo lo instalado
#   ./install.sh --help          → muestra esta ayuda
# =============================================================================

set -euo pipefail

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Variables globales ───────────────────────────────────────────────────────
TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
MODE="${1:---interactive}"
CONFIG_FILE=".claude-toolkit.config.json"

# Valores de configuracion (se rellenan en el wizard)
CFG_TRIGGER=""
CFG_BLOCK_CRITICAL=""
CFG_BLOCK_SCORE=""
CFG_SCORE_THRESHOLD=""
CFG_REPORT_LEVEL=""
CFG_ASK_FIX=""
CFG_VERCEL=""
CFG_DOCTOR=""
CFG_CLAUDE=""
CFG_CURSOR=""
CFG_CODEX=""

# ─── Utilidades de UI ─────────────────────────────────────────────────────────

print_header() {
  echo ""
  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${CYAN}${BOLD}║                                                          ║${RESET}"
  echo -e "${CYAN}${BOLD}║   ⚡ Claude React Toolkit — Setup Wizard                 ║${RESET}"
  echo -e "${CYAN}${BOLD}║                                                          ║${RESET}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
  echo -e "${DIM}  Revisa codigo React automaticamente con Vercel Agent Skills${RESET}"
  echo -e "${DIM}  Compatible con Claude Code, Cursor y Codex CLI${RESET}"
  echo ""
}

print_section() {
  echo ""
  echo -e "${CYAN}${BOLD}── $1 $( printf '%.0s─' $(seq 1 $((55 - ${#1}))) )${RESET}"
  echo ""
}

print_ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
print_warn() { echo -e "  ${YELLOW}⚠${RESET} $1"; }
print_err()  { echo -e "  ${RED}✗${RESET} $1"; }
print_info() { echo -e "  ${CYAN}→${RESET} $1"; }

# Muestra un menu y devuelve el numero elegido (1-based) en $REPLY
# Uso: ask_menu "Pregunta" "Default (numero)" "Op1" "Desc1" "Op2" "Desc2" ...
ask_menu() {
  local question="$1"
  local default_num="$2"
  shift 2
  local -a labels=()
  local -a descs=()

  while [[ $# -ge 2 ]]; do
    labels+=("$1")
    descs+=("$2")
    shift 2
  done

  echo -e "  ${BOLD}$question${RESET}"
  echo ""

  local i
  for i in "${!labels[@]}"; do
    local num=$((i + 1))
    local marker=""
    [[ "$num" == "$default_num" ]] && marker=" ${DIM}← recomendado${RESET}"
    echo -e "    ${CYAN}${BOLD}$num)${RESET} ${labels[$i]}${marker}"
    echo -e "       ${DIM}${descs[$i]}${RESET}"
  done

  echo ""
  printf "  Elige [1-%d] (Enter = %d): " "${#labels[@]}" "$default_num"
  read -r REPLY </dev/tty || REPLY=""

  # Usar default si el usuario presiona Enter
  if [[ -z "$REPLY" ]]; then
    REPLY="$default_num"
  fi

  # Validar que es un numero dentro del rango
  if ! [[ "$REPLY" =~ ^[0-9]+$ ]] || [[ "$REPLY" -lt 1 ]] || [[ "$REPLY" -gt "${#labels[@]}" ]]; then
    REPLY="$default_num"
  fi

  echo ""
}

# Pregunta si/no
ask_yn() {
  local question="$1"
  local default="${2:-s}"

  if [[ "$default" == "s" ]]; then
    local prompt="[S/n]"
  else
    local prompt="[s/N]"
  fi

  printf "  ${BOLD}%s${RESET} %s: " "$question" "$prompt"
  read -r ans </dev/tty || ans=""
  ans="${ans:-$default}"
  ans=$(echo "$ans" | tr '[:upper:]' '[:lower:]')
  [[ "$ans" == "s" || "$ans" == "si" || "$ans" == "y" || "$ans" == "yes" ]]
}

# ─── Verificacion de prerequisitos ────────────────────────────────────────────
check_prereqs() {
  print_section "Verificando prerequisitos"

  local all_ok=true

  if command -v claude &>/dev/null; then
    print_ok "Claude Code CLI $(claude --version 2>/dev/null || echo '')"
  else
    print_warn "Claude Code CLI no encontrado"
    print_info "Instala: ${CYAN}npm install -g @anthropic-ai/claude-code${RESET}"
    all_ok=false
  fi

  if command -v npx &>/dev/null; then
    print_ok "Node.js / npx $(node --version 2>/dev/null || echo '')"
    print_info "React Doctor usara npx para el analisis"
  else
    print_warn "npx no encontrado — React Doctor no funcionara"
  fi

  if command -v python3 &>/dev/null; then
    print_ok "Python 3 $(python3 --version 2>/dev/null | cut -d' ' -f2 || echo '')"
  else
    print_err "Python 3 requerido para parsear resultados"
    all_ok=false
  fi

  if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    local project
    project=$(basename "$(git rev-parse --show-toplevel)")
    print_ok "Repositorio git detectado: ${BOLD}$project${RESET}"
  else
    print_warn "No estas en un repositorio git"
    print_info "Los git hooks no se instalaran (pero los skills si)"
  fi

  echo ""
  if [[ "$all_ok" == "false" ]]; then
    echo -e "  ${YELLOW}Algunos prerequisitos faltan. Puedes continuar pero algunas${RESET}"
    echo -e "  ${YELLOW}funciones podrian no estar disponibles.${RESET}"
    echo ""
    if ! ask_yn "¿Continuar de todas formas?" "s"; then
      echo ""
      echo -e "  Instalacion cancelada. Instala los prerequisitos e intenta de nuevo."
      echo ""
      exit 0
    fi
  fi
}

# ─── Wizard de configuracion ──────────────────────────────────────────────────
run_wizard() {
  print_section "Configuracion — ¿Cuando revisar?"

  ask_menu "¿Cuándo quieres que se ejecute la revisión automática?" "1" \
    "Antes de cada commit (pre-commit)" \
      "Revisa solo los archivos en staging. Mas frecuente, mas rapido." \
    "Antes de hacer push (pre-push)" \
      "Revisa todos los cambios desde el ultimo push. Menos interrupciones." \
    "En ambos momentos (commit y push)" \
      "Maxima cobertura. El push revisa todo, el commit revisa lo inmediato." \
    "Solo manualmente (npm run review)" \
      "Tu decides cuando revisar. Sin automatismo en git."

  case "$REPLY" in
    1) CFG_TRIGGER="pre-commit" ;;
    2) CFG_TRIGGER="pre-push" ;;
    3) CFG_TRIGGER="both" ;;
    4) CFG_TRIGGER="manual" ;;
  esac

  # ── Que hacer con los problemas ──────────────────────────────────────────────
  print_section "Configuracion — ¿Qué hacer al encontrar problemas?"

  ask_menu "Cuando se detecta algo CRÍTICO (async-parallel, barrel imports...)" "1" \
    "Bloquear el commit/push y mostrar el problema" \
      "No puedes continuar sin corregirlo o usar --no-verify." \
    "Avisar pero dejar continuar" \
      "Muestra el aviso, guarda el reporte y sigue adelante." \
    "Preguntar que quieres hacer en cada caso" \
      "Te pregunta interactivamente si bloquear o continuar."

  case "$REPLY" in
    1) CFG_BLOCK_CRITICAL="block" ;;
    2) CFG_BLOCK_CRITICAL="warn" ;;
    3) CFG_BLOCK_CRITICAL="ask" ;;
  esac

  echo ""
  if ask_yn "¿Bloquear también si el health score del código cae por debajo de un umbral?" "n"; then
    CFG_BLOCK_SCORE="true"

    ask_menu "¿Cual es el health score minimo aceptable?" "2" \
      "40 — Solo bloquear en casos muy graves" \
        "Proyectos legacy o con mucha deuda tecnica." \
      "50 — Umbral equilibrado" \
        "Recomendado para la mayoria de proyectos." \
      "70 — Estandar de calidad" \
        "Para proyectos que quieren mantener alta calidad." \
      "85 — Exigente" \
        "Para proyectos de produccion criticos."

    case "$REPLY" in
      1) CFG_SCORE_THRESHOLD="40" ;;
      2) CFG_SCORE_THRESHOLD="50" ;;
      3) CFG_SCORE_THRESHOLD="70" ;;
      4) CFG_SCORE_THRESHOLD="85" ;;
    esac
  else
    CFG_BLOCK_SCORE="false"
    CFG_SCORE_THRESHOLD="0"
  fi

  # ── Nivel de reporte ─────────────────────────────────────────────────────────
  print_section "Configuracion — ¿Qué problemas reportar?"

  ask_menu "¿Qué nivel de severidad quieres ver en los reportes?" "2" \
    "Solo CRITICAL" \
      "Unicamente lo que bloquea o rompe la app en produccion." \
    "CRITICAL + HIGH" \
      "Criticos y problemas de arquitectura importantes. Recomendado." \
    "CRITICAL + HIGH + MEDIUM" \
      "Incluye oportunidades de optimizacion de rendimiento." \
    "Todos los niveles (CRITICAL a LOW)" \
      "Maximo detalle. Puede ser mucho ruido en proyectos grandes."

  case "$REPLY" in
    1) CFG_REPORT_LEVEL="critical" ;;
    2) CFG_REPORT_LEVEL="critical_high" ;;
    3) CFG_REPORT_LEVEL="critical_high_medium" ;;
    4) CFG_REPORT_LEVEL="all" ;;
  esac

  # ── Auto-fix ─────────────────────────────────────────────────────────────────
  print_section "Configuracion — ¿Aplicar fixes automáticamente?"

  ask_menu "Cuando Claude encuentra un problema con fix de alta confianza..." "2" \
    "Aplicar el fix automaticamente sin preguntar" \
      "Solo fixes seguros (async-parallel, derives state). Nunca rompe funcionalidad." \
    "Preguntar antes de aplicar cada fix" \
      "Muestra el cambio propuesto y espera confirmacion. Recomendado." \
    "Solo reportar, no tocar el codigo" \
      "Tu aplicas los cambios manualmente con la guia del reporte."

  case "$REPLY" in
    1) CFG_ASK_FIX="auto" ;;
    2) CFG_ASK_FIX="ask" ;;
    3) CFG_ASK_FIX="report_only" ;;
  esac

  # ── Herramientas ─────────────────────────────────────────────────────────────
  print_section "Configuracion — ¿Qué herramientas usar?"

  echo -e "  ${BOLD}¿Activar Vercel React Review?${RESET}"
  echo -e "  ${DIM}57 reglas de performance: async-parallel, barrel imports, re-renders...${RESET}"
  echo ""
  if ask_yn "  Activar" "s"; then CFG_VERCEL="true"; else CFG_VERCEL="false"; fi
  echo ""

  # ── Editores ─────────────────────────────────────────────────────────────────
  print_section "Configuracion — ¿En qué editores instalarlo?"

  echo -e "  ${BOLD}¿Instalar skill en Claude Code? (~/.claude/skills/)${RESET}"
  echo -e "  ${DIM}Permite invocar '/vercel-react-review' con fixes interactivos${RESET}"
  echo ""
  if ask_yn "  Instalar" "s"; then CFG_CLAUDE="true"; else CFG_CLAUDE="false"; fi
  echo ""

  echo -e "  ${BOLD}¿Instalar reglas en Cursor? (.cursor/rules/)${RESET}"
  echo -e "  ${DIM}Las reglas se aplican automaticamente al editar .tsx/.ts en Cursor${RESET}"
  echo ""
  if ask_yn "  Instalar" "n"; then CFG_CURSOR="true"; else CFG_CURSOR="false"; fi
  echo ""

  echo -e "  ${BOLD}¿Instalar instrucciones para Codex CLI? (AGENTS.md)${RESET}"
  echo -e "  ${DIM}Codex aplicara las reglas al generar codigo en este proyecto${RESET}"
  echo ""
  if ask_yn "  Instalar" "n"; then CFG_CODEX="true"; else CFG_CODEX="false"; fi
}

# ─── Resumen de configuracion ─────────────────────────────────────────────────
show_config_summary() {
  print_section "Resumen de tu configuracion"

  # Trigger
  case "$CFG_TRIGGER" in
    pre-commit) echo -e "  ${CYAN}Cuando revisar:${RESET}   Antes de cada commit" ;;
    pre-push)   echo -e "  ${CYAN}Cuando revisar:${RESET}   Antes de hacer push" ;;
    both)       echo -e "  ${CYAN}Cuando revisar:${RESET}   En commit Y en push" ;;
    manual)     echo -e "  ${CYAN}Cuando revisar:${RESET}   Solo manualmente" ;;
  esac

  # Bloqueo
  case "$CFG_BLOCK_CRITICAL" in
    block) echo -e "  ${CYAN}Si hay CRITICAL:${RESET}  Bloquear commit/push" ;;
    warn)  echo -e "  ${CYAN}Si hay CRITICAL:${RESET}  Avisar y continuar" ;;
    ask)   echo -e "  ${CYAN}Si hay CRITICAL:${RESET}  Preguntar que hacer" ;;
  esac

  if [[ "$CFG_BLOCK_SCORE" == "true" ]]; then
    echo -e "  ${CYAN}Score minimo:${RESET}     ${CFG_SCORE_THRESHOLD}/100 (bloquea si baja)"
  else
    echo -e "  ${CYAN}Score minimo:${RESET}     Sin limite"
  fi

  # Reporte
  case "$CFG_REPORT_LEVEL" in
    critical)              echo -e "  ${CYAN}Reportar:${RESET}         Solo CRITICAL" ;;
    critical_high)         echo -e "  ${CYAN}Reportar:${RESET}         CRITICAL + HIGH" ;;
    critical_high_medium)  echo -e "  ${CYAN}Reportar:${RESET}         CRITICAL + HIGH + MEDIUM" ;;
    all)                   echo -e "  ${CYAN}Reportar:${RESET}         Todos los niveles" ;;
  esac

  # Fix
  case "$CFG_ASK_FIX" in
    auto)        echo -e "  ${CYAN}Auto-fix:${RESET}         Aplicar automaticamente" ;;
    ask)         echo -e "  ${CYAN}Auto-fix:${RESET}         Preguntar antes de aplicar" ;;
    report_only) echo -e "  ${CYAN}Auto-fix:${RESET}         Solo reportar" ;;
  esac

  # Herramientas
  local tools=()
  [[ "$CFG_VERCEL" == "true" ]] && tools+=("Vercel React Review")
  [[ "${CFG_DOCTOR:-true}" == "true" ]] && tools+=("React Doctor")
  echo -e "  ${CYAN}Herramientas:${RESET}     ${tools[*]:-Ninguna}"
  echo -e "  ${CYAN}Fixes via:${RESET}        tu editor AI (Claude Code / Cursor / Codex)"

  # Editores
  local editors=()
  [[ "$CFG_CLAUDE" == "true" ]] && editors+=("Claude Code")
  [[ "$CFG_CURSOR" == "true" ]] && editors+=("Cursor")
  [[ "$CFG_CODEX"  == "true" ]] && editors+=("Codex CLI")
  echo -e "  ${CYAN}Editores:${RESET}         ${editors[*]:-Ninguno}"

  echo ""
  if ! ask_yn "¿Confirmar y proceder con la instalacion?" "s"; then
    echo ""
    echo -e "  Instalacion cancelada. Ejecuta el wizard de nuevo para reconfigurar."
    echo ""
    exit 0
  fi
}

# ─── Guardar configuracion en JSON ────────────────────────────────────────────
save_config() {
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")

  cat > "$project_root/$CONFIG_FILE" << EOF
{
  "_info": "Configuracion del CodeReviewer. Puedes editar este archivo o ejecutar ./install.sh --update-config",
  "_docs": "https://github.com/tu-org/CodeReviewer#configuracion",
  "version": "1.0.0",
  "trigger": "$CFG_TRIGGER",
  "blocking": {
    "on_critical": $([ "$CFG_BLOCK_CRITICAL" == "block" ] && echo "true" || echo "false"),
    "on_critical_action": "$CFG_BLOCK_CRITICAL",
    "on_low_health_score": $CFG_BLOCK_SCORE,
    "health_score_threshold": $CFG_SCORE_THRESHOLD
  },
  "reporting": {
    "level": "$CFG_REPORT_LEVEL",
    "save_report": true,
    "report_dir": ".claude-review"
  },
  "auto_fix": {
    "mode": "$CFG_ASK_FIX",
    "only_high_confidence": true
  },
  "tools": {
    "vercel_review": $CFG_VERCEL,
    "react_doctor": true
  },
  "editors": {
    "claude_code": $CFG_CLAUDE,
    "cursor": $CFG_CURSOR,
    "codex": $CFG_CODEX
  }
}
EOF

  print_ok "Configuracion guardada en: ${BOLD}$CONFIG_FILE${RESET}"
}

# ─── Instalar skills en ~/.claude/ ────────────────────────────────────────────
install_claude_skills() {
  if [[ "$CFG_CLAUDE" != "true" ]]; then return 0; fi

  print_info "Instalando skill en Claude Code..."
  mkdir -p "$CLAUDE_DIR/skills"

  cp -r "$TOOLKIT_DIR/skills/vercel-react-review" "$CLAUDE_DIR/skills/" 2>/dev/null && \
    print_ok "Skill 'vercel-react-review' instalado en ~/.claude/skills/"

  mkdir -p "$CLAUDE_DIR/agents"
  if [[ -f "$TOOLKIT_DIR/agents/code-reviewer.md" ]]; then
    [[ -f "$CLAUDE_DIR/agents/code-reviewer.md" ]] && \
      cp "$CLAUDE_DIR/agents/code-reviewer.md" "$CLAUDE_DIR/agents/code-reviewer.md.bak"
    cp "$TOOLKIT_DIR/agents/code-reviewer.md" "$CLAUDE_DIR/agents/code-reviewer.md"
    print_ok "Agent 'code-reviewer' actualizado con analisis React"
  fi
}

# ─── Instalar reglas para Cursor ──────────────────────────────────────────────
install_cursor_rules() {
  if [[ "$CFG_CURSOR" != "true" ]]; then return 0; fi

  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  local cursor_dir="$project_root/.cursor/rules"

  print_info "Instalando reglas en Cursor..."
  mkdir -p "$cursor_dir"
  cp "$TOOLKIT_DIR/cursor-rules/"*.mdc "$cursor_dir/" 2>/dev/null && \
    print_ok "Reglas Cursor instaladas en .cursor/rules/"
}

# ─── Instalar AGENTS.md para Codex ───────────────────────────────────────────
install_codex_agents() {
  if [[ "$CFG_CODEX" != "true" ]]; then return 0; fi

  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  local dest="$project_root/AGENTS.md"

  print_info "Instalando AGENTS.md para Codex CLI..."
  if [[ -f "$dest" ]]; then
    echo "" >> "$dest"
    echo "---" >> "$dest"
    cat "$TOOLKIT_DIR/codex/AGENTS.md" >> "$dest"
    print_ok "Instrucciones React agregadas al AGENTS.md existente"
  else
    cp "$TOOLKIT_DIR/codex/AGENTS.md" "$dest"
    print_ok "AGENTS.md creado para Codex CLI"
  fi
}

# ─── Instalar git hooks ───────────────────────────────────────────────────────
install_git_hooks() {
  if [[ "$CFG_TRIGGER" == "manual" ]]; then
    print_info "Modo manual seleccionado — sin git hooks"
    return 0
  fi

  if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    print_warn "No es un repositorio git. Git hooks no instalados."
    return 0
  fi

  local project_root
  project_root=$(git rev-parse --show-toplevel)
  local hooks_dir="$project_root/.git/hooks"
  local runner="$TOOLKIT_DIR/hooks/lib/runner.sh"
  local config_path="$project_root/$CONFIG_FILE"

  install_hook() {
    local hook_name="$1"
    local hook_file="$hooks_dir/$hook_name"

    if [[ -f "$hook_file" ]] && grep -q "CodeReviewer" "$hook_file" 2>/dev/null; then
      print_info "Hook $hook_name ya esta instalado (omitiendo)"
      return 0
    fi

    if [[ -f "$hook_file" ]] && ! grep -q "CodeReviewer" "$hook_file" 2>/dev/null; then
      # Agregar al hook existente
      {
        echo ""
        echo "# ── CodeReviewer ──────────────────────────────────────"
        echo "\"$runner\" \"$config_path\" \"$hook_name\""
      } >> "$hook_file"
      print_ok "Toolkit agregado al $hook_name hook existente"
    else
      # Crear nuevo hook
      cat > "$hook_file" << HOOKEOF
#!/usr/bin/env bash
# CodeReviewer — $hook_name hook
# Generado por install.sh. Para reconfigurar: cd \$(git rev-parse --show-toplevel)/.claude-toolkit && ./install.sh --update-config
"$runner" "$config_path" "$hook_name"
HOOKEOF
      chmod +x "$hook_file"
      print_ok "Hook $hook_name instalado"
    fi
  }

  case "$CFG_TRIGGER" in
    pre-commit) install_hook "pre-commit" ;;
    pre-push)   install_hook "pre-push" ;;
    both)       install_hook "pre-commit"; install_hook "pre-push" ;;
  esac
}

# ─── Instalar scripts npm ─────────────────────────────────────────────────────
install_npm_scripts() {
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  local pkg="$project_root/package.json"

  [[ ! -f "$pkg" ]] && { print_warn "package.json no encontrado. Scripts npm no configurados."; return 0; }
  grep -q "review:vercel" "$pkg" 2>/dev/null && { print_info "Scripts npm ya existen (omitiendo)"; return 0; }

  node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('$pkg', 'utf8'));
pkg.scripts = pkg.scripts || {};
pkg.scripts['review']         = 'bash \"${TOOLKIT_DIR}/scripts/run-review.sh\"';
pkg.scripts['review:vercel']  = 'bash \"${TOOLKIT_DIR}/scripts/run-review.sh\" vercel';
pkg.scripts['review:config']  = 'bash \"${TOOLKIT_DIR}/install.sh\" --update-config';
fs.writeFileSync('$pkg', JSON.stringify(pkg, null, 2) + '\n');
" 2>/dev/null && \
    print_ok "Scripts npm agregados al package.json" || \
    print_warn "No se pudieron agregar scripts npm"
}

# ─── Desinstalacion ───────────────────────────────────────────────────────────
uninstall() {
  print_section "Desinstalando CodeReviewer"

  # Skills
  [[ -d "$CLAUDE_DIR/skills/vercel-react-review" ]] && \
    rm -rf "$CLAUDE_DIR/skills/vercel-react-review" && print_ok "Skill vercel-react-review eliminado"

  # Agent backup
  [[ -f "$CLAUDE_DIR/agents/code-reviewer.md.bak" ]] && \
    mv "$CLAUDE_DIR/agents/code-reviewer.md.bak" "$CLAUDE_DIR/agents/code-reviewer.md" && \
    print_ok "code-reviewer.md restaurado"

  # Git hooks
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  for hook in pre-commit pre-push; do
    local hook_file="$project_root/.git/hooks/$hook"
    if [[ -f "$hook_file" ]] && grep -q "CodeReviewer" "$hook_file" 2>/dev/null; then
      # Eliminar solo las lineas del toolkit, no el hook completo
      local tmp
      tmp=$(mktemp)
      grep -v "CodeReviewer\|runner.sh" "$hook_file" > "$tmp" || true
      mv "$tmp" "$hook_file"
      chmod +x "$hook_file"
      print_ok "Hook $hook limpiado"
    fi
  done

  # Config
  [[ -f "$project_root/$CONFIG_FILE" ]] && \
    rm "$project_root/$CONFIG_FILE" && print_ok "$CONFIG_FILE eliminado"

  echo ""
  echo -e "${GREEN}Desinstalacion completada.${RESET}"
  echo ""
  exit 0
}

# ─── Modo rapido (defaults) ───────────────────────────────────────────────────
set_quick_defaults() {
  CFG_TRIGGER="pre-commit"
  CFG_BLOCK_CRITICAL="block"
  CFG_BLOCK_SCORE="true"
  CFG_SCORE_THRESHOLD="50"
  CFG_REPORT_LEVEL="critical_high"
  CFG_ASK_FIX="ask"
  CFG_VERCEL="true"
  CFG_CLAUDE="true"
  CFG_CURSOR="false"
  CFG_CODEX="false"
}

# ─── Cargar config existente ──────────────────────────────────────────────────
load_existing_config() {
  local project_root
  project_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  local cfg="$project_root/$CONFIG_FILE"

  [[ ! -f "$cfg" ]] && return 1

  CFG_TRIGGER=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(d.get('trigger','pre-commit'))" 2>/dev/null || echo "pre-commit")
  CFG_BLOCK_CRITICAL=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(d.get('blocking',{}).get('on_critical_action','block'))" 2>/dev/null || echo "block")
  CFG_BLOCK_SCORE=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(str(d.get('blocking',{}).get('on_low_doctor_score',True)).lower())" 2>/dev/null || echo "true")
  CFG_SCORE_THRESHOLD=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(d.get('blocking',{}).get('doctor_score_threshold',50))" 2>/dev/null || echo "50")
  CFG_REPORT_LEVEL=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(d.get('reporting',{}).get('level','critical_high'))" 2>/dev/null || echo "critical_high")
  CFG_ASK_FIX=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(d.get('auto_fix',{}).get('mode','ask'))" 2>/dev/null || echo "ask")
  CFG_VERCEL=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(str(d.get('tools',{}).get('vercel_review',True)).lower())" 2>/dev/null || echo "true")
  CFG_CLAUDE=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(str(d.get('editors',{}).get('claude_code',True)).lower())" 2>/dev/null || echo "true")
  CFG_CURSOR=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(str(d.get('editors',{}).get('cursor',False)).lower())" 2>/dev/null || echo "false")
  CFG_CODEX=$(python3 -c "import json,sys; d=json.load(open('$cfg')); print(str(d.get('editors',{}).get('codex',False)).lower())" 2>/dev/null || echo "false")

  return 0
}

# ─── Resumen post-instalacion ─────────────────────────────────────────────────
show_final_summary() {
  print_section "¡Listo! Resumen de uso"

  case "$CFG_TRIGGER" in
    pre-commit|both)
      echo -e "  ${BOLD}Automatico (pre-commit):${RESET}"
      echo -e "  ${DIM}git commit -m \"mi cambio\"${RESET}"
      echo -e "  ${DIM}→ Revisa archivos staged automaticamente${RESET}"
      echo ""
      ;;
  esac

  case "$CFG_TRIGGER" in
    pre-push|both)
      echo -e "  ${BOLD}Automatico (pre-push):${RESET}"
      echo -e "  ${DIM}git push origin main${RESET}"
      echo -e "  ${DIM}→ Revisa todos los cambios desde el ultimo push${RESET}"
      echo ""
      ;;
  esac

  echo -e "  ${BOLD}Manual (en cualquier momento):${RESET}"
  echo -e "  ${CYAN}npm run review${RESET}          → Revision completa con Claude"
  echo -e "  ${CYAN}npm run review:vercel${RESET}   → Solo Vercel React Review"
  echo -e "  ${CYAN}npm run review:config${RESET}   → Reconfigurar preferencias"
  echo ""

  if [[ "$CFG_CLAUDE" == "true" ]]; then
    echo -e "  ${BOLD}En Claude Code:${RESET}"
    echo -e "  ${CYAN}/vercel-react-review${RESET}    → Revision interactiva con fixes"
    echo ""
  fi

  echo -e "  ${BOLD}Saltar la revision puntualmente:${RESET}"
  echo -e "  ${DIM}git commit --no-verify -m \"wip\"${RESET}"
  echo ""

  echo -e "  ${BOLD}Para proyectos en GitHub:${RESET}"
  echo -e "  Copia ${CYAN}github-action/claude-review.yml${RESET} a ${CYAN}.github/workflows/${RESET}"
  echo -e "  Agrega ${CYAN}ANTHROPIC_API_KEY${RESET} en Settings → Secrets"
  echo ""

  echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  echo -e "${CYAN}${BOLD}║   ✅ Claude React Toolkit instalado correctamente         ║${RESET}"
  echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
  echo ""
}

# ─── Flujo principal ──────────────────────────────────────────────────────────
case "$MODE" in
  --help|-h)
    echo ""
    echo -e "${BOLD}CodeReviewer — install.sh${RESET}"
    echo ""
    echo "  ./install.sh                  → Wizard interactivo (recomendado)"
    echo "  ./install.sh --quick          → Instalacion con defaults"
    echo "  ./install.sh --update-config  → Solo reconfigurar"
    echo "  ./install.sh --uninstall      → Desinstalar todo"
    echo ""
    exit 0
    ;;
  --uninstall)
    print_header
    uninstall
    ;;
  --quick)
    print_header
    check_prereqs
    set_quick_defaults
    print_section "Instalacion rapida con configuracion recomendada"
    ;;
  --update-config)
    print_header
    print_section "Reconfigurando preferencias"
    load_existing_config || true
    run_wizard
    show_config_summary
    ;;
  --interactive|*)
    print_header
    check_prereqs
    run_wizard
    show_config_summary
    ;;
esac

# Ejecutar instalacion
print_section "Instalando"

save_config
install_claude_skills
install_cursor_rules
install_codex_agents
install_git_hooks
install_npm_scripts

show_final_summary
