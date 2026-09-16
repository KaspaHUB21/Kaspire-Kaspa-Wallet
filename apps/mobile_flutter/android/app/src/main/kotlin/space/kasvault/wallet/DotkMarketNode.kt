package space.kasvault.wallet

import org.json.JSONArray
import org.json.JSONObject
import java.net.URL
import java.net.URLEncoder
import javax.net.ssl.HttpsURLConnection

/** Independent native pre-signing check; no caller-selected host or script. */
object DotkMarketNode {
    private const val base = "https://kaspire.kaslab.space/api/local-node"
    private fun get(path: String): String {
        val connection = URL(base + path).openConnection() as HttpsURLConnection
        connection.instanceFollowRedirects = false
        connection.connectTimeout = 8000
        connection.readTimeout = 8000
        try {
            check(connection.responseCode == 200) { "Marketplace node verification is unavailable" }
            val bytes = connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    check(output.size() + count <= 4 * 1024 * 1024) { "Node response exceeds verification limit" }
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            return bytes.toString(Charsets.UTF_8)
        } finally { connection.disconnect() }
    }

    fun verify(review: JSONObject) {
        val tx = JSONObject(review.getString("transactionJson"))
        val inputs = tx.getJSONArray("inputs")
        check(inputs.length() in 1..80)
        val seen = mutableSetOf<String>()
        val liveByAddress = mutableMapOf<String, JSONArray>()
        for (i in 0 until inputs.length()) {
            val input = inputs.getJSONObject(i)
            val txid = input.getString("transactionId")
            val index = input.getInt("index")
            check(txid.matches(Regex("[0-9a-f]{64}")) && index >= 0 && seen.add("$txid:$index"))
            val expected = input.getJSONObject("utxo")
            val previous = JSONObject(get("/transactions/$txid"))
            check(previous.getString("transaction_id") == txid && previous.getBoolean("is_accepted")) {
                "Marketplace input transaction is not accepted"
            }
            val outputs = previous.getJSONArray("outputs")
            val output = (0 until outputs.length()).map { outputs.getJSONObject(it) }
                .singleOrNull { it.getInt("index") == index }
                ?: error("Marketplace input output is missing")
            val expectedScript = expected.getString("scriptPublicKey")
            check(expectedScript.startsWith("0000")) { "Unsupported script version" }
            val script = expectedScript.drop(4)
            val expectedCovenant = if (expected.isNull("covenantId")) null else expected.getString("covenantId")
            val actualCovenant = if (output.isNull("covenant_id")) null else output.getString("covenant_id")
            check(output.get("amount").toString() == expected.get("amount").toString() &&
                output.getString("script_public_key") == script && actualCovenant == expectedCovenant) {
                "Marketplace input conflicts with the accepted on-chain output"
            }
            val address = output.getString("script_public_key_address")
            check(address.startsWith("kaspa:"))
            val live = liveByAddress.getOrPut(address) {
                JSONArray(get("/addresses/${URLEncoder.encode(address, "UTF-8")}/utxos"))
            }
            val matches = (0 until live.length()).map { live.getJSONObject(it) }.filter {
                val point = it.getJSONObject("outpoint")
                point.getString("transactionId") == txid && point.getInt("index") == index
            }
            check(matches.size == 1) { "Marketplace input has already been spent; refresh the offer" }
            val entry = matches.single().getJSONObject("utxoEntry")
            val spk = entry.getJSONObject("scriptPublicKey")
            check(!entry.getBoolean("isCoinbase") && entry.get("amount").toString() == expected.get("amount").toString() &&
                spk.getString("scriptPublicKey") == script && spk.optInt("version", 0) == 0 &&
                entry.get("blockDaaScore").toString() == expected.get("blockDaaScore").toString()) {
                "Marketplace live UTXO does not match the approved input"
            }
        }
    }
}
