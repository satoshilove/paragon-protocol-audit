// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

interface IEIP1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

contract ParagonBestExecutionV14 is Ownable {
    using ECDSA for bytes32;

    string  public constant NAME    = "ParagonBestExecution";
    string  public constant VERSION = "1";
    bytes32 public immutable DOMAIN_SEPARATOR;

    // keccak256("SwapIntent(address user,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint256 deadline,address recipient,uint256 nonce)")
    bytes32 public constant INTENT_TYPEHASH =
        0x3bd37b889cb869efed4995e979017a10e93e3ec031a3d86332421b98ad625cc6;

    // Accept two legacy variants you supported earlier
    bytes32 private constant INTENT_TYPEHASH_SPACES =
        0x05b39d4bdc6b2679a634346bc60b08b95b4ede11751dfbe20c9c1215858ad589;
    bytes32 private constant INTENT_TYPEHASH_OLD =
        0xb4656a9b09580b84789cc96df0bc0eb4137bdccb4c656425f69526f623210534;

    // EIP-1271 magic value
    bytes4 private constant EIP1271_MAGIC = 0x1626ba7e;

    struct SwapIntent {
        address user;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint256 deadline;
        address recipient;
        uint256 nonce;
    }

    mapping(address => uint256) public nonces;

    event BestExecution(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,   // executor can fill later if needed
        address recipient,
        address executor,
        uint256 nonce
    );
    event IntentCanceled(address indexed user, uint256 nonce);

    constructor(address initialOwner) Ownable(initialOwner) {
        uint256 chainId; assembly { chainId := chainid() }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(NAME)),
                keccak256(bytes(VERSION)),
                chainId,
                address(this)
            )
        );
    }

    // ---------- hashing ----------
    function _structHash(bytes32 typehash, SwapIntent calldata it) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                typehash,
                it.user,
                it.tokenIn,
                it.tokenOut,
                it.amountIn,
                it.minAmountOut,
                it.deadline,
                it.recipient,
                it.nonce
            )
        );
    }

    function _digest(bytes32 typehash, SwapIntent calldata it) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, _structHash(typehash, it)));
    }

    function hashIntent(SwapIntent calldata it) public view returns (bytes32) {
        return _digest(INTENT_TYPEHASH, it);
    }

    // ---------- signature checks ----------
    function _userEIP1271Ok(SwapIntent calldata it, bytes calldata sig) internal view returns (bool) {
        if (it.user.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            it.user.staticcall(abi.encodeWithSelector(IEIP1271.isValidSignature.selector, hashIntent(it), sig));
        return ok && ret.length >= 4 && bytes4(ret) == EIP1271_MAGIC;
    }

    function _recoverEOA(SwapIntent calldata it, bytes calldata sig) internal view returns (address) {
        (address s, ECDSA.RecoverError e,) = ECDSA.tryRecover(_digest(INTENT_TYPEHASH, it), sig);
        if (e == ECDSA.RecoverError.NoError && s != address(0)) return s;
        bytes32 d2 = _digest(INTENT_TYPEHASH_SPACES, it);
        (s, e,) = ECDSA.tryRecover(d2, sig);
        if (e == ECDSA.RecoverError.NoError && s != address(0)) return s;
        bytes32 d3 = _digest(INTENT_TYPEHASH_OLD, it);
        (s, e,) = ECDSA.tryRecover(d3, sig);
        return (e == ECDSA.RecoverError.NoError) ? s : address(0);
    }

    // ---------- API ----------
    function verify(SwapIntent calldata it, bytes calldata sig) public view returns (bool) {
        if (block.timestamp > it.deadline) return false;
        if (it.nonce != nonces[it.user]) return false;
        if (it.user == address(0) || it.tokenIn == address(0) || it.tokenOut == address(0) || it.recipient == address(0)) return false;

        // Contract wallet path (user signs via 1271)
        if (_userEIP1271Ok(it, sig)) return true;

        // EOA path
        address signer = _recoverEOA(it, sig);
        return (signer == it.user);
    }

    function consume(SwapIntent calldata it, bytes calldata sig) external {
        require(block.timestamp <= it.deadline, "intent: expired");
        require(it.nonce == nonces[it.user], "intent: bad nonce");
        require(it.user != address(0) && it.tokenIn != address(0) && it.tokenOut != address(0) && it.recipient != address(0), "intent: zero");

        // Contract wallet OK?
        if (it.user.code.length != 0) {
            (bool ok, bytes memory ret) =
                it.user.staticcall(abi.encodeWithSelector(IEIP1271.isValidSignature.selector, hashIntent(it), sig));
            require(ok && ret.length >= 4 && bytes4(ret) == EIP1271_MAGIC, "intent: 1271");
        } else {
            // EOA
            address signer = _recoverEOA(it, sig);
            require(signer == it.user, "intent: sig");
        }

        unchecked { nonces[it.user] = it.nonce + 1; }
        emit BestExecution(it.user, it.tokenIn, it.tokenOut, it.amountIn, 0, it.recipient, msg.sender, it.nonce);
    }

    function cancel(uint256 expectedNonce) external {
        require(nonces[msg.sender] == expectedNonce, "nonce mismatch");
        unchecked { nonces[msg.sender] = expectedNonce + 1; }
        emit IntentCanceled(msg.sender, expectedNonce);
    }

    function nextNonce(address user) external view returns (uint256) {
        return nonces[user];
    }
}
