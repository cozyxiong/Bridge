// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCall} from "../libraries/SafeCall.sol";
import {Address} from "../../lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {ContractsAddress} from "../libraries/ContractsAddress.sol";

contract BridgeEvent {
    event TokenReceived(uint256 souceChainId, uint256 destChainId, address to, address token, uint256 amount);
    event TokenAllocated(uint256 souceChainId, uint256 destChainId, address to, address token, uint256 amount);
    event BridgeReceivedMessageDone(address from, address to, uint256 amount, uint256 nonce, bytes32 hash);
    event BridgeAllocatedMessageDone(address targetContract, address from, address to, uint256 amount, uint256 gasLimit, uint256 nonce, bytes32 hash);
    event BridgeBaseConfigChanged(bytes4 setterSelector, string setterSignature, bytes value);
}

contract BridgeBase is Initializable, ReentrancyGuardUpgradeable, BridgeEvent {

    error NotRelayer();
    error InvalidAmount();
    error InvalidChainId();
    error InvalidSourceChainId();
    error InvalidDestChainId();
    error InvalidToken();
    error LessThanMinTransferAmount();
    error FundNotSufficient();
    error BridgeReceivedMessageFailed();
    error BridgeAllocatedMessageFailed();

    uint256 public constant FEE_DENOMINATOR = 1000;

    uint256 public minTransferAmount;
    uint256 public feeRate;
    uint256 public messageNonce;
    mapping(uint256 => bool) public chainIdWhitelist;
    mapping(IERC20 => bool) public tokenWhitelist;
    mapping(uint256 => mapping(IERC20 => uint256)) public fundingPool;
    mapping(uint256 => uint256) public feeChainPool;

    using SafeERC20 for IERC20;
    address public relayer;

    struct Init {
        address multisigWallet;
    }

    modifier onlyRelayer() {
        if (msg.sender != relayer) { revert NotRelayer(); }
        _;
    }

    function init(Init memory init) internal {
        relayer = init.multisigWallet;

        minTransferAmount = 0.1 ether;
        feeRate = 1;
    }

    function receiveETH(uint256 sourceChainId, uint256 destChainId, address to) external payable returns (bool) {
        if (sourceChainId != block.chainid) { revert InvalidSourceChainId(); }
        if (!chainIdWhitelist[destChainId]) { revert InvalidDestChainId(); }
        if (msg.value < minTransferAmount) { revert LessThanMinTransferAmount(); }

        uint256 fee = (msg.value * feeRate) / FEE_DENOMINATOR;
        fundingPool[block.chainid][ContractsAddress.ETHAddress()] += msg.value;
        feeChainPool[block.chainid] += fee;

        emit TokenReceived(sourceChainId, destChainId, to, ContractsAddress.ETHAddress(), msg.value);
        return true;
    }

    function receiveToken(uint256 sourceChainId, uint256 destChainId, address to, IERC20 token, uint256 amount) external returns (bool) {
        if (sourceChainId != block.chainid) { revert InvalidSourceChainId(); }
        if (!chainIdWhitelist[destChainId]) { revert InvalidDestChainId(); }
        if (!tokenWhitelist[token]) { revert InvalidToken(); }
        if (amount < minTransferAmount) { revert LessThanMinTransferAmount(); }

        token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 fee = (amount * feeRate) / FEE_DENOMINATOR;
        fundingPool[block.chainid][token] += amount;
        feeChainPool[block.chainid] += fee;

        emit TokenReceived(sourceChainId, destChainId, to, address(token), amount);
        return true;
    }

    function bridgeReceivedMessage(address from, address to, uint256 amount) external onlyRelayer returns (bool) {
        bytes32 messageHash = keccak256(abi.encode(from, to, amount, messageNonce));
        messageNonce++;
        emit BridgeReceivedMessageDone(from, to, amount, messageNonce, messageHash);
        return true;
    }

    function allocateETH(uint256 sourceChainId, uint256 destChainId, address to, uint256 amount) external onlyRelayer returns (bool) {
        if (destChainId != block.chainid) { revert InvalidDestChainId(); }
        if (!chainIdWhitelist[sourceChainId]) { revert InvalidSourceChainId(); }
        if (amount < minTransferAmount) { revert LessThanMinTransferAmount(); }

        if (address(this).balance < amount) { revert FundNotSufficient(); }
        Address.sendValue(to, amount);

        fundingPool[block.chainid][ContractsAddress.ETHAddress()] -= amount;

        emit TokenAllocated(sourceChainId, destChainId, to, ContractsAddress.ETHAddress(), amount);
        return true;
    }

    function allocateToken(uint256 sourceChainId, uint256 destChainId, address to, IERC20 token, uint256 amount) external onlyRelayer returns (bool) {
        if (destChainId != block.chainid) { revert InvalidDestChainId(); }
        if (!chainIdWhitelist[sourceChainId]) { revert InvalidSourceChainId(); }
        if (!tokenWhitelist[token]) { revert InvalidToken(); }
        if (amount < minTransferAmount) { revert LessThanMinTransferAmount(); }

        if (token.balanceOf(address(this)) < amount) { revert FundNotSufficient(); }
        token.safeTransfer(to, amount);

        fundingPool[block.chainid][token] -= amount;

        emit TokenAllocated(sourceChainId, destChainId, to, address(token), amount);
        return true;
    }

    function bridgeAllocatedMessage(address targetContract, address from, address to, uint256 amount, uint256 gasLimit) external onlyRelayer returns (bool) {
        bytes32 messageHash = keccak256(abi.encode(from, to, amount, gasLimit, messageNonce));
        bool success = SafeCall.callWithMinGas(
            targetContract,
            gasLimit,
            amount,
            abi.encodeWithSignature(
                "receivedFromBridge(address,address,amount)",
                from,
                to,
                amount
            )
        );
        if (!success) { revert BridgeAllocatedMessageFailed(); }
        messageNonce++;
        emit BridgeAllocatedMessageDone(targetContract, from, to, amount, gasLimit, messageNonce, messageHash);
        return true;
    }

    function sendTokenToUser(IERC20 token, address to, uint256 amount) external onlyRelayer returns (bool) {
        if (!tokenWhitelist[token]) { revert InvalidToken(); }
        if (fundingPool[token] < amount) { revert FundNotSufficient(); }
        fundingPool[token] -= amount;

        if (token == ContractsAddress.ETHAddress()) {
            if (address(this).balance < amount) { revert FundNotSufficient(); }
            Address.sendValue(to, amount);
        } else {
            if (token.balanceOf(address(this)) < amount) { revert FundNotSufficient(); }
            token.safeTransfer(to, amount);
        }
        return true;
    }

    function setChainIdWhitelist(uint256 chainId, bool isValid) external onlyRelayer {
        chainIdWhitelist[chainId] = isValid;
        emit BridgeBaseConfigChanged(this.setChainIdWhitelist.selector, "setChainWhitelist(uint256,bool)", abi.encode(chainId, isValid));
    }

    function setTokenWhitelist(address token, bool isValid) external onlyRelayer {
        tokenWhitelist[IERC20(token)] = isValid;
        emit BridgeBaseConfigChanged(this.setTokenWhitelist.selector, "setTokenWhitelist(address,bool)", abi.encode(token, isValid));
    }

    function setMinTransferAmount(uint256 _minTransferAmount) external onlyRelayer {
        minTransferAmount = _minTransferAmount;
        emit BridgeBaseConfigChanged(this.minTransferAmount.selector, "setMinTransferAmount(uint256)", abi.encode(minTransferAmount));
    }

    function setFeeRate(uint256 _feeRate) external onlyRelayer {
        feeRate = _feeRate;
        emit BridgeBaseConfigChanged(this.setFeeRate.selector, "setFeeRate(uint256)", abi.encode(feeRate));
    }
}
