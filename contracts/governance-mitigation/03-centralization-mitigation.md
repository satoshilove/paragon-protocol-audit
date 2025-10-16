# PAC-11 | Centralization Related Risks

**Status:** Acknowledged — mitigated in code, to be fully resolved at deployment (pre-launch).

## What we changed (code-level)

- Added **pause-guardian** pattern (pause-only multisig) to:
  - `ParagonPayflowExecutorV2` (guardian can `pause`; only Timelock can `unpause` & change params).
  - `ParagonLockerCollector` (guardian can `pause`; only Timelock can `unpause` & change params).
- Ensured all sensitive mutators remain **`onlyOwner`**, so once ownership is moved to the Timelock they’re **time-locked** actions.
- Added/confirmed **event emissions** on critical setters (e.g., `ChainlinkUsdValuer.setFeed`).

## Governance rollout (pre-launch plan)

At mainnet deployment we will not leave any contract owned by an EOA. Ownership transfers are part of our deployment script.

- **Core Safe (Gnosis Safe)** — multisig, threshold **3/5**.
- **TimelockController (OpenZeppelin)** — `minDelay = 48h`.
  - `PROPOSER_ROLE` → **Core Safe**
  - `EXECUTOR_ROLE` → `address(0)` (permissionless) **or** Core Safe
  - `TIMELOCK_ADMIN_ROLE` → **Timelock itself** (self-admin) for strict governance
- **Guardian Safe** — smaller multisig (e.g., **2/3**) with **pause-only** powers on Executor & Locker.

**Contracts whose `owner` will be Timelock (48h delay):**

- `ParagonPayflowExecutorV2`
- `ParagonLockerCollector`
- `LPFlowRebates`
- `TreasurySplitter`
- `ChainlinkUsdValuer`
- `ParagonBestExecutionV14`

## Authority matrix (who can do what)

**Timelock (via Core Safe proposals)** — all `onlyOwner` functions:

- **ParagonPayflowExecutorV2:** `setParams`, `setSplitBips`, `setRelayerFeeBips`, `setReputationOperator`, `setUsdValuer`, `setSupportedToken`, `setRelayer`, `setVenueEnabled`, `sweep`, `sweepNative`, `unpause`.
- **LPFlowRebates:** `setNotifier`, `addSupportedReward`, `removeSupportedReward`, `setAllowedLp`, `emergencySweep`.
- **ParagonLockerCollector:** `setReceiver`, `setRouter`, `setVault`, `setAllowedToken(s)`, `sweep`, `withdrawNative`, `unpause`.
- **TreasurySplitter:** `setSinks`, `distribute`, `sweep`, `sweepNative`.
- **ChainlinkUsdValuer:** `setFeed`, `clearFeed`, `setMaxPrice1e18`, `pause`, `unpause`.
- **ParagonBestExecutionV14:** `setAuthorizedExecutor`, `sweepNative` (+ existing setters).

**Guardian Safe:** `pause()` on Executor & Locker only (no `unpause`, no parameter changes).

## Rationale

- Eliminates single-key risk; all privileged changes go through a **48h public timelock** with **multisig** approval.
- **Pause-guardian** gives a quick circuit-breaker without treasury/param powers.
- We will publish addresses and signer policy before TGE.

## Evidence in this repo (now)

- `docs/security/01-governance-one-pager.md` — governance model (Timelock + multisigs, thresholds, roles).
- `docs/security/02-function-authority-matrix.md` — per-function authority mapping (Timelock vs Guardian).
- Code diffs:
  - `ParagonPayflowExecutorV2` — `Pausable`, guardian, `onlyOwnerOrGuardian` for `pause`, owner-only `unpause`.
  - `ParagonLockerCollector` — `Pausable`, guardian, `whenNotPaused` on external flows.
  - `ChainlinkUsdValuer` — events & pausable admin.

## Post-deployment evidence (to be added before launch)

- **Addresses**
  - Core Safe (3/5): `<SAFE_ADDRESS>`
  - Guardian Safe (2/3): `<GUARDIAN_SAFE_ADDRESS>`
  - TimelockController (48h): `<TIMELOCK_ADDRESS>`
- **Tx hashes**
  - Timelock role setup: `<TX_HASH_1>`, `<TX_HASH_2>`, …
  - Ownership transfers to Timelock for each contract: `<TX_HASH_XYZ>`
- **Public note**
  - Governance post with addresses & policy: `<LINK>`

## Verification checklist (for auditors/community)

- Each contract `owner()` returns `<TIMELOCK_ADDRESS>`.
- Timelock roles:
  - `PROPOSER_ROLE` → `<SAFE_ADDRESS>`
  - `EXECUTOR_ROLE` → `0x0000…0000` (or `<SAFE_ADDRESS>`)
  - `TIMELOCK_ADMIN_ROLE` → `<TIMELOCK_ADDRESS>`
- Guardian Safe is set as `guardian` on:
  - `ParagonPayflowExecutorV2.guardian()`
  - `ParagonLockerCollector.guardian()`
