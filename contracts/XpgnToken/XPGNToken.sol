// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title XPGN Token — Final Audit-Ready Version (Bucketed, Hard-Capped Tokenomics)
/// @notice
/// - ERC20 governance token for Paragon with:
///   - Fixed hard cap: 550,000,000 XPGN (18 decimals)
///   - Role-based mint buckets with independent caps
///   - Permit (EIP-2612), Votes (governance), Pausable transfers
/// - The bucket caps define **absolute maximums** per category. The *planned* usage
///   of each bucket (Year 1 emissions, validator reserves, etc.) is governed by
///   off-chain tokenomics and DAO policy, but the on-chain caps cannot be exceeded.
///
/// High-level supply map (off-chain plan, not enforced by code):
/// - Total Maximum Supply (hard cap): 550,000,000 XPGN
///
/// - Genesis Liquidity & MM: 10,000,000 XPGN total
///   • 202,020 XPGN minted at deploy for initial seed liquidity
///   • ~9.8M XPGN reserve minted to treasury post-deploy and locked 12 months
///
/// - Farming & Emissions: up to 150,000,000 XPGN cap
///   • Planned Year 1 budget: 72,450,000 XPGN (3→2→1.25→0.75 / block on BSC ~0.75s blocks)
///   • Remaining ~77.55M reserved for future years (reduced schedules)
///
/// - Validator / Chain Reserve: up to 160,000,000 XPGN cap
///   • Off-chain plan: ~100M actively used for validators, rest unminted/locked as long-term security reserve
///
/// - Ecosystem / Partners: up to 55,000,000 XPGN cap
///   • Streamed monthly (450k max) after ECOSYSTEM_START_TIME; includes 6M locked airdrops + Eggs/Sigils/points
///
/// - Treasury & DAO: up to 40,000,000 XPGN cap
///   • Used for protocol-owned liquidity, buybacks (100% fees), incentives, ops
///
/// - Team: up to 55,000,000 XPGN cap (must mint to teamVesting)
/// - Advisors: up to 10,000,000 XPGN cap (must mint to advisorVesting)
///
/// - DAO Supplemental / Long-Term Buffer: up to 70,000,000 XPGN cap
///   • Mintable only by DAO-controlled role for future needs (e.g. extra POL, new chain incentives),
///     still under the global 550M cap.
///
/// NOTE (caps vs hard cap):
/// - Sum of bucket caps (excluding GENESIS) =
///     150M (FARMING)
///   + 160M (VALIDATOR)
///   +  55M (ECOSYSTEM)
///   +  40M (TREASURY)
///   +  55M (TEAM)
///   +  10M (ADVISOR)
///   +  70M (SUPPLEMENTAL)
///   = 540,000,000 XPGN
/// - Conceptual GENESIS allocation = 10,000,000 XPGN
/// - Total planned = 550,000,000 XPGN, matching the ERC20Capped hard cap.
///
/// The contract enforces:
/// - 550M global cap (ERC20Capped)
/// - Per-bucket caps (FARMING / VALIDATOR / ECOSYSTEM / TREASURY / TEAM / ADVISOR / SUPPLEMENTAL)
/// - Ecosystem mints: 1x per 30 days, post-start, <= ECOSYSTEM_MONTHLY_LIMIT
/// - Team / Advisor must mint only to their vesting contracts.
/// The **exact emission schedule** (e.g. Q1/Q2/Q3/Q4 emissions) is implemented
/// in the farm + dripper + gauge system, *within* these static caps.
contract XPGNToken is ERC20Capped, ERC20Permit, ERC20Votes, AccessControlEnumerable, Pausable {
    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    /// @notice DAO multisig / core admin address (separate from DEFAULT_ADMIN_ROLE if you ever rotate)
    address public admin;

    // -----------------------------------------------------------------------
    // Roles
    // -----------------------------------------------------------------------

    bytes32 public constant FARMING_MINTER_ROLE      = keccak256("FARMING_MINTER_ROLE");      // farms / gauges (MasterChef / gauges)
    bytes32 public constant VALIDATOR_MINTER_ROLE    = keccak256("VALIDATOR_MINTER_ROLE");    // validator / chain reserve distributor
    bytes32 public constant ECOSYSTEM_MINTER_ROLE    = keccak256("ECOSYSTEM_MINTER_ROLE");    // ecosystem / partners / grants (streamed)
    bytes32 public constant TREASURY_MINTER_ROLE     = keccak256("TREASURY_MINTER_ROLE");     // DAO & Treasury ops (buybacks, POL, incentives)
    bytes32 public constant TEAM_MINTER_ROLE         = keccak256("TEAM_MINTER_ROLE");         // only to teamVesting
    bytes32 public constant ADVISOR_MINTER_ROLE      = keccak256("ADVISOR_MINTER_ROLE");      // only to advisorVesting
    bytes32 public constant SUPPLEMENTAL_MINTER_ROLE = keccak256("SUPPLEMENTAL_MINTER_ROLE"); // DAO supplemental / long-term buffer

    // -----------------------------------------------------------------------
    // Bucket Caps (all 18 decimals, HARD MAXIMUMS)
    // -----------------------------------------------------------------------

    /// @dev Maximum XPGN that can ever be minted for farming, gauges, and all
    /// reward/emission mechanisms combined. The **planned** Year 1 emissions
    /// (~72.45M XPGN) are a subset of this, leaving ~77.55M headroom for future years
    /// with lower emission rates. Cannot be increased after deployment.
    uint256 public constant FARMING_MINT_CAP = 150_000_000 ether; // Liquidity & Gauges (emissions, multi-year max);

    /// @dev Maximum XPGN reserved for validators / chain security / staking.
    /// Off-chain plan: ~100M actively used, rest unminted/locked as long-term security reserve.
    uint256 public constant VALIDATOR_MINT_CAP = 160_000_000 ether; // Validator / Chain Reserve (planned subset)

    /// @dev Maximum XPGN for ecosystem growth: integrations, partners, grants,
    /// points → veXPGN programs, and campaign incentives (incl. 6M locked airdrops). Actual streaming is
    /// governed by ECOSYSTEM_* config below (time-gated, monthly limit).
    uint256 public constant ECOSYSTEM_MINT_CAP = 55_000_000 ether; // Ecosystem / Airdrops / Utilities (streamed)

    /// @dev Maximum XPGN for Treasury / DAO ops: protocol-owned liquidity,
    /// buyback funding (100% fees), strategic incentives, and emergency buffers.
    uint256 public constant TREASURY_MINT_CAP = 40_000_000 ether; // DAO & Treasury (buybacks, POL, ops)

    /// @dev Maximum XPGN for team allocations. All mints MUST go to teamVesting,
    /// which enforces 12mo cliff + 36mo linear vesting (first unlock 2027).
    uint256 public constant TEAM_MINT_CAP = 55_000_000 ether; // Team (must mint to teamVesting)

    /// @dev Maximum XPGN for advisors / early helpers. All mints MUST go to
    /// advisorVesting, which enforces 24mo linear vesting.
    uint256 public constant ADVISOR_MINT_CAP = 10_000_000 ether; // Advisors (must mint to advisorVesting)

    /// @dev Maximum XPGN for DAO-controlled supplemental needs: future POL, new chain incentives,
    /// or long-term expansions. Mintable only by SUPPLEMENTAL_MINTER_ROLE and still under the 550M cap.
    uint256 public constant SUPPLEMENTAL_MINT_CAP = 70_000_000 ether; // DAO supplemental buffer

    /// @dev Total genesis allocation for initial DEX liquidity / MM.
    /// GENESIS_MINT_AMOUNT is the *conceptual* total genesis allocation (10M).
    /// At deploy, only 202,020 XPGN are minted here for the launch seed.
    /// The remaining reserve is minted later via TREASURY_MINTER_ROLE and counts against TREASURY_MINT_CAP.
    uint256 public constant GENESIS_MINT_AMOUNT = 10_000_000 ether; // Genesis Liquidity & MM (202k launch + 9.8M reserve via treasury)

    // -----------------------------------------------------------------------
    // Ecosystem streaming config (monthly)
    // -----------------------------------------------------------------------

    /// @notice Earliest timestamp at which ecosystem streaming can begin.
    /// Before this time, ECOSYSTEM_MINTER_ROLE cannot mint at all.
    uint256 public constant ECOSYSTEM_START_TIME = 1769852348; // Jan 31, 2026 UTC

    /// @notice Minimum time between two ecosystem mints. Enforces a simple
    /// "one mint per 30 days" schedule at the contract level.
    uint256 public constant ECOSYSTEM_VESTING_PERIOD = 30 days;

    /// @notice Maximum XPGN that can be minted in a single ecosystem mint
    /// (i.e. per 30-day epoch). This, combined with the total ECOSYSTEM_MINT_CAP,
    /// bounds both the **rate** and **total** of ecosystem emissions.
    uint256 public constant ECOSYSTEM_MONTHLY_LIMIT = 450_000 ether;

    // -----------------------------------------------------------------------
    // Mint tracking
    // -----------------------------------------------------------------------

    uint256 public farmingMinted;
    uint256 public validatorMinted;
    uint256 public ecosystemMinted;
    uint256 public treasuryMinted;
    uint256 public teamMinted;
    uint256 public advisorMinted;
    uint256 public supplementalMinted;

    uint256 public lastEcosystemMintTime;
    bool    public validatorMintingEnabled;

    // -----------------------------------------------------------------------
    // Enforced recipients (vesting)
    // -----------------------------------------------------------------------

    /// @notice All TEAM mints must go to this vesting contract. The vesting
    /// contract enforces 12mo cliff + 36mo linear vesting (first unlock 2027).
    address public immutable teamVesting;    // all TEAM mints must go here

    /// @notice All ADVISOR mints must go to this vesting contract, which handles
    /// 24mo linear vesting.
    address public immutable advisorVesting; // all ADVISOR mints must go here

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event Mint(address indexed to, uint256 amount, bytes32 indexed role);
    event ValidatorMintingEnabled(address indexed admin);
    event ValidatorMintingDisabled(address indexed admin);
    event AdminUpdated(address indexed newAdmin);

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @param daoMultisig      DAO multisig / admin (DEFAULT_ADMIN_ROLE holder)
    /// @param masterChef       farming controller (ParagonFarmController / gauges)
    /// @param validatorRewards validator reserve distributor contract
    /// @param _teamVesting     team vesting contract (enforced recipient)
    /// @param _advisorVesting  advisor vesting contract (enforced recipient)
    /// @param genesisRecipient recipient of 202,020 genesis liquidity (DEX seed; reserve minted separately to treasury)
    constructor(
        address daoMultisig,
        address masterChef,
        address validatorRewards,
        address _teamVesting,
        address _advisorVesting,
        address genesisRecipient
    )
        ERC20("XPGN Token", "XPGN")
        ERC20Capped(550_000_000 ether)
        ERC20Permit("XPGN Token")
    {
        require(daoMultisig      != address(0), "INVALID_DAO_MULTISIG");
        require(masterChef       != address(0), "INVALID_MASTERCHEF");
        require(validatorRewards != address(0), "INVALID_VALIDATOR_REWARDS");
        require(_teamVesting     != address(0), "INVALID_TEAM_VESTING");
        require(_advisorVesting  != address(0), "INVALID_ADVISOR_VESTING");
        require(genesisRecipient != address(0), "INVALID_GENESIS_RECIPIENT");

        admin = daoMultisig;
        _grantRole(DEFAULT_ADMIN_ROLE, daoMultisig);

        // Assign minters per bucket
        _grantRole(FARMING_MINTER_ROLE,      masterChef);
        _grantRole(VALIDATOR_MINTER_ROLE,    validatorRewards);
        _grantRole(ECOSYSTEM_MINTER_ROLE,    daoMultisig);
        _grantRole(TREASURY_MINTER_ROLE,     daoMultisig);
        _grantRole(TEAM_MINTER_ROLE,         daoMultisig);
        _grantRole(ADVISOR_MINTER_ROLE,      daoMultisig);
        _grantRole(SUPPLEMENTAL_MINTER_ROLE, daoMultisig); // DAO-only supplemental buffer

        teamVesting    = _teamVesting;
        advisorVesting = _advisorVesting;

        // Launch Seed Mint: Only 202,020 XPGN for initial seed liquidity
        // Remaining genesis reserve is minted later via TREASURY_MINTER_ROLE and locked 12 months.
        _mint(genesisRecipient, 202_020 ether);
        emit Mint(genesisRecipient, 202_020 ether, bytes32("GENESIS_LAUNCH_SEED"));

        // Ecosystem streaming not yet used
        lastEcosystemMintTime = 0;
    }

    // -----------------------------------------------------------------------
    // Admin helpers
    // -----------------------------------------------------------------------

    function getAdmin() external view returns (address) {
        return admin;
    }

    /// @notice Optional: rotate admin label (does NOT change DEFAULT_ADMIN_ROLE).
    /// Can be used if the DAO migrates control from one multisig to another.
    function setAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAdmin != address(0), "INVALID_ADMIN");
        admin = newAdmin;
        emit AdminUpdated(newAdmin);
    }

    function enableValidatorMinting() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!validatorMintingEnabled, "VALIDATOR_ALREADY_ENABLED");
        validatorMintingEnabled = true;
        emit ValidatorMintingEnabled(msg.sender);
    }

    function disableValidatorMinting() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(validatorMintingEnabled, "VALIDATOR_ALREADY_DISABLED");
        validatorMintingEnabled = false;
        emit ValidatorMintingDisabled(msg.sender);
    }

    // -----------------------------------------------------------------------
    // Minting
    // -----------------------------------------------------------------------

    /// @notice Unified mint entry. Role determines which bucket/cap applies.
    /// @dev TEAM / ADVISOR mints are forced to their vesting contracts.
    ///      All per-bucket caps plus the global 550M cap are enforced.
    function mint(address to, uint256 amount, bytes32 role) external {
        require(
            role == FARMING_MINTER_ROLE      ||
            role == VALIDATOR_MINTER_ROLE    ||
            role == ECOSYSTEM_MINTER_ROLE    ||
            role == TREASURY_MINTER_ROLE     ||
            role == TEAM_MINTER_ROLE         ||
            role == ADVISOR_MINTER_ROLE      ||
            role == SUPPLEMENTAL_MINTER_ROLE,
            "INVALID_ROLE"
        );
        require(hasRole(role, msg.sender), "CALLER_NOT_MINTER");
        require(amount > 0, "ZERO_AMOUNT");

        if (role == FARMING_MINTER_ROLE) {
            farmingMinted += amount;
            require(farmingMinted <= FARMING_MINT_CAP, "FARMING_CAP_EXCEEDED");

        } else if (role == VALIDATOR_MINTER_ROLE) {
            require(validatorMintingEnabled, "VALIDATOR_DISABLED");
            validatorMinted += amount;
            require(validatorMinted <= VALIDATOR_MINT_CAP, "VALIDATOR_CAP_EXCEEDED");

        } else if (role == ECOSYSTEM_MINTER_ROLE) {
            // Simple “one mint per 30 days, <= monthly limit” after start date
            require(block.timestamp >= ECOSYSTEM_START_TIME, "ECOSYSTEM_NOT_STARTED");

            if (lastEcosystemMintTime != 0) {
                require(
                    block.timestamp >= lastEcosystemMintTime + ECOSYSTEM_VESTING_PERIOD,
                    "ECOSYSTEM_COOLDOWN"
                );
            }

            require(amount <= ECOSYSTEM_MONTHLY_LIMIT, "ECOSYSTEM_MONTHLY_LIMIT");
            ecosystemMinted += amount;
            require(ecosystemMinted <= ECOSYSTEM_MINT_CAP, "ECOSYSTEM_CAP_EXCEEDED");

            lastEcosystemMintTime = block.timestamp;

        } else if (role == TREASURY_MINTER_ROLE) {
            treasuryMinted += amount;
            require(treasuryMinted <= TREASURY_MINT_CAP, "TREASURY_CAP_EXCEEDED");

        } else if (role == TEAM_MINTER_ROLE) {
            require(to == teamVesting, "TEAM_TO_MUST_BE_VESTING");
            teamMinted += amount;
            require(teamMinted <= TEAM_MINT_CAP, "TEAM_CAP_EXCEEDED");

        } else if (role == ADVISOR_MINTER_ROLE) {
            require(to == advisorVesting, "ADVISOR_TO_MUST_BE_VESTING");
            advisorMinted += amount;
            require(advisorMinted <= ADVISOR_MINT_CAP, "ADVISOR_CAP_EXCEEDED");

        } else {
            // SUPPLEMENTAL_MINTER_ROLE
            supplementalMinted += amount;
            require(supplementalMinted <= SUPPLEMENTAL_MINT_CAP, "SUPPLEMENTAL_CAP_EXCEEDED");
        }

        _mint(to, amount);
        emit Mint(to, amount, role);
        // ERC20Capped will also enforce the global 550M cap across all buckets + GENESIS
    }

    // -----------------------------------------------------------------------
    // Pause controls (emergency)
    // -----------------------------------------------------------------------

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // -----------------------------------------------------------------------
    // Internal hooks & overrides
    // -----------------------------------------------------------------------

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Capped, ERC20Votes)
    {
        // Block transfers when paused, but allow mint/burn (from == 0 or to == 0)
        if (from != address(0)) {
            require(!paused(), "PAUSED");
        }
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
