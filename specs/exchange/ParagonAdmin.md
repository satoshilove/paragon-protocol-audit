# ParagonAdmin — SPEC


**Intent:** Centralized parameter & safety control for Exchange components (fees, slippage caps, whitelists, emergency pause).


## State
- `isPaused` — global emergency switch affecting Router critical paths
- Bounded params: `lpFeeBps`, `maxSlippageBps`, oracle staleness, etc. (see PARAMS_REGISTRY.md)
- Role addresses: DAO (timelock), Guardian (multisig), Ops (if any)


## Invariants
- **INV-AD-01:** All setters enforce on-chain bounds (e.g., `lpFeeBps <= 100`, `maxSlippageBps <= 1000`) and emit events
- **INV-AD-02:** Pause gating enforced by guarded modules (Router/Oracle respect `isPaused` when required)


## Permissions
- DAO: bounded setters
- Guardian: `pause/unpause` only (no value-setting)


## External Interactions
- Read-only checks by Router; emits configuration events


## Failure Modes
- Revert on out-of-bounds values, zero addresses for critical roles


## Events
- `ParamUpdated(key, old, new)`, `Paused()`, `Unpaused()`


## Tests Map
- INV-AD-01: `test/Admin.t.sol::testBoundsForSetters()`
- INV-AD-02: `test/Admin.t.sol::testPauseGatesRouter()`