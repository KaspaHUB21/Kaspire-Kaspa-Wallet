package space.kasvault.wallet

import org.junit.Assert.*
import org.junit.Test

class AndroidUpdateRulesTest {
    private val version = "0.11.69"
    private val initial = AndroidUpdateRules.githubUrl(version)
    @Test fun exactVersionAndTrustedRedirectsOnly() {
        assertEquals("https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/download/v0.11.69/Kaspire-Android-mainnet-v0.11.69.apk", initial)
        for (value in listOf(initial, "https://release-assets.githubusercontent.com/asset?signature=public-download", "https://objects.githubusercontent.com/asset")) {
            assertTrue(value, AndroidUpdateRules.allowedDownload(value, initial))
        }
        for (value in listOf("http://release-assets.githubusercontent.com/asset", "https://release-assets.githubusercontent.com.evil.example/asset",
            "https://user@release-assets.githubusercontent.com/asset", "https://release-assets.githubusercontent.com:444/asset",
            "https://github.com/other/repo/releases/download/latest/app.apk", "file:///tmp/update.apk", "$initial?override=1", "$initial#fragment")) {
            assertFalse(value, AndroidUpdateRules.allowedDownload(value, initial))
        }
        for (value in listOf("../evil", "0.11.69?evil", "v0.11.69", "0.11.69/extra")) {
            assertThrows(IllegalArgumentException::class.java) { AndroidUpdateRules.githubUrl(value) }
        }
    }
    @Test fun bindsPackageReleaseToSignedVersionAndForbidsDowngrades() {
        val apk = "https://kaspire.kaslab.space/downloads/Kaspire-Android-mainnet-v$version.apk"
        val notes = "https://github.com/KaspaHUB21/Kaspire-Kaspa-Wallet/releases/tag/v$version"
        AndroidUpdateRules.validate(version, 212, 1, "a".repeat(64), apk, notes, 211)
        for (build in listOf(210L, 211L)) assertThrows(IllegalArgumentException::class.java) {
            AndroidUpdateRules.validate(version, build, 1, "a".repeat(64), apk, notes, 211)
        }
        assertThrows(IllegalArgumentException::class.java) { AndroidUpdateRules.validate(version, 212, 213, "a".repeat(64), apk, notes, 211) }
        assertThrows(IllegalArgumentException::class.java) { AndroidUpdateRules.validate(version, 212, 1, "a".repeat(63), apk, notes, 211) }
        assertThrows(IllegalArgumentException::class.java) { AndroidUpdateRules.validate(version, 212, 1, "a".repeat(64), "$apk?extra=1", notes, 211) }
    }
    @Test fun preservesSigningContinuityWithoutTrustingAnUnrelatedKey() {
        assertTrue(AndroidUpdateRules.compatibleSigner(setOf("current"), setOf("current"), setOf("old", "current")))
        assertTrue(AndroidUpdateRules.compatibleSigner(setOf("current"), setOf("next"), setOf("current", "next")))
        assertFalse(AndroidUpdateRules.compatibleSigner(setOf("current"), setOf("attacker"), setOf("attacker")))
        assertFalse(AndroidUpdateRules.compatibleSigner(emptySet(), emptySet(), emptySet()))
        assertFalse(AndroidUpdateRules.compatibleSigner(setOf("one", "two"), setOf("one"), setOf("one", "two")))
    }
}
