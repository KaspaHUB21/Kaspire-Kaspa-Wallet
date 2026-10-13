package space.kasvault.wallet

import android.content.SharedPreferences
import android.util.Base64
import javax.crypto.Cipher
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONArray
import org.json.JSONObject

/** Native-owned, additive exposure/issuance journal. Never register these keys
 * as ordinary wallet addresses; no message, asset, xpub or dApp signing route. */
internal class HiddenKasStore(
    private val prefs: () -> SharedPreferences,
    private val walletId: () -> String,
    private val key: () -> SecretKey,
    private val withSecret: (((ByteArray) -> String) -> String),
) {
    companion object { const val descriptor = "kaspire-hidden-kas-v1" }
    private fun storage(id: String) = "wallet.$id.hidden_kas"
    private fun parse(raw: String): JSONObject = JSONObject(raw).also {
        check(!it.has("error")) { it.optString("error", "Native hidden KAS validation failed") }
    }
    @Synchronized fun load(): JSONObject {
        val id = walletId()
        val raw = prefs().getString(storage(id), null) ?: return JSONObject()
            .put("descriptor", descriptor).put("receiveCount", 0).put("changeCount", 0).put("exposed", JSONArray())
        val box = JSONObject(raw)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, Base64.decode(box.getString("iv"), Base64.NO_WRAP)))
        cipher.updateAAD("$descriptor:$id".toByteArray(Charsets.UTF_8))
        val plain = cipher.doFinal(Base64.decode(box.getString("ciphertext"), Base64.NO_WRAP))
        return try { JSONObject(plain.toString(Charsets.UTF_8)).also { validate(it) } } finally { plain.fill(0) }
    }
    fun validate(state: JSONObject) {
        check(state.getString("descriptor") == descriptor) { "Unsupported hidden KAS descriptor" }
        for (name in listOf("receiveCount", "changeCount")) check(state.getInt(name) in 0..10000) { "Invalid hidden KAS scan range" }
        val exposed = state.getJSONArray("exposed")
        check(exposed.length() <= 20000) { "Hidden KAS exposure journal too large" }
        for (i in 0 until exposed.length()) {
            val parts = exposed.getString(i).split(":")
            check(parts.size == 2 && parts[0] in listOf("0", "1") && parts[1].toInt() in 0..9999) { "Invalid exposure record" }
            check(parts[1].toInt() < state.getInt(if (parts[0] == "0") "receiveCount" else "changeCount")) { "Exposure outside issued range" }
        }
        state.optJSONObject("pending")?.let {
            check(it.getString("transactionId").matches(Regex("[0-9a-f]{64}")) && it.getString("submitJson").length <= 1024 * 1024) { "Invalid saved hidden KAS transaction" }
        }
    }
    @Synchronized private fun save(state: JSONObject) {
        validate(state)
        val id = walletId()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD("$descriptor:$id".toByteArray(Charsets.UTF_8))
        val plain = state.toString().toByteArray(Charsets.UTF_8)
        val encrypted = try { cipher.doFinal(plain) } finally { plain.fill(0) }
        val box = JSONObject().put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .put("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
        try { check(prefs().edit().putString(storage(id), box.toString()).commit()) { "Cannot persist address exposure. No signed bytes may leave the native boundary." } }
        finally { encrypted.fill(0) }
    }
    fun derive(branch: Int, start: Int, count: Int): JSONArray {
        val raw = withSecret { SecureCore.deriveHiddenKas(it, branch, start, count) }
        if (!raw.startsWith("[")) parse(raw)
        return JSONArray(raw)
    }
    @Synchronized fun issue(branch: Int): JSONObject {
        check(branch in 0..1) { "Invalid address branch" }
        val state = load()
        check(!state.has("pending")) { "Finish the saved transaction before generating another address" }
        val name = if (branch == 0) "receiveCount" else "changeCount"
        val index = state.getInt(name)
        val exposed = state.getJSONArray("exposed")
        if (branch == 1 && index > 0 && (0 until exposed.length()).none { exposed.getString(it) == "1:${index - 1}" }) {
            // Abandoned unsigned reviews do not consume this reservation.
            return derive(1, index - 1, 1).getJSONObject(0)
        }
        val highest = (0 until exposed.length()).map { exposed.getString(it) }
            .filter { it.startsWith("$branch:") }.map { it.substringAfter(':').toInt() }.maxOrNull() ?: -1
        check(index - highest <= 20) { "Discovery gap limit reached. Use an issued address before generating more, and keep the encrypted backup." }
        val address = derive(branch, index, 1).getJSONObject(0)
        state.put(name, index + 1); save(state) // Commit BEFORE exposing address to Flutter.
        return address
    }
    @Synchronized fun observe(used: JSONArray): JSONObject {
        check(used.length() <= 20000) { "Too many observed addresses" }
        val state = load(); val exposed = state.getJSONArray("exposed")
        val known = (0 until exposed.length()).map { exposed.getString(it) }.toMutableSet()
        for (i in 0 until used.length()) {
            val a = used.getJSONObject(i); val branch = a.getInt("branch"); val index = a.getInt("index")
            check(branch in 0..1 && index in 0..9999) { "Invalid observed address" }
            val name = if (branch == 0) "receiveCount" else "changeCount"
            state.put(name, maxOf(state.getInt(name), index + 1))
            if (known.add("$branch:$index")) exposed.put("$branch:$index")
        }
        save(state); return state
    }
    private fun verifyRequest(request: JSONObject, state: JSONObject) {
        check(request.getString("descriptor") == descriptor && !state.has("pending")) { "Finish the saved transaction first" }
        val change = request.getJSONObject("change")
        check(change.getInt("branch") == 1 && change.getInt("index") == state.getInt("changeCount") - 1) { "Change address is not the latest reserved address" }
        val exposed = state.getJSONArray("exposed")
        check((0 until exposed.length()).none { exposed.getString(it) == "1:${change.getInt("index")}" }) { "Change key is already exposed" }
        for (i in 0 until exposed.length()) {
            val coordinate = exposed.getString(i).split(":")
            check(derive(coordinate[0].toInt(), coordinate[1].toInt(), 1).getJSONObject(0).getString("address") != request.getString("recipient")) {
                "Recipient is a retired address of this account. Choose a fresh receiving address."
            }
        }
        val signers = request.getJSONArray("signers")
        for (a in (0 until signers.length()).map { signers.getJSONObject(it) } + listOf(change)) {
            val branch = a.getInt("branch"); val index = a.getInt("index")
            check(branch in 0..1 && index in 0 until state.getInt(if (branch == 0) "receiveCount" else "changeCount")) { "Unissued hidden KAS address" }
            check(derive(branch, index, 1).getJSONObject(0).let {
                    it.getString("address") == a.getString("address") && it.getString("keyHash") == a.getString("keyHash")
                }) { "Hidden address does not belong to the active seed" }
            // Receiving to an already exposed own key would undo key hiding.
            check(a.getString("address") != request.getString("recipient")) { "Do not pay a key being revealed by this transaction" }
        }
    }
    @Synchronized fun prepare(raw: String): String {
        verifyRequest(JSONObject(raw), load())
        return parse(SecureCore.prepareHiddenKas(raw)).toString()
    }
    @Synchronized fun sign(raw: String, hash: String): String {
        val request = JSONObject(raw); val state = load(); verifyRequest(request, state)
        val review = parse(SecureCore.prepareHiddenKas(raw))
        check(review.getString("reviewHash") == hash) { "Hidden KAS terms changed; review again" }
        val signers = request.getJSONArray("signers")
        val exposure = JSONArray()
        for (i in 0 until signers.length()) exposure.put(signers.getJSONObject(i))
        exposure.put(request.getJSONObject("change")) // Consume the reservation even if broadcast never succeeds.
        observe(exposure) // Durable burn BEFORE secret signing, even if signing fails.
        val signed = parse(withSecret { SecureCore.signHiddenKas(it, raw, hash) })
        signed.put("request", request)
        val updated = load(); updated.put("pending", signed)
        save(updated) // If this fails, signed bytes are discarded, keys stay burnt.
        return signed.toString()
    }
    @Synchronized fun confirm(transactionId: String, expectedWalletId: String) {
        check(walletId() == expectedWalletId) { "Wallet changed" }
        val state = load()
        check(state.optJSONObject("pending")?.getString("transactionId") == transactionId) { "Saved transaction changed" }
        state.remove("pending"); save(state)
    }
    @Synchronized fun restore(imported: JSONObject) {
        validate(imported)
        val current = load()
        for (name in listOf("receiveCount", "changeCount")) current.put(name, maxOf(current.getInt(name), imported.getInt(name)))
        val exposed = current.getJSONArray("exposed")
        val known = (0 until exposed.length()).map { exposed.getString(it) }.toMutableSet()
        val other = imported.getJSONArray("exposed")
        for (i in 0 until other.length()) if (known.add(other.getString(i))) exposed.put(other.getString(i))
        imported.optJSONObject("pending")?.let {
            parse(withSecret { secret -> SecureCore.verifySavedHiddenKas(secret, it.toString()) })
            check(!current.has("pending") || current.getJSONObject("pending").getString("transactionId") == it.getString("transactionId")) { "Two different saved transactions; keep both backups" }
            current.put("pending", it)
        }
        save(current)
    }
}
