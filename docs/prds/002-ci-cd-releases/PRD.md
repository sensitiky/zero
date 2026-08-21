# PRD — CI/CD: releases, tags y DMG instalable

## Status
Approved

## Problem
Hoy no hay pipeline: para publicar una versión de Zero hay que compilar, empaquetar y firmar a
mano, y no queda ni un tag ni un artefacto descargable en GitHub. El paso G4 del item
`001-agent-chat-core` ("Firma, notarización y DMG") está `blocked` justamente porque `notarize.sh`
nunca corrió — necesita una cuenta Apple Developer que no existe. Esta PRD no desbloquea G4; cubre
la mitad que sí es posible ahora: automatizar el build + el release, con firma ad-hoc (la misma que
ya usa `make-app.sh`), no notarizada.

## Goals
- Un push a `main` (incluye un merge de PR) dispara un workflow que compila la app en release, la
  empaqueta en un `.dmg` y publica un GitHub Release con ese `.dmg` adjunto — sin pasos manuales.
- El número de versión del release se auto-incrementa (patch) a partir del último tag `vX.Y.Z`
  existente; no viene de un valor hardcodeado en el script ni requiere pushear el tag a mano.
- Las notas del release se autogeneran desde el log de commits (`gh release create --generate-notes`).

## Non-goals
- Firma con Developer ID y notarización (bloqueado por falta de cuenta Apple Developer — sigue
  siendo G4 en `001-agent-chat-core`, no se toca aquí). El `.dmg` sale con firma ad-hoc: quien lo
  instale tiene que sortear Gatekeeper (clic derecho → Abrir).
- Auto-update de la app (ya descartado como decisión del proyecto mientras el repo sea privado).
- Builds para otras plataformas (Windows/Linux) — la app es macOS-only.
- Changelog curado a mano — alcanza con las notas autogeneradas.

## User stories
- Como mantenedor de Zero, quiero pushear un tag y que el `.dmg` instalable aparezca solo en
  GitHub Releases, para no repetir el build/empaquetado manual en cada versión.

## Functional requirements
1. Un push a `main` (push directo o merge de PR) dispara el workflow de release.
2. El workflow corre `swift test` antes de compilar; si falla, el release no se publica.
3. El workflow calcula la versión bumpeando el patch del último tag `vX.Y.Z` existente
   (`v0.1.0` si no hay ninguno) y la inyecta como `CFBundleShortVersionString` del bundle en
   build time, reemplazando el `0.1.0` fijo que hoy escribe `Scripts/make-app.sh`.
4. El workflow corre `Scripts/make-app.sh release` para producir `build/Zero.app`.
5. El workflow empaqueta `build/Zero.app` en `Zero-{version}.dmg` (firma ad-hoc vía `hdiutil`, sin
   notarización — mismo criterio que el build local hoy).
6. El workflow crea el tag calculado, lo pushea, y crea el GitHub Release para ese tag con
   `gh release create --generate-notes`, subiendo el `.dmg` como asset.
7. Si el tag calculado ya tiene un release publicado, el workflow falla explícitamente en vez de
   sobrescribirlo en silencio (re-publicar exige borrar el release/tag primero).

## Non-functional requirements
- Sin secrets nuevos: nada de firma real, nada de credenciales de notarización.
- Corre en runner `macos-latest` de GitHub (hosted) — no self-hosted. Si esa imagen todavía no
  trae el SDK de macOS 26.0 (deployment target del `Package.swift`), el job falla en el build y
  hay que pinnear una imagen más nueva cuando GitHub la publique.

## Data model changes
Ninguno.

## UI/UX notes
Ninguna — es tooling de CI, no toca la app.

## Open questions
1. **Runner.** ~~Resuelto~~ — `macos-latest` (hosted). El usuario prefiere no depender de un
   self-hosted runner; si `macos-latest` no trae el SDK 26.0 todavía, se ajusta el `runs-on`
   cuando falle.

## Conflicts / dependencies
- Reemplaza el `0.1.0` fijo en `Scripts/make-app.sh` por un valor parametrizable — no rompe el uso
  manual local (default sigue siendo `0.1.0` si no se pasa versión).
- No toca `Scripts/notarize.sh` (sigue siendo el camino documentado para cuando haya cuenta de
  Apple Developer).
