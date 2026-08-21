# Implementation Plan — CI/CD: releases, tags y DMG instalable

## Status
Approved

## Branch / worktree
Branch name: `feat/002-ci-cd-releases`
Isolation mode: current checkout branch

## Phases

### Phase A — Versión parametrizable
- [ ] `Scripts/make-app.sh`: `CFBundleShortVersionString` sale de `${ZERO_VERSION:-0.1.0}` en vez
      del `0.1.0` fijo. Sin el env var, el build local se comporta exactamente igual que hoy.

### Phase B — Workflow de release
- [ ] `.github/workflows/release.yml`:
  - Triggers: `push` a `main` (cubre push directo y merge de PR), más `workflow_dispatch` con un
    input `version` (para poder probar el pipeline sin tocar tags/releases reales — ver Gate 3).
  - `runs-on: macos-latest` (hosted) — sin self-hosted runner.
  - Pasos: `actions/checkout` con `fetch-depth: 0` / `fetch-tags: true` (necesita ver los tags
    existentes), calcular el próximo tag bumpeando el patch del último `vX.Y.Z` (`v0.1.0` si no
    hay ninguno), `swift test` (si falla, el job para acá), exportar `ZERO_VERSION`,
    `Scripts/make-app.sh release`, `hdiutil create` inline para `build/Zero-${VERSION}.dmg`,
    crear y pushear el tag, `gh release create "$TAG" "build/Zero-${VERSION}.dmg" --generate-notes`.
  - Sin script nuevo para el `.dmg`: son dos líneas de `hdiutil`, inline en el YAML — no amerita un
    archivo aparte (`notarize.sh` sigue siendo el único lugar que empaqueta con firma real).
  - `gh release create` ya falla solo si el tag/release existe — cubre el FR7 sin código extra.
  - `permissions: contents: write` en el job — necesario para pushear el tag y crear el release
    con el `GITHUB_TOKEN` default.

### Phase C — Guía de prueba
- [ ] `docs/prds/002-ci-cd-releases/TESTING.md`: cómo probar el workflow con `workflow_dispatch`
      antes de confiar en un push real a `main`.

## Test plan
- Unit: ninguno nuevo — no hay lógica de app nueva, solo tooling de CI.
- Gate de CI: `swift test` corriendo dentro del propio workflow es la única red antes de publicar.
- Manual (Gate 3): disparar el workflow con `workflow_dispatch` (input `version: 0.0.0-test`) y
  confirmar que el `.dmg` sale bien armado y el job entero pasa, sin necesidad de tocar tags/releases
  reales; después, un push real a `main` para el caso end-to-end.

## Rollback notes
- Un run malo: `gh release delete vX.Y.Z --cleanup-tag` y `git push --delete origin vX.Y.Z`, después
  corregir el workflow.
- Revertir la feature completa: `git revert` del merge o borrar `.github/workflows/release.yml` y el
  cambio en `Scripts/make-app.sh` (el fallback a `0.1.0` deja el script igual que antes).
