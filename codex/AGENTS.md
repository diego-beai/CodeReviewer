# React Code Review Agent — Codex Instructions

Este archivo configura las instrucciones de revision de codigo React para Codex CLI.
Coloca este archivo en la raiz de tu proyecto React como `AGENTS.md`.

## Instrucciones de revision automatica

Cuando Codex genere o modifique codigo React/TypeScript, aplica automaticamente estas reglas:

### CRITICAL — Siempre corregir antes de terminar

#### async-parallel
No uses `await` secuenciales cuando las operaciones son independientes.

```ts
// NUNCA hacer esto
const user = await api.getUser(id)
const posts = await api.getPosts(id)

// SIEMPRE hacer esto
const [user, posts] = await Promise.all([
  api.getUser(id),
  api.getPosts(id)
])
```

#### bundle-barrel-imports
No importes desde archivos barrel (index.ts). Importa directamente.

```ts
// NUNCA
import { Button, Modal } from '../components'

// SIEMPRE
import { Button } from '../components/Button'
import { Modal } from '../components/Modal'
```

### HIGH — Corregir en el mismo PR

#### architecture-avoid-boolean-props
No uses mas de 2 props booleanas en el mismo componente. Usa `variant` o `status`.

```tsx
// MAL
<Btn isLoading isPrimary isLarge isDisabled={false} />

// BIEN
<Btn variant="primary" size="lg" status="loading" />
```

#### architecture-compound-components
Divide componentes de mas de 80 lineas con muchas props en compound components.

### MEDIUM — Mejorar en la siguiente iteracion

#### rerender-derived-state-no-effect
No uses `useEffect + setState` para calcular valores derivados.

```tsx
// MAL
const [name, setName] = useState('')
useEffect(() => setName(`${first} ${last}`), [first, last])

// BIEN
const name = `${first} ${last}`
```

#### rerender-memo
Envuelve en `React.memo` los componentes puros que reciben props primitivas.

#### rerender-stable-callbacks
Envuelve en `useCallback` las funciones que se pasan como props.

## Workflow de revision al generar codigo

Cuando generes o modifiques archivos `.tsx`/`.ts`:

1. Verifica que no hay `await` secuenciales independientes
2. Verifica que los imports son directos (no desde barrels)
3. Si el componente tiene 3+ boolean props, propone refactorizacion a `variant`
4. Si hay `useEffect` que solo llama a `setState`, convierte a valor derivado
5. Al terminar, sugiere ejecutar: `npx react-doctor`

## Formato de reporte de hallazgos

Cuando encuentres violaciones, reporta en este formato:

```
🚨 CRITICAL: async-parallel
   Archivo: src/hooks/useUserData.ts:23-26
   Problema: fetchProfile y fetchSettings se ejecutan secuencialmente
   Fix: Promise.all([fetchProfile(id), fetchSettings(id)])

⚠️  HIGH: architecture-avoid-boolean-props
   Archivo: src/components/Button.tsx
   Problema: 4 boolean props (isLoading, isPrimary, isOutlined, isDisabled)
   Fix: variant: 'primary' | 'secondary' | 'ghost', status: 'idle' | 'loading'
```

## Referencia de reglas completas

- React Best Practices (57 reglas): https://github.com/vercel-labs/agent-skills/tree/main/skills/react-best-practices
- Composition Patterns (8 reglas): https://github.com/vercel-labs/agent-skills/tree/main/skills/composition-patterns
