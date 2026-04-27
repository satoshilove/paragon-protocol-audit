// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

abstract contract SignedUsageAdapterBase is Ownable, Pausable, ReentrancyGuard {
    using ECDSA for bytes32;

    uint256 public constant WEEK = 7 days;

    struct UsageClaim {
        address user;
        uint256 usdValue1e18;
        bytes32 ref;
        uint256 epoch;
        uint256 deadline;
    }

    bytes32 public immutable DOMAIN_SEPARATOR;

    bytes32 public constant USAGE_CLAIM_TYPEHASH =
        keccak256("UsageClaim(address user,uint256 usdValue1e18,bytes32 ref,uint256 epoch,uint256 deadline)");

    mapping(address => bool) public authorizedSigner;
    mapping(bytes32 => bool) public usedDigest;

    event SignerSet(address indexed signer, bool allowed);
    event ClaimConsumed(
        bytes32 indexed digest,
        address indexed user,
        bytes32 indexed ref,
        uint256 usdValue1e18,
        uint256 epoch
    );
    event EmergencyPause(address indexed owner);
    event EmergencyUnpause(address indexed owner);

    constructor(address initialOwner) Ownable(initialOwner) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(_domainName())),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    function _domainName() internal view virtual returns (string memory);

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    function setSigner(address signer, bool allowed) external onlyOwner {
        require(signer != address(0), "signer=0");
        authorizedSigner[signer] = allowed;
        emit SignerSet(signer, allowed);
    }

    function pause() external onlyOwner {
        _pause();
        emit EmergencyPause(msg.sender);
    }

    function unpause() external onlyOwner {
        _unpause();
        emit EmergencyUnpause(msg.sender);
    }

    function hashClaim(UsageClaim calldata c) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                USAGE_CLAIM_TYPEHASH,
                c.user,
                c.usdValue1e18,
                c.ref,
                c.epoch,
                c.deadline
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _verifyAndConsume(UsageClaim calldata c, bytes calldata signature)
        internal
        returns (bytes32 digest)
    {
        require(c.user != address(0), "user=0");
        require(c.usdValue1e18 > 0, "value=0");
        require(c.deadline >= block.timestamp, "expired");
        require(c.epoch == currentEpoch(), "wrong epoch");

        digest = hashClaim(c);
        require(!usedDigest[digest], "claim used");

        address signer = ECDSA.recover(digest, signature);
        require(authorizedSigner[signer], "bad signer");

        usedDigest[digest] = true;

        emit ClaimConsumed(digest, c.user, c.ref, c.usdValue1e18, c.epoch);
    }
}
