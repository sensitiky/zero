# Testing guide — CI/CD: releases, tags y DMG instalable

## 1. Registrar el runner self-hosted (una sola vez)

1. GitHub → repo → **Settings → Actions → Runners → New self-hosted runner**, elegir macOS/ARM64.
2. Seguir los comandos que muestra GitHub (descargan el agente, `./config.sh` con el token que da
   la propia página, `./run.sh`). Dejarlo corriendo como servicio (`./svc.sh install && ./svc.sh
   start`) para que sobreviva a un reinicio de la Mac.
3. Confirmar en **Settings → Actions → Runners** que aparece `Idle` con las labels `self-hosted` y
   `macOS` (las pone GitHub solo al registrar en una Mac).

## 2. Dry run — sin publicar nada

1. Repo → **Actions → release → Run workflow**, dejar el input `version` en `0.0.0-test` (o poner
   otro).
2. Confirmar que el job entero corre en verde: `swift test` pasa, `Scripts/make-app.sh release`
   produce `build/Zero.app`, `hdiutil` produce `build/Zero-0.0.0-test.dmg`.
3. El paso "Publish release" se salta (no corrió por un tag) — no se crea nada en GitHub Releases.
4. Abrir `build/Zero-0.0.0-test.dmg` localmente en la Mac del runner y confirmar que monta y que
   `Zero.app` adentro abre (con el clic derecho → Abrir de rigor, porque es firma ad-hoc).

## 3. Caso real — un tag

1. `git tag v0.1.0 && git push origin v0.1.0` (una vez que este feature esté en `main`).
2. El workflow corre solo. Confirmar en **Actions** que terminó en verde.
3. Confirmar en **Releases** que existe `v0.1.0` con notas autogeneradas y `Zero-0.1.0.dmg`
   adjunto.
4. Descargar el `.dmg` desde el Release (no desde la máquina del runner) y confirmar que abre igual.

## Known limitations / deferred

- Firma ad-hoc únicamente — sin cuenta Apple Developer no hay notarización. Quien instale el
  `.dmg` tiene que sortear Gatekeeper. Sigue como G4 en `001-agent-chat-core`.
- Si un tag ya tiene release publicado, el workflow falla (no lo pisa). Para rehacer un release:
  `gh release delete vX.Y.Z --cleanup-tag` y volver a pushear el tag.
- Sin auto-update — el usuario reinstala el `.dmg` a mano en cada versión.
