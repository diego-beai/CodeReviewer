---
name: vercel-react-review
description: Audita codigo React/TypeScript contra las reglas de vercel-labs/agent-skills. Usa cuando termines una feature, antes de un PR, o para revisar la calidad de componentes. Complementa react-doctor (score estatico) con analisis de patrones de performance y composicion.
version: 1.0.0
---

# Vercel React Review

Audita tu codigo React/TypeScript contra 57 reglas de performance y 8 de composicion
de componentes mantenidas por el equipo de Vercel.

## Reglas utilizadas

Descarga en tiempo de ejecucion desde:
- React Best Practices (57 reglas): https://raw.githubusercontent.com/vercel-labs/agent-skills/main/skills/react-best-practices/SKILL.md
- Composition Patterns (8 reglas): https://raw.githubusercontent.com/vercel-labs/agent-skills/main/skills/composition-patterns/SKILL.md

## Workflow al invocar este skill

1. **Contexto**: Determina el scope de la revision:
   - Si el usuario especifica archivos concretos, revisalos
   - Si no, usa `git diff --name-only HEAD` para obtener archivos modificados
   - Si no hay diff util, usa los `.tsx`/`.ts` modificados recientemente en `src/`

2. **Descargar reglas**: Usa WebFetch para obtener los dos SKILL.md anteriores.

3. **Leer archivos**: Lee los archivos .tsx/.ts identificados en el paso 1.

4. **Analizar**: Aplica las reglas descargadas sobre el codigo. Prioridades criticas:
   - `async-parallel`: fetches secuenciales que podrian ir con Promise.all (CRITICAL)
   - `bundle-barrel-imports`: imports desde index.ts que inflan el bundle (CRITICAL)
   - `rerender-derived-state-no-effect`: estado derivado calculado en useEffect (MEDIUM)
   - `rerender-memo`: componentes que se re-renderizan innecesariamente (MEDIUM)
   - `architecture-avoid-boolean-props`: exceso de props booleanas (HIGH)
   - `architecture-compound-components`: oportunidades de compound components (HIGH)

5. **Reporte**: Genera una tabla con los hallazgos:

   | Archivo | Linea(s) | Regla | Severidad | Problema | Fix propuesto |

   Ordenar por severidad (CRITICAL > HIGH > MEDIUM > LOW). Omitir archivos sin hallazgos.

6. **Fixes**: Despues del reporte, pregunta si desea aplicar los fixes automaticamente,
   empezando por los de severidad alta. Nunca romper funcionalidad existente.

## Integracion con otras herramientas

Este skill es complementario a:
- **react-doctor**: da un score numerico de salud general (0-100)
- **code-reviewer**: revisa seguridad, mantenibilidad y correctitud generica
- **vercel-react-review** (este): profundiza en performance React y patrones de composicion

Flujo recomendado: `vercel-react-review` → `react-doctor` → `code-reviewer`

## Fallback sin internet

Si GitHub no esta disponible, aplicar estas reglas CRITICAL embebidas:

### CRITICAL: async-parallel
**Problema**: Fetches secuenciales con await que podrian ejecutarse en paralelo.
**Detection**: Multiples `await fetch(...)` o `await axios.get(...)` consecutivos sin dependencia entre si.
**Fix**: Envolver en `Promise.all([...])` o `Promise.allSettled([...])`.

```tsx
// MAL
const user = await fetchUser(id)
const posts = await fetchPosts(id)

// BIEN
const [user, posts] = await Promise.all([fetchUser(id), fetchPosts(id)])
```

### CRITICAL: bundle-barrel-imports
**Problema**: Import desde un archivo barrel (index.ts) que importa todo el modulo.
**Detection**: `import { X } from '../components'` cuando existe `components/index.ts`.
**Fix**: Import directo desde el archivo fuente.

```tsx
// MAL
import { Button, Input, Modal } from '../components'

// BIEN
import { Button } from '../components/Button'
import { Input } from '../components/Input'
import { Modal } from '../components/Modal'
```

### HIGH: architecture-avoid-boolean-props
**Problema**: Componentes con muchas props booleanas que actuan como modos.
**Detection**: 3+ props booleanas en un mismo componente (isLoading, isDisabled, isPrimary...).
**Fix**: Usar una prop `variant` o `status` con union type.

```tsx
// MAL
<Button isLoading={true} isPrimary={true} isDisabled={false} isOutlined={false} />

// BIEN
<Button variant="primary" status="loading" />
```

### MEDIUM: rerender-derived-state-no-effect
**Problema**: Estado derivado calculado en useEffect + setState en lugar de derivarlo directamente.
**Detection**: `useEffect(() => { setState(calcFromProps(props)) }, [props])`.
**Fix**: Calcular el valor derivado directamente en el render.

```tsx
// MAL
const [fullName, setFullName] = useState('')
useEffect(() => { setFullName(`${first} ${last}`) }, [first, last])

// BIEN
const fullName = `${first} ${last}`
```
