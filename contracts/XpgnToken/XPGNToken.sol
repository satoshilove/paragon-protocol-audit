// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title XPGN Token — Final Audit-Ready Version (Full Bucket Tokenomics)
/// @notice ERC20 with capped supply, permit, votes, pausable, and role-based bucket mint caps.
contract XPGNToken is ERC20Capped, ERC20Permit, ERC20Votes, AccessControlEnumerable, Pausable {
    // -----------------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------------
    /// @notice DAO multisig / core admin address (separate from DEFAULT_ADMIN_ROLE if you ever rotate)
    address public admin;

    // -----------------------------------------------------------------------
    // Roles
    // -----------------------------------------------------------------------
    bytes32 public constant FARMING_MINTER_ROLE    = keccak256("FARMING_MINTER_ROLE");    // farms / gauges (MasterChef)
    bytes32 public constant VALIDATOR_MINTER_ROLE  = keccak256("VALIDATOR_MINTER_ROLE");  // validator / chain reserve distributor
    bytes32 public constant ECOSYSTEM_MINTER_ROLE  = keccak256("ECOSYSTEM_MINTER_ROLE");  // ecosystem / partners / grants
    bytes32 public constant TREASURY_MINTER_ROLE   = keccak256("TREASURY_MINTER_ROLE");   // DAO & Treasury ops
    bytes32 public constant TEAM_MINTER_ROLE       = keccak256("TEAM_MINTER_ROLE");       // only to teamVesting
    bytes32 public constant ADVISOR_MINTER_ROLE    = keccak256("ADVISOR_MINTER_ROLE");    // only to advisorVesting

    // -----------------------------------------------------------------------
    // Bucket Caps (all 18 decimals)
    // -----------------------------------------------------------------------
    uint256 public constant FARMING_MINT_CAP       = 150_000_000 ether;  // Liquidity & Gauges (emissions)
    uint256 public constant VALIDATOR_MINT_CAP     = 250_000_000 ether;  // Validator / Chain Reserve
    uint256 public constant ECOSYSTEM_MINT_CAP     = 40_000_001 ether;   // Ecosystem Grants & Partnerships
    uint256 public constant TREASURY_MINT_CAP      = 33_999_999 ether;   // DAO & Treasury
    uint256 public constant TEAM_MINT_CAP          = 55_000_000 ether;   // Team (must mint to teamVesting)
    uint256 public constant ADVISOR_MINT_CAP       = 11_000_000 ether;   // Advisors (must mint to advisorVesting)
    uint256 public constant GENESIS_MINT_AMOUNT    = 10_000_000 ether;   // Genesis Liquidity & MM (one-time at deploy)

    // NOTE: sum(buckets without GENESIS) = 540M, + 10M GENESIS = 550M cap

    // -----------------------------------------------------------------------
    // Ecosystem streaming config (monthly)
    // -----------------------------------------------------------------------
    uint256 public constant ECOSYSTEM_START_TIME     = 1769852348; // Jan 31, 2026 UTC
    uint256 public constant ECOSYSTEM_VESTING_PERIOD = 30 days;
    uint256 public constant ECOSYSTEM_MONTHLY_LIMIT  = 450_000 ether;

    // -----------------------------------------------------------------------
    // Mint tracking
    // -----------------------------------------------------------------------
    uint256 public farmingMinted;
    uint256 public validatorMinted;
    uint256 public ecosystemMinted;
    uint256 public treasuryMinted;
    uint256 public teamMinted;
    uint256 public advisorMinted;

    uint256 public lastEcosystemMintTime;
    bool    public validatorMintingEnabled;

    // -----------------------------------------------------------------------
    // Enforced recipients (vesting)
    // -----------------------------------------------------------------------
    address public immutable teamVesting;       // all TEAM mints must go here
    address public immutable advisorVesting;    // all ADVISOR mints must go here

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
    /// @param daoMultisig      DAO multisig / admin
    /// @param masterChef       farming controller (ParagonFarmController)
    /// @param validatorRewards validator reserve distributor
    /// @param _teamVesting     team vesting contract (enforced recipient)
    /// @param _advisorVesting  advisor vesting contract (enforced recipient)
    /// @param genesisRecipient recipient of 10M genesis liquidity (DEX / MM)
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
        _grantRole(FARMING_MINTER_ROLE,   masterChef);
        _grantRole(VALIDATOR_MINTER_ROLE, validatorRewards);
        _grantRole(ECOSYSTEM_MINTER_ROLE, daoMultisig);
        _grantRole(TREASURY_MINTER_ROLE,  daoMultisig);
        _grantRole(TEAM_MINTER_ROLE,      daoMultisig);
        _grantRole(ADVISOR_MINTER_ROLE,   daoMultisig);

        teamVesting    = _teamVesting;
        advisorVesting = _advisorVesting;

        // One-time Genesis Mint (10M) for initial DEX liquidity / MM
        _mint(genesisRecipient, GENESIS_MINT_AMOUNT);
        emit Mint(genesisRecipient, GENESIS_MINT_AMOUNT, bytes32("GENESIS"));

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
    function mint(address to, uint256 amount, bytes32 role) external {
        require(
            role == FARMING_MINTER_ROLE   ||
            role == VALIDATOR_MINTER_ROLE ||
            role == ECOSYSTEM_MINTER_ROLE ||
            role == TREASURY_MINTER_ROLE  ||
            role == TEAM_MINTER_ROLE      ||
            role == ADVISOR_MINTER_ROLE,
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

        } else {
            // ADVISOR_MINTER_ROLE
            require(to == advisorVesting, "ADVISOR_TO_MUST_BE_VESTING");
            advisorMinted += amount;
            require(advisorMinted <= ADVISOR_MINT_CAP, "ADVISOR_CAP_EXCEEDED");
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
