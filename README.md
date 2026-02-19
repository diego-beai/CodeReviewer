# ⚡ CodeReviewer

Toolkit de revision de codigo React para equipos. Combina deteccion gratuita en cada commit con revision profunda bajo demanda via AI.

---

## Arquitectura

```
git commit
    ├── [1] Deteccion estatica (grep, 0 tokens, instantaneo)
    │         async-parallel · barrel-imports
    ├── [2] React Doctor (npx, 0 tokens, ~3s)
    │         score 0-100 · warnings detallados
    └── Si hay issues → sugiere: npm run review

npm run review  (cuando el usuario lo decide)
    ├── [1] React Doctor completo
    ├── [2] Vercel React Rules via Claude
    │         Solo archivos del diff · max 10 archivos
    │         Reglas embebidas · sin WebFetch extra
    └── Ofrece aplicar fixes con el editor detectado

Cursor (siempre gratis):
    └── .mdc rules → reglas CRITICAL/HIGH/MEDIUM inline
        Cursor las aplica mientras editas, sin API calls
```

**Principio clave**: el hook nunca llama a la API de Claude. Los tokens se usan solo cuando el desarrollador decide hacer la revision completa.

---

## Instalacion

```bash
# En el directorio del proyecto React
git clone https://github.com/diego-beai/CodeReviewer.git ~/claude-react-toolkit
cd tu-proyecto-react
bash ~/claude-react-toolkit/install.sh
```

### Opciones de install.sh

```bash
bash install.sh           # Instalacion interactiva completa
bash install.sh --quick   # Valores por defecto (pre-commit, block on CRITICAL)
bash install.sh --update-config  # Solo actualiza la configuracion
bash install.sh --uninstall      # Elimina hooks y configuracion
```

---

## Uso diario

```bash
# Revision completa (Doctor + Vercel Rules)
npm run review

# Solo React Doctor (rapido, gratis)
npm run review:doctor

# Solo Vercel Rules (Claude)
npm run review:vercel

# Ver/editar configuracion actual
npm run review:config
```

---

## Herramientas instaladas

### Para Claude Code
- **Skill `/vercel-react-review`** — revision bajo demanda en Claude Code
- **Agent `code-reviewer`** — revision completa incluyendo analisis React

### Para Cursor
- **`.cursor/rules/vercel-react-review.mdc`** — reglas CRITICAL/HIGH aplicadas inline
- **`.cursor/rules/react-health-check.mdc`** — reglas de salud del codebase

### Para Codex CLI
- **`AGENTS.md`** en el root del proyecto — leido automaticamente por Codex

### Para todos (git hooks)
- **`.git/hooks/pre-commit`** o **`pre-push`** — segun configuracion

---

## Configuracion

Archivo: `.claude-toolkit.config.json` en el root del proyecto.

```json
{
  "trigger": "pre-commit",
  "blocking": {
    "on_critical_action": "block",
    "on_low_doctor_score": true,
    "doctor_score_threshold": 50
  },
  "reporting": {
    "level": "critical_high",
    "save_report": true,
    "report_dir": ".claude-review"
  },
  "auto_fix": {
    "mode": "ask"
  },
  "tools": {
    "react_doctor": true
  }
}
```

### Opciones de `trigger`
- `pre-commit` — el hook corre al hacer commit (recomendado)
- `pre-push` — el hook corre al hacer push
- `manual` — no instala hooks; solo usa `npm run review`

### Opciones de `on_critical_action`
- `block` — bloquea el commit si hay CRITICAL (recomendado)
- `warn` — muestra warning pero permite el commit
- `ask` — pregunta al desarrollador si continuar

---

## Reglas aplicadas

### CRITICAL (bloquean el commit por defecto)
| Regla | Descripcion |
|---|---|
| `async-parallel` | Awaits secuenciales sin dependencia de datos → usar `Promise.all` |
| `bundle-barrel-imports` | Imports desde `index.ts` que inflan el bundle → importar directamente |

### HIGH (warnings, no bloquean)
| Regla | Descripcion |
|---|---|
| `architecture-avoid-boolean-props` | 3+ props booleanas como modos → usar `variant` union type |
| `architecture-compound-components` | Componentes monoliticos → patron compound components |

### MEDIUM (sugerencias de mejora)
| Regla | Descripcion |
|---|---|
| `rerender-derived-state-no-effect` | Estado derivado en useEffect → calcular en render |
| `rerender-memo` | Componente puro sin React.memo → envolver para evitar re-renders |
| `rerender-stable-callbacks` | Arrow functions inline como props → useCallback |

### Salud del codebase (React Doctor + Vercel Health)
- Rules of hooks (sin condicionales/loops)
- Estado minimo y no redundante
- Dependencias de useEffect correctas
- Type safety (sin `any`)
- Tamano de componentes
- Prop drilling excesivo

---

## Como funciona la revision Vercel

1. `npm run review` detecta los archivos modificados via `git diff`
2. Limita a max 10 archivos para no saturar el contexto
3. Archivos largos (+400 lineas) se truncan a las primeras 100
4. El prompt incluye las reglas embebidas (sin WebFetch, sin dependencia de red)
5. Claude analiza y devuelve JSON estructurado con findings + health score
6. Se ofrece aplicar los fixes con el editor detectado

---

## Compatibilidad de editores

| Editor | Deteccion en hook | Revision manual | Aplicar fixes |
|---|---|---|---|
| **Claude Code** | React Doctor + static | `npm run review` (completo) | Automatico con confirmacion |
| **Cursor** | React Doctor + static | `.mdc` rules (inline, gratis) | Cursor Chat con fixes.md |
| **Codex CLI** | React Doctor + static | `npm run review` | Codex aplica los fixes |
| **Sin editor AI** | React Doctor + static | `npm run review` (sin fixes) | Reporte en `.claude-review/` |

---

## GitHub Actions

Para revision automatica en PRs:

```bash
# Copiar el template al proyecto
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
├── scripts/
│   └── run-review.sh             # Revision manual completa
├── prompts/
│   └── pre-commit-review.md      # Prompt para Claude (reglas embebidas)
├── skills/
│   └── vercel-react-review/      # Skill para Claude Code
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
- **Claude Code CLI** (para revision Vercel y aplicar fixes) — `npm install -g @anthropic-ai/claude-code`
- **Python 3** (incluido en macOS/Linux, para parsear JSON)
- **Cursor** o **Codex CLI** (opcionales, alternativas a Claude Code)

---

## Licencia

MIT — Creado por [diego-beai](https://github.com/diego-beai)
