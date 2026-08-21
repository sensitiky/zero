# Security-by-default (incu)

- Run the security scans (Snyk SAST + Snyk SCA + SonarQube) before any review gate; never report a scan
  as clean when it did not run.
- Fix issues introduced by the current change; pre-existing issues are out of scope unless the fix is trivial.
- Never commit secrets; reference them via env/keychain, never inline.
