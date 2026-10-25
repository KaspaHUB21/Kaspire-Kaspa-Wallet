package space.kasvault.wallet

import java.net.URI

/** Public release policy. No arbitrary URL or path from Flutter. */
internal object AndroidUpdateRules {
    const val MAX_BYTES = 256L * 1024 * 1024
    private const val REPO = "https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/"
    fun githubUrl(version: String): String {
        require(Regex("[0-9]+\\.[0-9]+\\.[0-9]+").matches(version)) { "Invalid update version" }
        return "${REPO}download/v$version/Kaspire-Android-mainnet-v$version.apk"
    }
    fun validate(version: String, build: Long, minimum: Long, hash: String, apk: String, notes: String, installed: Long) {
        githubUrl(version)
        require(build > installed && minimum in 1..build) { "Update is not newer than the installed app" }
        require(Regex("[0-9a-f]{64}").matches(hash)) { "Invalid update checksum" }
        require(apk == "https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v$version.apk" &&
            notes == "${REPO}tag/v$version") { "Signed URLs differ from the official release" }
    }
    fun allowedDownload(value: String, initial: String): Boolean = try {
        val uri = URI(value)
        uri.scheme == "https" && uri.rawUserInfo == null && uri.rawFragment == null &&
            (uri.port == -1 || uri.port == 443) &&
            (value == initial || uri.host in setOf("release-assets.githubusercontent.com", "objects.githubusercontent.com"))
    } catch (_: Exception) { false }
    fun compatibleSigner(installed: Set<String>, current: Set<String>, history: Set<String>): Boolean =
        installed.isNotEmpty() && (current == installed ||
            (installed.size == 1 && current.size == 1 && history.containsAll(installed)))
}
