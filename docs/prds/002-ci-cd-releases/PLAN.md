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
  - Triggers: `push` de tags `v[0-9]+.[0-9]+.[0-9]+`, más `workflow_dispatch` con un input
    `version` (para poder probar el pipeline sin publicar un tag real — ver Gate 3).
  - `runs-on: [self-hosted, macOS]` — la Mac del dev, ya tiene el SDK de macOS 26.
  - Pasos: `actions/checkout`, `swift test` (si falla, el job para acá — no se llega a empaquetar
    nada), exportar `ZERO_VERSION` (del tag sin la `v`, o del input del `workflow_dispatch`),
    `Scripts/make-app.sh release`, `hdiutil create` inline para `build/Zero-${VERSION}.dmg` a
    partir de `build/Zero.app` (ya sale con firma ad-hoc de `make-app.sh` — no se agrega firma
    nueva), `gh release create "$TAG" "build/Zero-${VERSION}.dmg" --generate-notes`.
  - Sin script nuevo para el `.dmg`: son dos líneas de `hdiutil`, inline en el YAML — no amerita un
    archivo aparte (`notarize.sh` sigue siendo el único lugar que empaqueta con firma real).
  - `gh release create` ya falla solo si el tag/release existe — cubre el FR7 sin código extra.

### Phase C — Guía de prueba
- [ ] `docs/prds/002-ci-cd-releases/TESTING.md`: cómo registrar el runner self-hosted una vez, y
      cómo probar el workflow con `workflow_dispatch` antes de confiar en un tag real.

## Test plan
- Unit: ninguno nuevo — no hay lógica de app nueva, solo tooling de CI.
- Gate de CI: `swift test` corriendo dentro del propio workflow es la única red antes de publicar.
- Manual (Gate 3): disparar el workflow con `workflow_dispatch` (input `version: 0.0.0-test`) y
  confirmar que el `.dmg` sale bien armado y el job entero pasa, sin necesidad de tocar tags/releases
  reales; después, un tag real (`v0.1.0`) para el caso end-to-end.

## Rollback notes
- Un run malo: `gh release delete vX.Y.Z --cleanup-tag` y `git push --delete origin vX.Y.Z`, después
  corregir el workflow.
- Revertir la feature completa: `git revert` del merge o borrar `.github/workflows/release.yml` y el
  cambio en `Scripts/make-app.sh` (el fallback a `0.1.0` deja el script igual que antes).
