# Vercel React Review — Agent Instructions

Audit React/TypeScript code against vercel-labs/agent-skills best practices.

## Steps

1. Determine scope: user-specified files > git diff files > recently modified .tsx/.ts in src/
2. Fetch via WebFetch:
   - https://raw.githubusercontent.com/vercel-labs/agent-skills/main/skills/react-best-practices/SKILL.md
   - https://raw.githubusercontent.com/vercel-labs/agent-skills/main/skills/composition-patterns/SKILL.md
3. Read target files with the Read tool
4. Cross-reference code against fetched rules
5. Output findings table sorted by severity (CRITICAL > HIGH > MEDIUM > LOW)
6. Ask before applying any fixes

## Output format

| File | Line(s) | Rule | Severity | Problem | Proposed Fix |

Only report actual violations. Skip files with no issues.
After table: ask if user wants fixes applied, starting with CRITICAL/HIGH items.

## Priority rules to check

| Rule ID | Severity | Pattern to detect |
|---|---|---|
| async-parallel | CRITICAL | Multiple sequential awaits without data dependency |
| bundle-barrel-imports | CRITICAL | Imports from index.ts barrel files |
| architecture-avoid-boolean-props | HIGH | 3+ boolean props on same component |
| architecture-compound-components | HIGH | Complex component that could be split |
| rerender-derived-state-no-effect | MEDIUM | useEffect + setState for derived values |
| rerender-memo | MEDIUM | Component re-renders without change |
