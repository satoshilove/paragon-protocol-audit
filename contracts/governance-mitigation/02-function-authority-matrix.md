All functions below remain onlyOwner. After ownership transfer, “owner” = timelock, so every call is delayed 48h and gated by the multisig.

Contract	Sensitive functions → Authority after fix

ChainlinkUsdValuer	setFeed() → Timelock

LPFlowRebates	setNotifier(), addSupportedReward(), removeSupportedReward(), setAllowedLp(), emergencySweep() → Timelock

ParagonLockerCollector	setReceiver(), setRouter(), setVault(), setAllowedToken(), setAllowedTokens(), sweep(), withdrawNative() → Timelock; pause() → Guardian OR Timelock; unpause() → Timelock

ParagonPayflowExecutorV2	setParams(), setSplitBips(), setRelayerFeeBips(), setReputationOperator(), setUsdValuer(), setRelayer(), setVenueEnabled(), setSupportedToken(), sweep(), sweepNative() → Timelock; pause() → Guardian OR Timelock; unpause() → Timelock

ParagonBestExecutionV14	setAuthorizedExecutor() → Timelock

TreasurySplitter	setSinks(), distribute(), sweep(), sweepNative() → Timelock