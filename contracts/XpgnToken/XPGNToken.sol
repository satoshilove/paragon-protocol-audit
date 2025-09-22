// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title XPGN Token
/// @notice ERC20 with capped supply, permit, votes, pausable, and role-based mint caps per Option A tokenomics.
/// @dev Transfers are blocked while paused; minting is allowed (for safety/emergency ops).
contract XPGNToken is ERC20Capped, ERC20Permit, ERC20Votes, AccessControlEnumerable, Pausable {
    // --- Admin (DAO multisig) ---
    address public admin;

    // --- Roles ---
    bytes32 public constant FARMING_MINTER_ROLE    = keccak256("FARMING_MINTER_ROLE");    // farms/gauges controller
    bytes32 public constant VALIDATOR_MINTER_ROLE  = keccak256("VALIDATOR_MINTER_ROLE");  // validator reserve distributor
    bytes32 public constant ECOSYSTEM_MINTER_ROLE  = keccak256("ECOSYSTEM_MINTER_ROLE");  // ecosystem grants / partners
    bytes32 public constant TREASURY_MINTER_ROLE   = keccak256("TREASURY_MINTER_ROLE");   // DAO & Treasury ops/audits/MM/buybacks
    bytes32 public constant TEAM_MINTER_ROLE       = keccak256("TEAM_MINTER_ROLE");       // must mint to teamVesting
    bytes32 public constant ADVISOR_MINTER_ROLE    = keccak256("ADVISOR_MINTER_ROLE");    // must mint to advisorVesting

    // --- Bucket Caps (18 decimals) ---
    uint256 public constant FARMING_MINT_CAP       = 150_000_000 ether;     // Liquidity & Gauges (emissions)
    uint256 public constant VALIDATOR_MINT_CAP     = 250_000_000 ether;     // Validator / Chain Reserve (time-locked program)
    uint256 public constant ECOSYSTEM_MINT_CAP     = 40_000_001 ether;      // Ecosystem Grants & Partnerships
    uint256 public constant TREASURY_MINT_CAP      = 33_999_999 ether;      // DAO & Treasury
    uint256 public constant TEAM_MINT_CAP          = 55_000_000 ether;      // Team (must mint to teamVesting)
    uint256 public constant ADVISOR_MINT_CAP       = 11_000_000 ether;      // Advisors (must mint to advisorVesting)
    uint256 public constant GENESIS_MINT_AMOUNT    = 10_000_000 ether;      // Genesis Liquidity & MM (one-time at deploy)

    // --- Ecosystem monthly vesting (streaming) ---
    uint256 public constant ECOSYSTEM_START_TIME     = 1760486400;    // Oct 15, 2025 UTC
    uint256 public constant ECOSYSTEM_VESTING_PERIOD = 30 days;
    uint256 public constant ECOSYSTEM_MONTHLY_LIMIT  = 450_000 ether; // ~0.45M / month

    // --- Mint tracking ---
    uint256 public farmingMinted;
    uint256 public validatorMinted;
    uint256 public ecosystemMinted;
    uint256 public treasuryMinted;
    uint256 public teamMinted;
    uint256 public advisorMinted;

    uint256 public lastEcosystemMintTime;
    bool    public validatorMintingEnabled;

    // --- Enforced recipients for Team/Advisors (vesting contracts) ---
    address public immutable teamVesting;       // must receive TEAM mints
    address public immutable advisorVesting;    // must receive ADVISOR mints

    // --- Events ---
    event Mint(address indexed to, uint256 amount, bytes32 indexed role);
    event ValidatorMintingEnabled(address indexed admin);
    event ValidatorMintingDisabled(address indexed admin);
    event AdminUpdated(address indexed newAdmin);

    /// @param daoMultisig        DAO multisig (admin)
    /// @param masterChef         farms/gauges controller (farming minter)
    /// @param validatorRewards   validator distributor (validator minter)
    /// @param _teamVesting       team vesting contract (enforced recipient)
    /// @param _advisorVesting    advisor vesting contract (enforced recipient)
    /// @param genesisRecipient   recipient of 10M genesis liquidity
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
        require(daoMultisig != address(0), "INVALID_DAO_MULTISIG");
        require(masterChef != address(0), "INVALID_MASTERCHEF");
        require(validatorRewards != address(0), "INVALID_VALIDATOR_REWARDS");
        require(_teamVesting != address(0), "INVALID_TEAM_VESTING");
        require(_advisorVesting != address(0), "INVALID_ADVISOR_VESTING");
        require(genesisRecipient != address(0), "INVALID_GENESIS_RECIPIENT");

        admin = daoMultisig;
        _grantRole(DEFAULT_ADMIN_ROLE, daoMultisig);

        // Assign minters per bucket
        _grantRole(FARMING_MINTER_ROLE,   masterChef);
        _grantRole(VALIDATOR_MINTER_ROLE, validatorRewards);
        _grantRole(ECOSYSTEM_MINTER_ROLE, daoMultisig); // DAO streams partners/grants
        _grantRole(TREASURY_MINTER_ROLE,  daoMultisig); // DAO-controlled treasury operations
        _grantRole(TEAM_MINTER_ROLE,      daoMultisig); // DAO triggers vesting mints to teamVesting
        _grantRole(ADVISOR_MINTER_ROLE,   daoMultisig); // DAO triggers vesting mints to advisorVesting

        teamVesting    = _teamVesting;
        advisorVesting = _advisorVesting;

        // Initial mint: 10M to genesis liquidity / MM (not to DAO treasury)
        _mint(genesisRecipient, GENESIS_MINT_AMOUNT);
        emit Mint(genesisRecipient, GENESIS_MINT_AMOUNT, bytes32("GENESIS"));

        lastEcosystemMintTime = ECOSYSTEM_START_TIME;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------
    function getAdmin() external view returns (address) { return admin; }

    /// @notice Optional: rotate DAO multisig (DEFAULT_ADMIN_ROLE should be managed separately if needed).
    function setAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAdmin != address(0), "INVALID_ADMIN");
        admin = newAdmin;
        emit AdminUpdated(newAdmin);
    }

    function enableValidatorMinting() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!validatorMintingEnabled, "VALIDATOR_MINTING_ALREADY_ENABLED");
        validatorMintingEnabled = true;
        emit ValidatorMintingEnabled(msg.sender);
    }

    function disableValidatorMinting() external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(validatorMintingEnabled, "VALIDATOR_MINTING_ALREADY_DISABLED");
        validatorMintingEnabled = false;
        emit ValidatorMintingDisabled(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Minting (by bucket)
    // -------------------------------------------------------------------------
    /// @notice Unified mint function governed by role and per-bucket caps.
    /// @dev Team/Advisor mints must target their vesting contracts (enforced).
    function mint(address to, uint256 amount, bytes32 role) external {
        require(
            role == FARMING_MINTER_ROLE ||
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
            // Monthly streaming with start time & cap
            require(block.timestamp >= ECOSYSTEM_START_TIME, "ECOSYSTEM_NOT_STARTED");
            // Enforce one mint per ~30 days max allowance
            require(block.timestamp >= lastEcosystemMintTime, "ECOSYSTEM_COOLDOWN");
            require(amount <= ECOSYSTEM_MONTHLY_LIMIT, "ECOSYSTEM_MONTHLY_LIMIT");
            ecosystemMinted += amount;
            require(ecosystemMinted <= ECOSYSTEM_MINT_CAP, "ECOSYSTEM_CAP_EXCEEDED");
            lastEcosystemMintTime = block.timestamp + ECOSYSTEM_VESTING_PERIOD;

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
    }

    // -------------------------------------------------------------------------
    // Pause controls
    // -------------------------------------------------------------------------
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    // -------------------------------------------------------------------------
    // Internal hooks & overrides
    // -------------------------------------------------------------------------
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Capped, ERC20Votes)
    {
        // Block transfers while paused (minting/burning still allowed)
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
