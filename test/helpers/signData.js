const ethers = require("ethers");
const utils = ethers.utils;
const ethUtil = require("ethereumjs-util");

//this, _investor, _fromTime, _toTime, _validTo
function signData(tmAddress, investorAddress, fromTime, toTime, expiryTime, restricted, validFrom, validTo, nonce, pk) {

    let packedData = utils
        .solidityKeccak256(
            ["address", "address", "uint64", "uint64", "uint64", "uint8", "uint64", "uint64", "uint256"],
            [tmAddress, investorAddress, fromTime, toTime, expiryTime, restricted, validFrom, validTo, nonce]
        )
        .slice(2);
    packedData = new Buffer(packedData, "hex");
    packedData = Buffer.concat([new Buffer(`\x19Ethereum Signed Message:\n${packedData.length.toString()}`), packedData]);
    packedData = web3.sha3(`0x${packedData.toString("hex")}`, { encoding: "hex" });
    return ethUtil.ecsign(new Buffer(packedData.slice(2), "hex"), new Buffer(pk, "hex"));
}

// sign data for verify tranfer function
function signDataVerifyTransfer (tmAddress, fromAddress, toAddress, amount, account) {
    let packedData = utils
        .solidityKeccak256(
            ["address", "address", "address", "uint256"],
            [tmAddress, fromAddress, toAddress, amount]
        )
        .slice(2);
    packedData = new Buffer(packedData, "hex");
    packedData = Buffer.concat([new Buffer(`\x19Ethereum Signed Message:\n${packedData.length.toString()}`), packedData]);
    packedData = web3.sha3(`0x${packedData.toString("hex")}`, { encoding: "hex" });

    return web3.eth.sign(account, packedData);
}

module.exports = {
    signData, signDataVerifyTransfer
};
