<!-- blueprint:start -->
## Planning with blueprint

This project plans its work with the `blueprint` plugin.

- High-level design, in this directory: `SYSTEM.md`, `ARCHITECTURE.md`, `ROADMAP.md`, and decision records in `docs/adr/`. Work on it with `/hld`.
- Low-level design, one directory per component: `.blueprints/<component>/`, holding `INTENT.md`, `SPEC.md`, `PROOFS.md` and `PLAN.md`. Work on it with `/lld <component>`.
- Templates: `.blueprints/_rules/`. Every planning document follows its template there.
- Agents propose options with trade-offs. The operator decides.
<!-- blueprint:end -->
