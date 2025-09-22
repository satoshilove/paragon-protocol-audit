# XPGN Token

**Intent:** ERC20 with capped supply (550M), permit, votes, pausable transfers, and role-based bucket caps aligned to tokenomics.

**State:** admin, role minters, bucket caps & cumulative minted, monthly ecosystem stream (start time, 30-day cadence, monthly limit), validator toggle, enforced recipients for Team/Advisor.

**Invariants**
- `INV-XPGN-01`: Only addresses with proper role can mint that bucket.
- `INV-XPGN-02`: Each bucket’s minted total ≤ its cap.
- `INV-XPGN-03`: Team/Advisor mints must target their vesting recipients.
- `INV-XPGN-04`: Validator minting requires `validatorMintingEnabled`.
- `INV-XPGN-05`: Ecosystem mints: not before start, ≤ monthly limit, one mint per 30 days.
- `INV-XPGN-06`: Pause blocks transfers but not minting (for ops).
- `INV-XPGN-07`: `permit` and `votes` behave per ERC-2612 / ERC20Votes.

**Tests:** `test/token/XPGNToken.spec.js`.
