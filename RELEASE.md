# Release process (maintainer notes)

1. Bump `version` in `wally.toml` if dependencies changed.
2. Update `default.project.json` / `sourcemap.json` if the tree changed.
3. Tag: `git tag v1.0.0 && git push origin v1.0.0` — Wally/GitHub both pick this up.
4. CI (`.github/workflows/ci.yml`) must be green: analyze + tests + rojo build.

Wally usage for consumers:

```bash
wally pollinations/pollinations-roblox
```

or in `wally.toml`:

```toml
[dependencies]
Pollinations = "pollinations/pollinations-roblox@1.0.0"
```
