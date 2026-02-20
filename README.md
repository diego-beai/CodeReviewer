# ⚡ CodeReviewer

Toolkit de revision de codigo React para equipos. Deteccion gratuita en cada commit + revision profunda via skills nativos de Claude Code.

---

## Arquitectura

```
git commit
    ├── [1] Deteccion estatica (grep, 0 tokens, instantaneo)
    │         async-parallel · barrel-imports
    └── [2] React Doctor (npx, 0 tokens, ~5s)
              score 0-100 · warnings detallados

En Claude Code (cuando el desarrollador decide):
    /vercel-react-review   → 57 reglas Vercel: async-parallel, barrel imports, re-renders
    /react-doctor          → health score 0-100 del proyecto
    code-reviewer agent    → revision completa (invoca ambos + seguridad/calidad)
```

**Principio clave**: el hook nunca llama a la API de Claude. Los tokens se usan solo cuando el desarrollador decide hacer la revision completa.

---

## Instalacion

### Opcion A — Dentro del proyecto (recomendado para equipos)

El toolkit vive dentro del propio proyecto como `.claude-toolkit/`. Todos los companeros tienen la misma version al hacer `git clone`.

```bash
# Desde la raiz del proyecto (donde esta package.json y .git)
cd tu-proyecto-react
git clone https://github.com/diego-beai/CodeReviewer.git .claude-toolkit
bash .claude-toolkit/install.sh
```

Opcionalmente como submodulo:
```bash
git submodule add https://github.com/diego-beai/CodeReviewer.git .claude-toolkit
bash .claude-toolkit/install.sh
```

### Opcion B — Instalacion global compartida

El toolkit esta en tu home y lo apuntas a cada proyecto.

```bash
git clone https://github.com/diego-beai/CodeReviewer.git ~/claude-react-toolkit
cd tu-proyecto-react
bash ~/claude-react-toolkit/install.sh
```

> **Importante**: ejecuta siempre `install.sh` desde la **raiz del proyecto** (donde esta `package.json`), no desde dentro del toolkit.

### Opciones de install.sh

```bash
bash .claude-toolkit/install.sh                    # Wizard interactivo
bash .claude-toolkit/install.sh --quick            # Defaults (pre-commit, block on CRITICAL)
bash .claude-toolkit/install.sh --update-config    # Solo reconfigurar
bash .claude-toolkit/install.sh --uninstall        # Eliminar todo
```

---

## Uso diario

### Automatico (git hook, gratis)

Al hacer `git commit` o `git push` (segun configuracion), el hook corre automaticamente:
- Deteccion estatica de patrones CRITICAL
- React Doctor con score 0-100

Si hay problemas, bloquea el commit (o avisa, segun configuracion).

### Revision profunda (Claude Code)

```
/vercel-react-review   → Patrones React de Vercel con fixes interactivos
/react-doctor          → Health score 0-100 del proyecto
```

O usa el agente para revision completa:
```
Usa el agente code-reviewer en el proyecto
```

---

## Herramientas instaladas

### Skills en Claude Code (~/.claude/skills/)
- **`/vercel-react-review`** — 57 reglas de performance Vercel: async-parallel, barrel imports, re-renders, composicion
- **`/react-doctor`** — score 0-100 con diagnosticos detallados

### Agent en Claude Code (~/.claude/agents/)
- **`code-reviewer`** — revision completa: invoca vercel-react-review + react-doctor + seguridad/calidad generica

### Git hook (gratis, sin tokens)
- **`.git/hooks/pre-commit`** o **`pre-push`** — segun configuracion

### Para Cursor (opcional)
- **`.cursor/rules/vercel-react-review.mdc`** — reglas CRITICAL/HIGH aplicadas inline al editar
- **`.cursor/rules/react-health-check.mdc`** — reglas de salud del codebase

### Para Codex CLI (opcional)
- **`AGENTS.md`** en el root del proyecto — leido automaticamente por Codex

---

## Configuracion

Archivo: `.claude-toolkit.config.json` en el root del proyecto.

```json
{
  "trigger": "pre-commit",
  "blocking": {
    "on_critical_action": "block",
    "on_low_health_score": true,
    "health_score_threshold": 50
  },
  "reporting": {
    "level": "critical_high",
    "save_report": true,
    "report_dir": ".claude-review"
  },
  "tools": {
    "react_doctor": true
  }
}
```

### Opciones de `trigger`
- `pre-commit` — el hook corre al hacer commit (recomendado)
- `pre-push` — el hook corre al hacer push
- `manual` — no instala hooks; solo usa los skills en Claude Code

### Opciones de `on_critical_action`
- `block` — bloquea el commit si hay CRITICAL (recomendado)
- `warn` — muestra warning pero permite el commit
- `ask` — pregunta al desarrollador si continuar

---

## Reglas del hook (gratis, sin tokens)

### CRITICAL (bloquean el commit por defecto)
| Regla | Descripcion |
|---|---|
| `async-parallel` | Awaits secuenciales sin dependencia de datos → usar `Promise.all` |
| `bundle-barrel-imports` | Imports desde `index.ts` que inflan el bundle → importar directamente |

## Reglas del skill `/vercel-react-review` (via Claude Code)

### HIGH
| Regla | Descripcion |
|---|---|
| `architecture-avoid-boolean-props` | 3+ props booleanas como modos → usar `variant` union type |
| `architecture-compound-components` | Componentes monoliticos → patron compound components |

### MEDIUM
| Regla | Descripcion |
|---|---|
| `rerender-derived-state-no-effect` | Estado derivado en useEffect → calcular en render |
| `rerender-memo` | Componente puro sin React.memo → envolver para evitar re-renders |
| `rerender-stable-callbacks` | Arrow functions inline como props → useCallback |

---

## Compatibilidad

| Editor | Hook automatico | Revision profunda | Fixes |
|---|---|---|---|
| **Claude Code** | React Doctor + static | `/vercel-react-review` · `code-reviewer` | Interactivo en el chat |
| **Cursor** | React Doctor + static | `.mdc` rules (inline, gratis) | Cursor Chat |
| **Codex CLI** | React Doctor + static | `AGENTS.md` | Codex aplica los fixes |
| **Sin editor AI** | React Doctor + static | Reporte en `.claude-review/` | Manual |

---

## GitHub Actions

Para revision automatica en PRs:

```bash
mkdir -p .github/workflows
cp ~/claude-react-toolkit/github-action/claude-review.yml .github/workflows/
```

Requiere `ANTHROPIC_API_KEY` en los secrets del repositorio.

---

## Estructura del toolkit

```
claude-react-toolkit/
├── install.sh                    # Wizard de instalacion
├── README.md
├── config/
│   └── defaults.json             # Valores por defecto
├── hooks/
│   ├── pre-commit                # Hook de git
│   ├── pre-push                  # Hook de git
│   └── lib/
│       └── runner.sh             # Logica del hook (sin API calls)
├── skills/
│   └── vercel-react-review/      # Skill instalado en ~/.claude/skills/
│       ├── SKILL.md
│       └── AGENTS.md
├── agents/
│   └── code-reviewer.md          # Agent definition para Claude Code
├── cursor-rules/
│   ├── vercel-react-review.mdc   # Reglas CRITICAL/HIGH para Cursor
│   └── react-health-check.mdc   # Reglas de salud para Cursor
├── codex/
│   └── AGENTS.md                 # Instrucciones para Codex CLI
└── github-action/
    └── claude-review.yml         # Template GitHub Action para PRs
```

---

## Requisitos

- **Node.js** 18+ con `npx` (para React Doctor)
- **Git** (para deteccion de archivos modificados)
- **Claude Code CLI** (para skills y agent) — `npm install -g @anthropic-ai/claude-code`
- **Python 3** (incluido en macOS/Linux, para parsear JSON del hook)

---

## Licencia

MIT — Creado por [diego-beai](https://github.com/diego-beai)
