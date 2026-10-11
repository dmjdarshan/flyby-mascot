# FlyBy repository guidance

These instructions apply to the entire repository. Keep them concise and update them when the architecture or verification workflow materially changes.

## Product contract

- FlyBy is an ambient macOS menu-bar utility that reacts to nearby real aircraft.
- Presentation safety is the highest-priority product invariant. When the guard becomes unsafe, cancel queued overlays and remove visible overlays immediately.
- Never claim capture suppression is universal. Describe automatic detection as best effort and keep manual pause available.
- Prefer accurate live state over guessed enrichment. Never invent callsigns, aircraft types, routes, origins, or destinations.
- Keep the exact selected location and preferences local. Do not add accounts, analytics, telemetry, or call/screen-sharing history without explicit approval.
- Keep demo mode deterministic, local, and network-free.

## Architecture boundaries

- `FlyByCore` owns models, provider protocols, proximity calculations, eligibility, cooldowns, and presentation decisions. It must not import AppKit or SwiftUI.
- `FlyByApp` owns SwiftUI/AppKit presentation, menu-bar state, windows, permissions, and platform integration.
- Provider adapters normalize external data into `AircraftObservation`; UI code must not depend on provider-specific response types.
- Keep presentation-safety policy independent from overlay mechanics so either can evolve after compatibility testing.
- Use a mascot-sized moving panel. Do not introduce a full-screen transparent click-intercepting window.

## Swift standards

- Write Swift 6-compatible code and treat concurrency warnings as design feedback.
- Put UI and AppKit coordination on `@MainActor`. Values crossing actor boundaries must be `Sendable` or safely isolated.
- Prefer value types and pure functions in `FlyByCore`; use actors only for shared mutable state.
- Avoid force unwraps, `try!`, implicitly unwrapped optionals, and silent `catch` blocks in production code.
- Normalize units at boundaries: kilometers for user-facing radius/distance, meters and meters/second in observations, degrees clockwise from true north for track.
- Inject time or accept `now` parameters in time-sensitive domain logic so tests remain deterministic.
- Surface stale data, missing fields, provider health, and attribution honestly.
- Add comments for non-obvious safety or numerical reasoning, not for syntax that explains itself.

## Change workflow

1. Read `README.md`, `Package.swift`, and the affected types before editing.
2. Preserve unrelated work and keep changes scoped to the request.
3. Add or update deterministic tests for behavior changes, especially proximity, cooldown, polling, provider normalization, and presentation safety.
4. Run `sh .codex/verify.sh` before declaring implementation complete.
5. Report any unrun checks and the exact environment blocker.
6. Update `README.md` when setup, architecture, privacy behavior, or verification commands change.

Do not add a production dependency, provider, permission, entitlement, persistent data store, or network service without explaining the tradeoff and confirming it is required by the requested scope.

## Verification expectations

- Minimum for any Swift change: parser validation, `FlyBy` product build, and `FlyByCoreChecks`.
- With full Xcode available: also run `swift test` and relevant UI/manual checks.
- Presentation or overlay changes require manual validation on a real macOS desktop; record which displays, Spaces/full-screen modes, Reduce Motion state, and capture apps were exercised.
- Provider work requires fixtures for malformed, partial, stale, on-ground, and rate-limited responses. Tests must not depend on a live community endpoint.

## Review priorities

Review in this order:

1. Privacy or presentation-safety regressions.
2. Incorrect eligibility, closest-approach, deduplication, or unit handling.
3. Actor-isolation, cancellation, lifecycle, and window-management defects.
4. Provider terms, attribution, backoff, and failure behavior.
5. Accessibility, Reduce Motion, multi-display behavior, and visual polish.

## Source of truth

- Repository behavior and setup: `README.md` and code.
- Product scope and known risks: the linked FlyBy Notion specification and implementation plan when the Notion connector is available.
- Current implementation status: verified code and checks, not stale planning percentages.
