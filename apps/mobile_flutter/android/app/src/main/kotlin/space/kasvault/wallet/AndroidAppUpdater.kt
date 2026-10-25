package space.kasvault.wallet

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.SystemClock
import android.provider.Settings
import android.util.Base64
import androidx.core.content.FileProvider
import org.json.JSONObject
import java.io.File
import java.net.URL
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection

/** Downloads APK data only. Never loads code, installs silently or touches wallet storage. */
internal class AndroidAppUpdater(private val context: Context, private val verify: (String, String) -> Boolean) {
    private data class Terms(val version: String, val build: Long, val hash: String, val published: Long)
    private class Job(val token: String, val payload: String, val signature: String, val terms: Terms, val file: File) {
        @Volatile var stage = "downloading"
        @Volatile var received = 0L
        @Volatile var total = 0L
        @Volatile var cancelled = false
        @Volatile var error = ""
        @Volatile var connection: HttpsURLConnection? = null
        val started = SystemClock.elapsedRealtime()
    }
    private val executor = Executors.newSingleThreadExecutor()
    private val directory = File(context.cacheDir, "verified-updates").apply { mkdirs() }
    private val trust = context.getSharedPreferences("android_update_trust_v1", Context.MODE_PRIVATE)
    private var job: Job? = null

    @Synchronized fun start(payload: String, signature: String): Map<String, Any> {
        val terms = terms(payload, signature)
        job?.let {
            if (SystemClock.elapsedRealtime() - it.started >= 15 * 60 * 1000) {
                it.cancelled = true; it.connection?.disconnect(); it.stage = "cancelled"
            }
            if (!it.cancelled && it.stage !in setOf("failed", "cancelled")) {
                check(it.terms == terms) { "An update is already in progress" }
                return status(it.token)
            }
        }
        // Only updater-owned cache files, never user backup files.
        directory.listFiles()?.filter { it.isFile && (it.name.endsWith(".apk") || it.name.endsWith(".part")) }?.forEach { it.delete() }
        val token = UUID.randomUUID().toString()
        val current = Job(token, payload, signature, terms, File(directory, "$token.apk"))
        job = current
        executor.execute {
            val part = File(directory, "$token.part")
            try {
                download(current, part)
                checkActive(current); current.stage = "verifying"
                verifyApk(part, terms(current.payload, current.signature))
                checkActive(current)
                check(part.renameTo(current.file)) { "Could not save verified update" }
                current.stage = "ready"
            } catch (_: Exception) {
                part.delete(); current.file.delete()
                current.error = if (current.cancelled) "Update download cancelled." else
                    "The update could not be downloaded or verified. Retry or use the official website."
                current.stage = if (current.cancelled) "cancelled" else "failed"
            } finally { current.connection?.disconnect(); current.connection = null }
        }
        return status(token)
    }
    @Synchronized fun status(token: String): Map<String, Any> {
        val current = selected(token)
        return mapOf("token" to current.token, "stage" to current.stage, "receivedBytes" to current.received,
            "totalBytes" to current.total, "error" to current.error)
    }
    @Synchronized fun cancel(token: String) {
        val current = selected(token)
        check(current.stage != "installer-opened") { "Android installer already owns this update" }
        current.cancelled = true; current.connection?.disconnect()
        current.stage = "cancelled"; current.file.delete()
    }
    fun install(token: String, done: (String?, Exception?) -> Unit) {
        val current = synchronized(this) {
            selected(token).also {
                check(!it.cancelled && it.stage in setOf("ready", "permission-required", "installer-opened")) { "Update is not ready to install" }
                it.stage = "verifying"
            }
        }
        executor.execute {
            try {
                checkActive(current)
                verifyApk(current.file, terms(current.payload, current.signature))
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    try {
                        checkActive(current)
                        if (!context.packageManager.canRequestPackageInstalls()) {
                            context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            current.stage = "permission-required"
                        } else {
                            val uri = FileProvider.getUriForFile(context, "${context.packageName}.updates", current.file)
                            context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION))
                            current.stage = "installer-opened"
                        }
                        done(current.stage, null)
                    } catch (e: Exception) { current.stage = "ready"; done(null, e) }
                }
            } catch (e: Exception) {
                current.file.delete(); current.stage = "failed"
                android.os.Handler(android.os.Looper.getMainLooper()).post { done(null, e) }
            }
        }
    }
    private fun selected(token: String): Job = job?.takeIf { it.token == token } ?: error("Update session expired. Start the download again.")
    private fun checkActive(current: Job) {
        check(!current.cancelled && SystemClock.elapsedRealtime() - current.started < 15 * 60 * 1000) { "Update cancelled or expired" }
    }
    private fun terms(payload: String, signature: String): Terms {
        require(payload.length <= 24000 && signature.length <= 8192 && verify(payload, signature)) { "Invalid signed update manifest" }
        val data = JSONObject(String(Base64.decode(payload, Base64.NO_WRAP), Charsets.UTF_8))
        val version = data.getString("version"); val build = data.getLong("build")
        val installed = context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode
        AndroidUpdateRules.validate(version, build, data.getLong("minimumBuild"), data.getString("sha256"),
            data.getString("apkUrl"), data.getString("releaseNotesUrl"), installed)
        val published = Instant.parse(data.getString("publishedAt")).toEpochMilli()
        val highest = trust.getLong("build", 0); val previous = trust.getLong("published", 0)
        require(build > highest || build == highest && published >= previous) { "Update manifest moved backwards" }
        check(trust.edit().putLong("build", build).putLong("published", published).commit()) { "Could not preserve update trust" }
        return Terms(version, build, data.getString("sha256"), published)
    }
    private fun download(current: Job, destination: File) {
        val initial = AndroidUpdateRules.githubUrl(current.terms.version)
        var url = initial
        for (redirect in 0..5) {
            checkActive(current)
            require(AndroidUpdateRules.allowedDownload(url, initial)) { "Untrusted update redirect" }
            val connection = URL(url).openConnection() as HttpsURLConnection
            current.connection = connection
            connection.instanceFollowRedirects = false; connection.connectTimeout = 20000; connection.readTimeout = 30000
            connection.setRequestProperty("Accept-Encoding", "identity")
            connection.setRequestProperty("User-Agent", "Kaspire-Android-Updater")
            val status = connection.responseCode
            if (status in setOf(301, 302, 303, 307, 308)) {
                check(redirect < 5) { "Too many update redirects" }
                url = URL(URL(url), connection.getHeaderField("Location") ?: error("Missing redirect")).toString()
                connection.disconnect(); continue
            }
            check(status == 200) { "GitHub download unavailable" }
            val size = connection.contentLengthLong
            check(size == -1L || size in 1..AndroidUpdateRules.MAX_BYTES) { "Invalid update size" }
            current.total = size.coerceAtLeast(0)
            connection.inputStream.use { input -> destination.outputStream().use { output ->
                val bytes = ByteArray(65536)
                while (true) {
                    checkActive(current)
                    val count = input.read(bytes); if (count == -1) break
                    current.received += count
                    check(current.received <= AndroidUpdateRules.MAX_BYTES) { "Update is too large" }
                    output.write(bytes, 0, count)
                }
                output.fd.sync()
            } }
            check(current.received > 0 && (size == -1L || current.received == size)) { "Incomplete update" }
            return
        }
        error("Update download failed")
    }
    private fun verifyApk(file: File, terms: Terms) {
        check(file.length() in 1..AndroidUpdateRules.MAX_BYTES) { "Invalid APK size" }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input -> val bytes = ByteArray(65536); while (true) {
            val count = input.read(bytes); if (count == -1) break; digest.update(bytes, 0, count)
        } }
        fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
        check(hex(digest.digest()) == terms.hash) { "APK checksum differs from signed manifest" }
        val pm = context.packageManager
        val archive = pm.getPackageArchiveInfo(file.path, PackageManager.GET_SIGNING_CERTIFICATES) ?: error("Invalid APK")
        val installed = pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
        check(archive.packageName == context.packageName && archive.longVersionCode == terms.build && archive.versionName == terms.version) { "APK package/version differs from signed release" }
        fun signers(values: Array<android.content.pm.Signature>?) = values.orEmpty().map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }.toSet()
        check(AndroidUpdateRules.compatibleSigner(signers(installed.signingInfo?.apkContentsSigners),
            signers(archive.signingInfo?.apkContentsSigners), signers(archive.signingInfo?.signingCertificateHistory))) { "APK signing identity differs" }
    }
}
