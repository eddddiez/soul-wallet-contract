// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "@source/SoulWalletFactory.sol";
import "@source/SoulWallet.sol";
import "@source/keystore/L1/KeyStore.sol";
import "@account-abstraction/contracts/core/EntryPoint.sol";
import "./DeployHelper.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@source/modules/keystore/KeyStoreModule.sol";
import "@source/modules/keystore/OptimismKeyStoreProofModule/OpKnownStateRootWithHistory.sol";
import "@source/modules/keystore/KeystoreProof.sol";
import {NetWorkLib} from "./DeployHelper.sol";
import "@account-abstraction/contracts/interfaces/UserOperation.sol";

contract CreateWalletEntryPointPaymaster is Script {
    using ECDSA for bytes32;

    uint256 guardianThreshold = 1;
    uint64 initialGuardianSafePeriod = 2 days;

    address walletSigner;
    uint256 walletSingerPrivateKey;

    address newWalletSigner;
    uint256 newWalletSingerPrivateKey;

    address guardianAddress;
    uint256 guardianPrivateKey;

    address securityControlModuleAddress;

    address keystoreModuleAddress;

    address defaultCallbackHandler;

    SoulWalletFactory soulwalletFactory;

    address payable soulwalletAddress;
    KeyStore keystoreContract;

    OpKnownStateRootWithHistory opKnownStateRootWithHistory;

    KeystoreProof keystoreProofContract;
    bytes emptyBytes;
    EntryPoint public entrypoint = EntryPoint(payable(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789));

    function run() public {
        // wallet signer info
        walletSingerPrivateKey = vm.envUint("WALLET_SIGNGER_NEW_PRIVATE_KEY");
        walletSigner = vm.addr(walletSingerPrivateKey);

        // guardian info
        guardianPrivateKey = vm.envUint("GUARDIAN_PRIVATE_KEY");
        guardianAddress = vm.addr(guardianPrivateKey);

        createWallet();
    }

    function createWallet() private {
        bytes32 salt = bytes32(uint256(4));
        bytes[] memory modules = new bytes[](2);
        // security control module setup
        securityControlModuleAddress = loadEnvContract("SECURITY_CONTROL_MODULE_ADDRESS");
        modules[0] = abi.encodePacked(securityControlModuleAddress, abi.encode(uint64(2 days)));
        // keystore module setup
        keystoreModuleAddress = loadEnvContract("KEYSTORE_MODULE_ADDRESS");
        address[] memory guardians = new address[](1);
        guardians[0] = guardianAddress;
        bytes memory rawGuardian = abi.encode(guardians, guardianThreshold, 0);
        bytes32 initialGuardianHash = keccak256(rawGuardian);

        bytes memory keystoreModuleInitData =
            abi.encode(bytes32(uint256(uint160(walletSigner))), initialGuardianHash, initialGuardianSafePeriod);
        modules[1] = abi.encodePacked(keystoreModuleAddress, keystoreModuleInitData);

        bytes[] memory plugins = new bytes[](0);

        defaultCallbackHandler = loadEnvContract("DEFAULT_CALLBACK_HANDLER_ADDRESS");
        bytes memory initializer = abi.encodeWithSignature(
            "initialize(address,address,bytes[],bytes[])", walletSigner, defaultCallbackHandler, modules, plugins
        );
        soulwalletFactory = SoulWalletFactory(loadEnvContract("SOULWALLET_FACTORY_ADDRESS"));
        address cacluatedAddress = soulwalletFactory.getWalletAddress(initializer, salt);

        bytes memory soulWalletFactoryCall = abi.encodeWithSignature("createWallet(bytes,bytes32)", initializer, salt);
        bytes memory initCode = abi.encodePacked(address(soulwalletFactory), soulWalletFactoryCall);
        console.log("cacluatedAddress", cacluatedAddress);

        address[] memory tokenAddressList = new address[](1);

        address payToken = loadEnvContract("PAYTOKEN_ADDRESS");
        address paymaster = loadEnvContract("PAYMASTER_ADDRESS");

        tokenAddressList[0] = address(payToken);

        bytes[] memory tokenCallData = new bytes[](1);
        tokenCallData[0] = abi.encodeWithSignature("approve(address,uint256)", address(paymaster), 1000e6);
        bytes memory callData =
            abi.encodeWithSignature("executeBatch(address[],bytes[])", tokenAddressList, tokenCallData);
        bytes memory paymasterAndData =
            abi.encodePacked(abi.encodePacked(address(paymaster)), abi.encode(address(payToken), uint256(1000e6)));

        UserOperation[] memory ops = new UserOperation[](1);

        UserOperation memory userOperation = UserOperation({
            sender: cacluatedAddress,
            nonce: 0,
            initCode: initCode,
            callData: callData,
            callGasLimit: 5000000,
            verificationGasLimit: 1000000,
            preVerificationGas: 500000,
            maxFeePerGas: 10 gwei,
            maxPriorityFeePerGas: 10 gwei,
            paymasterAndData: paymasterAndData,
            signature: hex""
        });
        userOperation.signature = signUserOp(userOperation, walletSigner, walletSingerPrivateKey);

        ops[0] = userOperation;

        uint256 bundlerSinger = vm.envUint("WALLET_SIGNGER_PRIVATE_KEY");
        console.log("bundelr address ", vm.addr(bundlerSinger));
        vm.startBroadcast(bundlerSinger);
        logUserOp(userOperation);
        console.log("entrypoint", address(entrypoint));
        console.log("beneficiary ", vm.addr(bundlerSinger));
        entrypoint.handleOps(ops, payable(vm.addr(bundlerSinger)));
    }

    function logUserOp(UserOperation memory op) private view {
        console.log("sender: ", op.sender);
        console.log("nonce: ", op.nonce);
        console.log("initCode: ");
        console.logBytes(op.initCode);
        console.log("callData: ");
        console.logBytes(op.callData);
        console.log("callGasLimit: ");
        console.log(op.callGasLimit);
        console.log("verificationGasLimit: ");
        console.log(op.verificationGasLimit);
        console.log("preVerificationGas: ");
        console.log(op.preVerificationGas);
        console.log("maxFeePerGas: ");
        console.log(op.maxFeePerGas);
        console.log("maxPriorityFeePerGas: ");
        console.log(op.maxPriorityFeePerGas);
        console.log("paymasterAndData: ");
        console.logBytes(op.paymasterAndData);
        console.log("signature: ");
        console.logBytes(op.signature);
    }

    function signUserOp(UserOperation memory op, address addr, uint256 key)
        public
        view
        returns (bytes memory signature)
    {
        bytes32 hash = entrypoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash.toEthSignedMessageHash());
        require(addr == ECDSA.recover(hash.toEthSignedMessageHash(), v, r, s));
        signature = abi.encodePacked(r, s, v);
        require(addr == ECDSA.recover(hash.toEthSignedMessageHash(), signature));
    }

    function loadEnvContract(string memory label) private view returns (address) {
        address contractAddress = vm.envAddress(label);
        require(contractAddress != address(0), string(abi.encodePacked(label, " not provided")));
        require(contractAddress.code.length > 0, string(abi.encodePacked(label, " needs be deployed")));
        return contractAddress;
    }
}
