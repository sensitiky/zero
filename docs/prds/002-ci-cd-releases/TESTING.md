# Testing guide — CI/CD: releases, tags y DMG instalable

## 1. Dry run — sin publicar nada

1. Repo → **Actions → release → Run workflow**, dejar el input `version` en `0.0.0-test` (o poner
   otro).
2. Confirmar que el job entero corre en verde: `swift test` pasa, `Scripts/make-app.sh release`
   produce `build/Zero.app`, `hdiutil` produce `build/Zero-0.0.0-test.dmg`.
3. El paso "Tag and publish release" se salta (no corrió por un push a `main`) — no se crea nada
   en GitHub Releases ni se pushea ningún tag.
4. Descargar `build/Zero-0.0.0-test.dmg` desde los artifacts/logs del run (o correrlo localmente)
   y confirmar que monta y que `Zero.app` adentro abre (clic derecho → Abrir, por la firma ad-hoc).

## 2. Caso real — push a main

1. Mergear este feature (o cualquier PR) a `main`.
2. El workflow corre solo, calcula el próximo tag bumpeando el patch del último `vX.Y.Z`
   existente (`v0.1.0` si es el primero). Confirmar en **Actions** que terminó en verde.
3. Confirmar en **Releases** que existe el tag calculado con notas autogeneradas y su
   `Zero-{version}.dmg` adjunto.
4. Descargar el `.dmg` desde el Release y confirmar que abre igual.

## Known limitations / deferred

- Firma ad-hoc únicamente — sin cuenta Apple Developer no hay notarización. Quien instale el
  `.dmg` tiene que sortear Gatekeeper. Sigue como G4 en `001-agent-chat-core`.
- Si un tag ya tiene release publicado, el workflow falla (no lo pisa). Para rehacer un release:
  `gh release delete vX.Y.Z --cleanup-tag` y volver a pushear el tag.
- Sin auto-update — el usuario reinstala el `.dmg` a mano en cada versión.
