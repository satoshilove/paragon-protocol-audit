Paragon Protocol — Governance & Admin Controls (Pre-Launch Plan)

Multisig (Core Gov Safe): Gnosis Safe, threshold 3/5 (final address to be published prior to activation).

Timelock: OpenZeppelin TimelockController, minDelay = 48 hours.

Proposers: Core Gov Safe

Executors: Core Gov Safe (we will open to address(0) post-launch if desired)

Admin: Core Gov Safe (self-admin pattern can be adopted later)

Guardian (Emergency Pause): separate Gnosis Safe, threshold 2/3, with pause-only powers on:

ParagonPayflowExecutorV2 (can pause, cannot unpause)

ParagonLockerCollector (can pause, cannot unpause)

Ownership: all Ownable contracts transfer ownership to Timelock before enabling swaps.

Transparency: final Safe & Timelock addresses, signers policy, and timelock delay will be published in docs prior to enabling execution.