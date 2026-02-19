# ⚡ CodeReviewer

> Revisión automática de código React con IA, integrada en tu flujo de git.

Combina las **57 reglas de producción de Vercel** ([agent-skills](https://github.com/vercel-labs/agent-skills)) con el score de salud de **React Doctor**, directamente en tu terminal — antes de cada commit, antes de cada push, o cuando tú decidas.

Compatible con **Claude Code**, **Cursor** y **Codex CLI**.

---

## ¿Qué hace?

Cuando haces un commit (o un push, o lo que configures), el toolkit:

1. Detecta los archivos `.tsx`/`.ts` modificados
2. Los envía a Claude con las reglas de Vercel para detectar violaciones
3. Corre `react-doctor` y obtiene el score de salud
4. Actúa según tu configuración: bloquea, avisa, o pregunta

```
git commit -m "feat: nueva pantalla de usuario"

┌──────────────────────────────────────────────────┐
│  ⚡ Claude React Toolkit — Pre-commit Review     │
└──────────────────────────────────────────────────┘
  Analizando 3 archivo(s) React...

  [1/2] Vercel React Review
      [CRITICAL] src/hooks/useUserData.ts:23
        Regla:    async-parallel
        Problema: fetchUser y fetchPosts se ejecutan secuencialmente
        Fix:      Envolver en Promise.all([fetchUser(id), fetchPosts(id)])

  [2/2] React Doctor
      ⚠ Score bajo: 64/100 (umbral: 50)

┌──────────────────────────────────────────────────┐
│  Resultado: BLOQUEADO — Corrige los CRITICALs   │
└──────────────────────────────────────────────────┘
  ¿Quieres que Claude aplique los fixes automáticamente? [s/N]:
```

---

## Instalación

### Opción A — Como submódulo en tu proyecto (recomendado para equipos)

```bash
# Añadir el toolkit a tu proyecto React
git submodule add https://github.com/diego-beai/CodeReviewer.git .claude-toolkit

# Ejecutar el wizard de instalación
cd .claude-toolkit && ./install.sh
```

El wizard te pregunta exactamente cómo quieres que funcione (ver [Configuración](#configuración)) y guarda tus preferencias en `.claude-toolkit.config.json`.

### Opción B — Instalación global en tu máquina

```bash
git clone https://github.com/diego-beai/CodeReviewer.git ~/CodeReviewer

# Luego, en cada proyecto React donde quieras el toolkit:
~/CodeReviewer/install.sh
```

### Opción C — Instalación rápida con defaults

```bash
./install.sh --quick
```

Instala con la configuración recomendada sin hacer preguntas.

---

## El Wizard de Configuración

Al ejecutar `./install.sh`, el wizard interactivo te guía por estas opciones:

### ¿Cuándo revisar?

| Opción | Descripción |
|---|---|
| **Pre-commit** | Revisa solo los archivos en staging. Rápido, feedback inmediato. |
| **Pre-push** | Revisa todos los cambios desde el último push. Menos interrupciones. |
| **Ambos** | Máxima cobertura. |
| **Solo manual** | Tú decides cuándo con `npm run review`. |

### ¿Qué hacer al encontrar CRITICALs?

| Opción | Descripción |
|---|---|
| **Bloquear** | El commit no puede continuar hasta corregirlo (o `--no-verify`). |
| **Avisar** | Muestra el problema, guarda el reporte, deja pasar. |
| **Preguntar** | Te pregunta en cada caso si quieres bloquear o continuar. |

### ¿Qué severidades reportar?

| Nivel | Qué incluye |
|---|---|
| Solo CRITICAL | Problemas que rompen performance en producción. |
| CRITICAL + HIGH | + Problemas de arquitectura importantes. *(recomendado)* |
| + MEDIUM | + Oportunidades de optimización de renders. |
| Todos | + Sugerencias de mejora menores. |

### ¿Aplicar fixes automáticamente?

| Modo | Descripción |
|---|---|
| **Preguntar** | Muestra el fix propuesto y espera confirmación. *(recomendado)* |
| **Auto** | Aplica fixes de alta confianza sin preguntar. |
| **Solo reportar** | Solo informa, tú decides qué cambiar. |

### Score mínimo de React Doctor

Configura el umbral de score (0-100) por debajo del cual se bloquea el commit. Por defecto: 50.

---

## Uso manual

Una vez instalado, puedes lanzar la revisión en cualquier momento:

```bash
npm run review           # Vercel Review + React Doctor (completo)
npm run review:vercel    # Solo las 57 reglas de Vercel
npm run review:doctor    # Solo el score de React Doctor
npm run review:config    # Abrir el wizard para reconfigurar
```

Para saltar la revisión puntualmente sin desinstalarlo:
```bash
git commit --no-verify -m "wip: trabajo en progreso"
```

---

## Compatibilidad con editores

### Claude Code

El toolkit instala el skill `vercel-react-review` en `~/.claude/skills/` para revisiones interactivas con Claude:

```
/vercel-react-review
```

Claude descarga las reglas actualizadas de Vercel, revisa tu código, muestra una tabla de hallazgos y ofrece aplicar los fixes con explicaciones.

También actualiza el agent `code-reviewer` para que incluya automáticamente el análisis React cuando trabaje con proyectos `.tsx`/`.ts`.

### Cursor

Las reglas se instalan en `.cursor/rules/` y se aplican automáticamente al editar archivos `.tsx`/`.ts`:

- `vercel-react-review.mdc` — 57 reglas de performance React
- `react-doctor-check.mdc` — recordatorio de ejecutar react-doctor

### Codex CLI

Las instrucciones se instalan como `AGENTS.md` en la raíz del proyecto. Codex las lee automáticamente al ejecutarse.

---

## GitHub Actions

Para revisión automática en cada PR, copia la Action a tu proyecto:

```bash
mkdir -p .github/workflows
cp .claude-toolkit/github-action/claude-review.yml .github/workflows/
```

Luego añade tu `ANTHROPIC_API_KEY` en **Settings → Secrets and variables → Actions**.

Cada PR recibirá automáticamente un comentario con el análisis completo.

---

## Configuración manual

La configuración se guarda en `.claude-toolkit.config.json` en la raíz de tu proyecto. Puedes editarlo directamente:

```json
{
  "trigger": "pre-commit",
  "blocking": {
    "on_critical_action": "block",
    "on_low_doctor_score": true,
    "doctor_score_threshold": 50
  },
  "reporting": {
    "level": "critical_high"
  },
  "auto_fix": {
    "mode": "ask"
  },
  "tools": {
    "vercel_review": true,
    "react_doctor": true
  },
  "editors": {
    "claude_code": true,
    "cursor": false,
    "codex": false
  }
}
```

Para reconfigurar con el wizard: `npm run review:config`

---

## Reglas que se aplican

Las reglas se descargan en tiempo real desde [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills), siempre actualizadas.

### CRITICAL — Bloquean el commit por defecto

| Regla | Problema | Fix |
|---|---|---|
| `async-parallel` | Múltiples `await` secuenciales sin dependencia | `Promise.all([...])` |
| `bundle-barrel-imports` | Imports desde `index.ts` inflando el bundle | Import directo desde el archivo |

### HIGH — Advierten, permiten continuar

| Regla | Problema | Fix |
|---|---|---|
| `architecture-avoid-boolean-props` | 3+ props booleanas en el mismo componente | Prop `variant` con union type |
| `architecture-compound-components` | Componente monolítico con múltiples concerns | Compound components pattern |

### MEDIUM — Oportunidades de mejora

| Regla | Problema | Fix |
|---|---|---|
| `rerender-derived-state-no-effect` | `useEffect + setState` para valores derivados | Calcular en el render |
| `rerender-memo` | Componente puro que se re-renderiza sin cambios | `React.memo()` |
| `rerender-stable-callbacks` | Callbacks inline que causan re-renders en hijos | `useCallback` |

Para las 57 reglas completas → [vercel-labs/agent-skills/react-best-practices](https://github.com/vercel-labs/agent-skills/tree/main/skills/react-best-practices)

---

## Prerequisitos

| Herramienta | Para qué | Instalar |
|---|---|---|
| [Claude Code CLI](https://claude.ai/code) | Análisis con IA, auto-fix | `npm install -g @anthropic-ai/claude-code` |
| Node.js 18+ | React Doctor | [nodejs.org](https://nodejs.org) |
| Python 3 | Parsear resultados en hooks | Preinstalado en macOS/Linux |

---

## Estructura del repositorio

```
CodeReviewer/
├── install.sh                          ← Wizard de instalación interactivo
├── config/
│   └── defaults.json                   ← Valores por defecto
├── skills/
│   └── vercel-react-review/
│       ├── SKILL.md                    ← Skill para Claude Code
│       └── AGENTS.md                   ← Versión compacta para agentes
├── agents/
│   └── code-reviewer.md                ← code-reviewer con análisis React
├── hooks/
│   ├── pre-commit                      ← Git hook (generado por install.sh)
│   ├── pre-push                        ← Git hook (generado por install.sh)
│   └── lib/
│       └── runner.sh                   ← Núcleo: lee config y ejecuta revisión
├── prompts/
│   └── pre-commit-review.md            ← Prompt para Claude en los hooks
├── cursor-rules/
│   ├── vercel-react-review.mdc         ← Reglas para Cursor
│   └── react-doctor-check.mdc
├── codex/
│   └── AGENTS.md                       ← Instrucciones para Codex CLI
├── github-action/
│   └── claude-review.yml               ← Template GitHub Action
└── scripts/
    └── run-review.sh                   ← Revisión manual
```

---

## Desinstalar

```bash
cd .claude-toolkit && ./install.sh --uninstall
```

Elimina los git hooks, los skills de `~/.claude/`, restaura el `code-reviewer.md` original y borra el archivo de config del proyecto.

---

## Licencia

MIT — Usa, modifica y comparte libremente.

---

*Basado en las reglas de [vercel-labs/agent-skills](https://github.com/vercel-labs/agent-skills). Compatible con Claude Code de Anthropic.*
