package space.kasvault.wallet

object SecureCore {
    init { System.loadLibrary("kaspa_secure_core") }

    external fun generateWallet(passphrase: String): String
    external fun deriveDotkDeed(requestJson: String): String
    external fun describeDotkMarket(requestJson: String): String
    external fun prepareNftMarket(requestJson: String): String
    external fun prepareDotkMarket(requestJson: String): String
    external fun signDotkMarket(secret: ByteArray, requestJson: String, reviewHash: String): String
    external fun importWallet(phrase: String, passphrase: String): String
    external fun importPrivateKey(privateKey: String): String
    external fun addressWithPrefix(address: String, testnet: Boolean): String
    external fun exportPrivateKey(secret: ByteArray): String
    external fun publicKey(secret: ByteArray): String
    external fun deriveAddresses(secret: ByteArray, coinType: Int, account: Int, change: Int, start: Int, count: Int): String
    external fun deriveEvmAddress(secret: ByteArray): String
    external fun exportEvmPrivateKey(secret: ByteArray): String
    external fun prepareEvmTransaction(requestJson: String): String
    external fun signEvmTransaction(secret: ByteArray, requestJson: String, reviewHash: String): String
    external fun deriveBackupKeyBytes(password: ByteArray, salt: ByteArray, version: Int): ByteArray
    external fun prepareTransaction(requestJson: String): String
    external fun signTransaction(phrase: ByteArray, requestJson: String, reviewHash: String): String
    external fun prepareWyrmGenesis(requestJson: String): String
    external fun signWyrmGenesis(secret: ByteArray, requestJson: String, reviewHash: String): String
    external fun prepareWyrmTransition(requestJson: String): String
    external fun signWyrmTransition(secret: ByteArray, requestJson: String, reviewHash: String): String
    external fun prepareKcc20Transfer(requestJson: String): String
    external fun prepareKronTransfer(requestJson: String): String
    external fun signKcc20Transfer(secret: ByteArray, requestJson: String, reviewHash: String): String
    external fun signPersonalMessage(secret: ByteArray, address: String, message: String): String
    external fun prepareInscription(requestJson: String): String
    external fun prepareReveal(requestJson: String): String
    external fun signReveal(phrase: ByteArray, requestJson: String, reviewHash: String): String
    external fun preparePolicyTransaction(requestJson: String): String
    external fun signPolicyTransaction(secret: ByteArray, requestJson: String, reviewHash: String): String
    external fun preparePskt(requestJson: String): String
    external fun signPskt(secret: ByteArray, requestJson: String, reviewHash: String): String
    external fun tangemAddress(publicKeyHex: String): String
    external fun prepareTangemCommit(requestJson: String): String
    external fun finalizeTangemCommit(requestJson: String, reviewHash: String, signaturesJson: String): String
    external fun prepareTangemReveal(requestJson: String): String
    external fun finalizeTangemReveal(requestJson: String, reviewHash: String, signaturesJson: String): String
}
