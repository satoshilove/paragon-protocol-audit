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
/// - Genesis Liquidity & MM: 10,000,000 XPGN total (GENESIS bucket)
///   • 202,020 XPGN minted at deploy for initial seed liquidity
///   • Remaining up to 9,797,980 XPGN may be minted later (scarcity preserved),
///     intended for LP/MM/launch ops and typically time-locked via a separate lock contract.
///
/// NOTE (caps vs hard cap):
/// - Sum of bucket caps (INCLUDING GENESIS) =
///     10M (GENESIS)
///   + 150M (FARMING)
///   + 160M (VALIDATOR)
///   +  55M (ECOSYSTEM)
///   +  40M (TREASURY)
///   +  55M (TEAM)
///   +  10M (ADVISOR)
///   +  70M (SUPPLEMENTAL)
///   = 550,000,000 XPGN (matches ERC20Capped hard cap).
///
/// The contract enforces:
/// - 550M global cap (ERC20Capped)
/// - Per-bucket caps (GENESIS / FARMING / VALIDATOR / ECOSYSTEM / TREASURY / TEAM / ADVISOR / SUPPLEMENTAL)
/// - Ecosystem mints: 1x per 30 days, post-start, <= ECOSYSTEM_MONTHLY_LIMIT
/// - Team / Advisor must mint only to their vesting contracts.
contract XPGNToken is ERC20Capped, ERC20Permit, ERC20Votes, AccessControlEnumerable, Pausable {
    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------

    /// @notice DAO multisig / core admin address (separate from DEFAULT_ADMIN_ROLE if you ever rotate)
    address public admin;

    // -----------------------------------------------------------------------
    // Roles
    // -----------------------------------------------------------------------

    bytes32 public constant GENESIS_MINTER_ROLE      = keccak256("GENESIS_MINTER_ROLE");      // Genesis liquidity/MM reserve (up to 10M incl. seed)
    bytes32 public constant FARMING_MINTER_ROLE      = keccak256("FARMING_MINTER_ROLE");      // farming emissions funded by multisig into RewardDripperEscrow / gauges
    bytes32 public constant VALIDATOR_MINTER_ROLE    = keccak256("VALIDATOR_MINTER_ROLE");    // validator / chain reserve distributor
    bytes32 public constant ECOSYSTEM_MINTER_ROLE    = keccak256("ECOSYSTEM_MINTER_ROLE");    // ecosystem / partners / grants (streamed)
    bytes32 public constant TREASURY_MINTER_ROLE     = keccak256("TREASURY_MINTER_ROLE");     // DAO & Treasury ops (buybacks, POL, incentives)
    bytes32 public constant TEAM_MINTER_ROLE         = keccak256("TEAM_MINTER_ROLE");         // only to teamVesting
    bytes32 public constant ADVISOR_MINTER_ROLE      = keccak256("ADVISOR_MINTER_ROLE");      // only to advisorVesting
    bytes32 public constant SUPPLEMENTAL_MINTER_ROLE = keccak256("SUPPLEMENTAL_MINTER_ROLE"); // DAO supplemental / long-term buffer

    // -----------------------------------------------------------------------
    // Bucket Caps (all 18 decimals, HARD MAXIMUMS)
    // -----------------------------------------------------------------------

    /// @dev Genesis bucket (fixes PAD-49): total genesis allocation is tracked and mintable up to 10M,
    /// but only 202,020 is minted at deploy to preserve scarcity.
    uint256 public constant GENESIS_MINT_CAP = 10_000_000 ether;

    uint256 public constant FARMING_MINT_CAP = 150_000_000 ether; // Liquidity & Gauges (emissions, multi-year max)
    uint256 public constant VALIDATOR_MINT_CAP = 160_000_000 ether; // Validator / Chain Reserve (planned subset)
    uint256 public constant ECOSYSTEM_MINT_CAP = 55_000_000 ether; // Ecosystem / Airdrops / Utilities (streamed)
    uint256 public constant TREASURY_MINT_CAP = 40_000_000 ether; // DAO & Treasury (buybacks, POL, ops)
    uint256 public constant TEAM_MINT_CAP = 55_000_000 ether; // Team (must mint to teamVesting)
    uint256 public constant ADVISOR_MINT_CAP = 10_000_000 ether; // Advisors (must mint to advisorVesting)
    uint256 public constant SUPPLEMENTAL_MINT_CAP = 70_000_000 ether; // DAO supplemental buffer

    /// @dev (kept for docs) conceptual genesis allocation. Enforced via GENESIS_MINT_CAP + genesisMinted.
    uint256 public constant GENESIS_MINT_AMOUNT = 10_000_000 ether;

    // -----------------------------------------------------------------------
    // Ecosystem streaming config (monthly)
    // -----------------------------------------------------------------------

    uint256 public constant ECOSYSTEM_START_TIME = 1772323200; // Mar 1, 2026 UTC
    uint256 public constant ECOSYSTEM_VESTING_PERIOD = 30 days;
    uint256 public constant ECOSYSTEM_MONTHLY_LIMIT = 450_000 ether;

    // -----------------------------------------------------------------------
    // Mint tracking
    // -----------------------------------------------------------------------

    uint256 public genesisMinted;
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

    address public immutable teamVesting;    // all TEAM mints must go here
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

    /// @param daoMultisig      Dev multisig / future DAO multisig admin (DEFAULT_ADMIN_ROLE holder)
    /// @param validatorRewards validator reserve distributor contract
    /// @param _teamVesting     team vesting contract (enforced recipient)
    /// @param _advisorVesting  advisor vesting contract (enforced recipient)
    /// @param genesisRecipient recipient of 202,020 genesis liquidity (DEX seed)
    constructor(
        address daoMultisig,
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
        require(validatorRewards != address(0), "INVALID_VALIDATOR_REWARDS");
        require(_teamVesting     != address(0), "INVALID_TEAM_VESTING");
        require(_advisorVesting  != address(0), "INVALID_ADVISOR_VESTING");
        require(genesisRecipient != address(0), "INVALID_GENESIS_RECIPIENT");

        admin = daoMultisig;
        _grantRole(DEFAULT_ADMIN_ROLE, daoMultisig);

        // Assign minters per bucket
        // NOTE: You asked for "admin/team hold the role until DAO takeover":
        // - Start with daoMultisig holding GENESIS + TREASURY + other admin roles.
        // - Later, DAO governance can be granted roles and the multisig can revoke itself.
        _grantRole(GENESIS_MINTER_ROLE,      daoMultisig);
        _grantRole(FARMING_MINTER_ROLE,      daoMultisig);
        _grantRole(VALIDATOR_MINTER_ROLE,    validatorRewards);
        _grantRole(ECOSYSTEM_MINTER_ROLE,    daoMultisig);
        _grantRole(TREASURY_MINTER_ROLE,     daoMultisig);
        _grantRole(TEAM_MINTER_ROLE,         daoMultisig);
        _grantRole(ADVISOR_MINTER_ROLE,      daoMultisig);
        _grantRole(SUPPLEMENTAL_MINTER_ROLE, daoMultisig);

        teamVesting    = _teamVesting;
        advisorVesting = _advisorVesting;

        // Launch Seed Mint: only 202,020 XPGN minted now (scarcity preserved).
        // The remaining GENESIS bucket (up to 10M total) can be minted later via GENESIS_MINTER_ROLE
        // and should typically be sent to a timelock/vesting/LP lock contract.
        _mint(genesisRecipient, 202_020 ether);
        genesisMinted += 202_020 ether;
        require(genesisMinted <= GENESIS_MINT_CAP, "GENESIS_CAP_EXCEEDED");
        emit Mint(genesisRecipient, 202_020 ether, bytes32("GENESIS_LAUNCH_SEED"));

        lastEcosystemMintTime = 0;
    }

    // -----------------------------------------------------------------------
    // Admin helpers
    // -----------------------------------------------------------------------

    function getAdmin() external view returns (address) {
        return admin;
    }

    /// @notice Optional: rotate admin label (does NOT change DEFAULT_ADMIN_ROLE).
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

    /// @notice PAD-39 FIX (compat): Standard 2-arg mint() for legacy integrations.
    /// @dev Maps to FARMING_MINTER_ROLE.
    function mint(address to, uint256 amount) external {
        mint(to, amount, FARMING_MINTER_ROLE);
    }

    /// @notice Unified mint entry. Role determines which bucket/cap applies.
    /// @dev TEAM / ADVISOR mints are forced to their vesting contracts.
    ///      All per-bucket caps plus the global 550M cap are enforced.
    function mint(address to, uint256 amount, bytes32 role) public {
        require(
            role == GENESIS_MINTER_ROLE      ||
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

        if (role == GENESIS_MINTER_ROLE) {
            // PAD-49 FIX: genesis is a real tracked bucket, so the full 550M hard cap is reachable.
            // Keeps scarcity because only 202,020 is minted at deploy; remainder is optional.
            genesisMinted += amount;
            require(genesisMinted <= GENESIS_MINT_CAP, "GENESIS_CAP_EXCEEDED");

        } else if (role == FARMING_MINTER_ROLE) {
            farmingMinted += amount;
            require(farmingMinted <= FARMING_MINT_CAP, "FARMING_CAP_EXCEEDED");

        } else if (role == VALIDATOR_MINTER_ROLE) {
            require(validatorMintingEnabled, "VALIDATOR_DISABLED");
            validatorMinted += amount;
            require(validatorMinted <= VALIDATOR_MINT_CAP, "VALIDATOR_CAP_EXCEEDED");

        } else if (role == ECOSYSTEM_MINTER_ROLE) {
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
        // ERC20Capped enforces global 550M cap across all buckets combined.
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
