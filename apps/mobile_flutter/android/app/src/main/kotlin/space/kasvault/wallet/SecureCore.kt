package space.kasvault.wallet

object SecureCore {
    init { System.loadLibrary("kaspa_secure_core") }

    external fun generateWallet(passphrase: String): String
    external fun importWallet(phrase: String, passphrase: String): String
    external fun importPrivateKey(privateKey: String): String
    external fun exportPrivateKey(secret: String): String
    external fun deriveAddresses(secret: String, coinType: Int, account: Int, change: Int, start: Int, count: Int): String
    external fun deriveBackupKey(password: String, saltHex: String): String
    external fun prepareTransaction(requestJson: String): String
    external fun signTransaction(phrase: String, requestJson: String, reviewHash: String): String
    external fun prepareKcc20Transfer(requestJson: String): String
    external fun prepareKronTransfer(requestJson: String): String
    external fun signKcc20Transfer(secret: String, requestJson: String, reviewHash: String): String
    external fun signPersonalMessage(secret: String, address: String, message: String): String
    external fun prepareInscription(requestJson: String): String
    external fun prepareReveal(requestJson: String): String
    external fun signReveal(phrase: String, requestJson: String, reviewHash: String): String
    external fun preparePolicyTransaction(requestJson: String): String
    external fun signPolicyTransaction(secret: String, requestJson: String, reviewHash: String): String
    external fun preparePskt(requestJson: String): String
    external fun signPskt(secret: String, requestJson: String, reviewHash: String): String
}
