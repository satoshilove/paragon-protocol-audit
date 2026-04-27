# UnifiedEmissionsDistributor — SPEC

**Intent:**  
Fund weekly XPGN emissions to gauges using **finalized previous-epoch gauge weights** from `GaugeController`. Supports both direct `SimpleGauge` notifications and farm `pid` notifications.

## State
- `token` — XPGN token
- `controller` — `GaugeController`
- `farm` — external farm reward target for farm gauges
- `weeklyEmission` — target weekly emission amount
- `lastPushedWeek` — last rounded-down week distributed
- `useMinting` — whether distributor mints XPGN directly
- `treasury` — treasury funding source when `useMinting == false`
- `isSimpleGauge[gauge]` — gauge routing flag
- `isFarmGauge[gauge]` — farm routing flag
- `gaugeToPid[gauge]` — farm pid mapping

## Invariants
- **INV-UED-01 (Once per week):** `kick()` succeeds at most once per rounded week.
- **INV-UED-02 (Finalized source epoch only):** Distribution uses `sourceEp = controller.epoch() - 1` and requires that epoch to be finalized.
- **INV-UED-03 (Mapped weighted gauges only):** Any gauge with nonzero finalized weight must be mapped as either simple or farm gauge, otherwise `kick()` reverts.
- **INV-UED-04 (Fund only allocated):** The distributor funds exactly the sum of calculated gauge allocations, not the raw configured weekly target if dust or zero-share gauges reduce allocation.
- **INV-UED-05 (Exact treasury funding):** In treasury-funded mode, actual received amount must equal `allocated`.
- **INV-UED-06 (Farm approval discipline):** Farm approval is limited to exact `farmTotal` and reset to zero afterward.

## Permissions
- **DAO/Admin:** `setWeeklyEmission`, `setFundingMode`, `setFarm`, `setController`, `mapGauge`, `pause`, `unpause`
- **Anyone/Ops bot:** `kick()` once the week and source epoch conditions are satisfied

## External Interactions
- `controller.totalWeightFinal(sourceEp)`
- `controller.gaugeWeightFinal(sourceEp, gauge)`
- `IMintable(token).mint(...)` when minting enabled
- `token.safeTransferFrom(treasury, ...)` when treasury funded
- `SimpleGauge.notifyRewardAmount(amount)`
- `farm.notifyGaugeReward(pid, amount)`

## Failure Modes
- Revert if:
  - weekly emission not set
  - already pushed this week
  - previous epoch not finalized
  - no finalized total weight
  - weighted gauge is unmapped
  - treasury funding under-receives
  - no valid allocations exist

## Events
- `WeeklyEmissionUpdated(amount)`
- `FundingModeUpdated(useMinting, treasury)`
- `FarmUpdated(farm)`
- `ControllerUpdated(controller)`
- `GaugeMapped(gauge, pid, isSimple)`
- `EmissionsPushed(weekTs, sourceEpoch, totalAllocated, gaugesUsed, dustRemainder)`
- `EmergencyWithdraw(token, to, amount)`

## Tests Map
- **INV-UED-01:** `test/UnifiedEmissionsDistributor.t.sol::testKickOnlyOncePerWeek()`
- **INV-UED-02:** `test/UnifiedEmissionsDistributor.t.sol::testUsesFinalizedPreviousEpochOnly()`
- **INV-UED-03:** `test/UnifiedEmissionsDistributor.t.sol::testRevertOnUnmappedWeightedGauge()`
- **INV-UED-04:** `test/UnifiedEmissionsDistributor.t.sol::testFundsOnlyAllocatedAmount()`
- **INV-UED-05:** `test/UnifiedEmissionsDistributor.t.sol::testTreasuryFundingMustMatchAllocatedExactly()`
- **INV-UED-06:** `test/UnifiedEmissionsDistributor.t.sol::testFarmApprovalScopedToFarmTotal()`
