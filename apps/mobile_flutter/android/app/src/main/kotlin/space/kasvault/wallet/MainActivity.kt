package space.kasvault.wallet

import android.app.AlertDialog
import android.app.Dialog
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.text.InputType
import android.text.Editable
import android.text.TextWatcher
import android.util.Base64
import android.widget.EditText
import android.widget.AutoCompleteTextView
import android.widget.ArrayAdapter
import android.widget.ScrollView
import android.widget.TextView
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.GridLayout
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.json.JSONArray
import java.security.KeyStore
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

class MainActivity : FlutterFragmentActivity() {
    private data class OperationAuthorization(
        val operation: String,
        val binding: String,
        val expiresAt: Long,
    )
    private data class NativeReviewSummary(
        val operation: String,
        val text: String,
        val expiresAt: Long,
    )

    private val authorizationLock = Any()
    private val operationAuthorizations = mutableMapOf<String, OperationAuthorization>()
    private val nativeReviewSummaries = mutableMapOf<String, NativeReviewSummary>()
    private val authorizationLifetimeMs = 20_000L
    private val deviceCredentialRequestCode = 7109
    private var pendingDeviceCredentialAuthorization:
        Triple<String, String, MethodChannel.Result>? = null
    private var lastSessionAuthenticationAtMs = 0L
    private val channelName = "space.kasvault/security"
    private val vaultAlias = "kaspire_secret_wrap_v4"
    private val preferencesName = "kaspire_native_v4"
    private val seedCiphertextKey = "seed_ciphertext"
    private val seedIvKey = "seed_iv"
    private val addressKey = "wallet_address"
    private val walletIdsKey = "wallet_ids_v1"
    private val activeWalletIdKey = "active_wallet_id_v1"
    private val pinSaltKey = "pin_salt_v1"
    private val pinHashKey = "pin_hash_v1"
    private val pinFailuresKey = "pin_failures_v1"
    private val pinLockedUntilKey = "pin_locked_until_v1"
    private val bip39Words: List<String> by lazy {
        assets.open("bip39_english.txt").bufferedReader().use { reader ->
            reader.readText().split(Regex("\\s+")).filter { it.isNotEmpty() }
        }.also { check(it.size == 2048) { "Invalid embedded BIP-39 word list" } }
    }
    private val bip39WordSet: Set<String> by lazy { bip39Words.toHashSet() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "initializeVault" -> { ensureVaultKey(); migrateLegacyWallet(); result.success(null) }
                    "isHardwareBacked" -> result.success(isHardwareBacked())
                    "verifyUpdateManifest" -> result.success(verifyUpdateManifest(
                        call.argument<String>("payload") ?: error("Missing update payload"),
                        call.argument<String>("signature") ?: error("Missing update signature"),
                    ))
                    "hasNativeWallet" -> result.success(hasNativeWallet(call.argument<String>("address")))
                    "getNativeAddress" -> result.success(activeWalletAddress())
                    "listWallets" -> result.success(listWalletsJson().toString())
                    "deriveAddresses" -> {
                        val secret = decryptSecret()
                        val raw = SecureCore.deriveAddresses(
                            secret,
                            call.argument<Int>("coinType") ?: error("Missing coin type"),
                            call.argument<Int>("account") ?: 0,
                            call.argument<Int>("change") ?: error("Missing change branch"),
                            call.argument<Int>("start") ?: error("Missing start index"),
                            call.argument<Int>("count") ?: error("Missing address count")
                        )
                        resultFromCoreArray(raw, result)
                    }
                    "registerHdAddresses" -> {
                        registerHdAddresses(call.argument<String>("addresses") ?: error("Missing addresses"))
                        result.success(null)
                    }
                    "selectWallet" -> {
                        selectWallet(call.argument<String>("walletId") ?: error("Missing wallet id"))
                        result.success(null)
                    }
                    "renameWallet" -> {
                        renameWallet(
                            call.argument<String>("walletId") ?: error("Missing wallet id"),
                            call.argument<String>("name") ?: error("Missing wallet name")
                        )
                        result.success(null)
                    }
                    "hasPin" -> result.success(hasPin())
                    "authorizeOperation" -> authorizeOperation(
                        call.argument<String>("operation") ?: error("Missing operation"),
                        call.argument<String>("binding") ?: error("Missing operation binding"),
                        call.argument<Int>("sessionMinutes") ?: 0,
                        result,
                    )
                    "verifyPin" -> verifyPinDialog(call.argument<String>("reason") ?: "Authorize Kaspire", result)
                    "configurePin" -> configurePinDialog(result)
                    "removePin" -> { clearPin(); result.success(null) }
                    "createWallet" -> createWallet(result)
                    "importWallet" -> importWallet(result)
                    "importPrivateKey" -> importPrivateKey(result)
                    "exportPrivateKey" -> {
                        val address = call.argument<String>("address") ?: error("Missing export address")
                        val id = activeWalletId() ?: error("No active signing wallet")
                        check(controlsAddress(id, address)) {
                            "The active wallet does not control the requested export address"
                        }
                        requireAuthorization(call, "exportPrivateKey", address)
                        exportPrivateKey(address, result)
                    }
                    "exportRecoveryPhrase" -> {
                        requireAuthorization(call, "exportRecoveryPhrase", activeWalletAddress() ?: "")
                        exportRecoveryPhrase(result)
                    }
                    "exportEncryptedBackup" -> {
                        requireAuthorization(call, "exportEncryptedBackup", activeWalletAddress() ?: "")
                        exportEncryptedBackup(result)
                    }
                    "restoreEncryptedBackup" -> restoreEncryptedBackup(result)
                    "deleteWallet" -> {
                        val walletId = call.argument<String>("walletId") ?: activeWalletId()
                        requireAuthorization(call, "deleteWallet", walletId ?: "")
                        deleteWallet(walletId)
                        result.success(null)
                    }
                    "prepareTransaction" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        resultPreparedFromCore(
                            SecureCore.prepareTransaction(request),
                            "signTransaction",
                            result,
                        )
                    }
                    "prepareKcc20Transfer" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        resultPreparedFromCore(
                            SecureCore.prepareKcc20Transfer(request),
                            "signKcc20Transfer",
                            result,
                        )
                    }
                    "prepareInscription" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        resultFromCore(SecureCore.prepareInscription(request), result)
                    }
                    "prepareReveal" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        resultPreparedFromCore(
                            SecureCore.prepareReveal(request),
                            "signReveal",
                            result,
                        )
                    }
                    "preparePolicyTransaction" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        resultPreparedFromCore(
                            SecureCore.preparePolicyTransaction(request),
                            "signPolicyTransaction",
                            result,
                        )
                    }
                    "preparePskt" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        resultPreparedFromCore(
                            SecureCore.preparePskt(request),
                            "signPskt",
                            result,
                        )
                    }
                    "signPskt" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        val reviewHash = call.argument<String>("reviewHash") ?: error("Missing review hash")
                        requireAuthorization(call, "signPskt", reviewHash)
                        val secret = decryptSecret(JSONObject(request).getString("sender"))
                        resultFromCore(
                            SecureCore.signPskt(secret, request, reviewHash),
                            result,
                        )
                    }
                    "signPolicyTransaction" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        val reviewHash = call.argument<String>("reviewHash") ?: error("Missing review hash")
                        requireAuthorization(call, "signPolicyTransaction", reviewHash)
                        val secret = decryptSecret(JSONObject(request).getString("sender"))
                        resultFromCore(
                            SecureCore.signPolicyTransaction(secret, request, reviewHash),
                            result,
                        )
                    }
                    "signReveal" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        val reviewHash = call.argument<String>("reviewHash") ?: error("Missing review hash")
                        requireAuthorization(call, "signReveal", reviewHash)
                        val sender = JSONObject(request).getJSONObject("operation").getString("sender")
                        val secret = decryptSecret(sender)
                        resultFromCore(SecureCore.signReveal(secret, request, reviewHash), result)
                    }
                    "signTransaction" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        val reviewHash = call.argument<String>("reviewHash") ?: error("Missing review hash")
                        requireAuthorization(call, "signTransaction", reviewHash)
                        val requestObject = JSONObject(request)
                        val secret = decryptSecret(
                            requestObject.optString(
                                "walletAddress",
                                requestObject.getString("sender"),
                            ),
                        )
                        try {
                            resultFromCore(SecureCore.signTransaction(secret, request, reviewHash), result)
                        } finally {
                            // The Rust key and seed buffers are zeroized. Java strings cannot be
                            // reliably wiped, so this reference is scoped to this native call only.
                        }
                    }
                    "signKcc20Transfer" -> {
                        val request = call.argument<String>("request") ?: error("Missing request")
                        val reviewHash = call.argument<String>("reviewHash") ?: error("Missing review hash")
                        requireAuthorization(call, "signKcc20Transfer", reviewHash)
                        val secret = decryptSecret(JSONObject(request).getString("sender"))
                        resultFromCore(SecureCore.signKcc20Transfer(secret, request, reviewHash), result)
                    }
                    "signPersonalMessage" -> {
                        val address = call.argument<String>("address") ?: error("Missing address")
                        val message = call.argument<String>("message") ?: error("Missing message")
                        requireAuthorization(call, "signPersonalMessage", "$address\u0000$message")
                        val secret = decryptSecret(address)
                        resultFromCore(SecureCore.signPersonalMessage(secret, address, message), result)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("SECURITY_ERROR", "${error.javaClass.simpleName}: ${error.message ?: "Native vault operation failed"}", null)
            }
        }
    }

    private fun createWallet(result: MethodChannel.Result) {
        val generated = parseCore(SecureCore.generateWallet(""))
        val mnemonic = generated.getString("mnemonic")
        val view = recoveryView(
            "YOUR 24-WORD WALLET",
            "Write down every word in order. You may then enable an optional BIP-39 passphrase below the 24 words before creating the wallet.",
            mnemonic.split(" "),
            24,
            true
        )
        view.cancel.text = "CANCEL"
        view.confirm.text = "CREATE WALLET"
        view.cancel.setOnClickListener {
            clearRecoveryView(view)
            view.dialog.dismiss()
            result.error("CANCELLED", "Wallet creation cancelled", null)
        }
        view.confirm.setOnClickListener {
            try {
                val passphrase = selectedPassphrase(view)
                clearRecoveryView(view)
                view.dialog.dismiss()
                showCreationVerification(mnemonic, passphrase, result)
            } catch (error: Exception) {
                view.error.text = error.message ?: "Could not create wallet"
                view.error.visibility = TextView.VISIBLE
            }
        }
        showRecoveryView(view)
    }

    private fun showCreationVerification(
        mnemonic: String,
        passphrase: String,
        result: MethodChannel.Result
    ) {
        val words = mnemonic.split(" ")
        val indices = (words.indices).shuffled(kotlin.random.Random.Default).take(4).sorted()
        val view = recoveryView(
            "VERIFY YOUR BACKUP",
            "Enter the requested recovery words. Kaspire will create the wallet only after this offline backup check succeeds.",
            null,
            indices.size,
            false,
            fieldNumbers = indices.map { it + 1 }
        )
        view.cancel.text = "BACK"
        view.confirm.text = "VERIFY & CREATE"
        view.cancel.setOnClickListener {
            clearRecoveryView(view)
            view.dialog.dismiss()
            result.error("CANCELLED", "Wallet creation cancelled before backup verification", null)
        }
        view.confirm.setOnClickListener {
            try {
                val correct = indices.indices.all { fieldIndex ->
                    view.fields[fieldIndex].text.toString().trim().lowercase() == words[indices[fieldIndex]]
                }
                check(correct) { "One or more recovery words are incorrect" }
                val material = parseCore(SecureCore.importWallet(mnemonic, passphrase))
                val address = material.getString("address")
                storeWallet(encodeMnemonicSecret(mnemonic, passphrase), address)
                clearRecoveryView(view)
                view.dialog.dismiss()
                result.success(address)
            } catch (error: Exception) {
                view.error.text = error.message ?: "Recovery verification failed"
                view.error.visibility = TextView.VISIBLE
            }
        }
        showRecoveryView(view)
    }

    private fun importWallet(result: MethodChannel.Result) {
        showImportWallet(result)
    }

    private fun showImportWallet(result: MethodChannel.Result) {
        val view = recoveryView(
            "IMPORT WALLET",
            "Choose 12 or 24 words, then enter your English BIP-39 recovery phrase in order. You can also paste the complete phrase into the first field.",
            null,
            24,
            true,
            true
        )
        view.cancel.text = "CANCEL"
        view.confirm.text = "IMPORT WALLET"
        view.cancel.setOnClickListener {
            clearRecoveryView(view)
            view.dialog.dismiss()
            result.error("CANCELLED", "Import cancelled", null)
        }
        view.confirm.setOnClickListener {
            try {
                val selectedCount = view.selectedWordCount()
                check(selectedCount == 12 || selectedCount == 24) { "Choose 12 or 24 words first" }
                val phrase = view.fields.take(selectedCount)
                    .joinToString(" ") { it.text.toString().trim() }.trim()
                val invalid = view.fields.take(selectedCount).filter {
                    !bip39WordSet.contains(it.text.toString().trim().lowercase())
                }
                invalid.forEach { it.error = "Not an English BIP-39 word" }
                check(invalid.isEmpty()) {
                    "Correct the highlighted recovery words before importing"
                }
                val passphrase = selectedPassphrase(view)
                val material = parseCore(SecureCore.importWallet(phrase, passphrase))
                val normalized = material.getString("mnemonic")
                val address = material.getString("address")
                storeWallet(encodeMnemonicSecret(normalized, passphrase), address)
                clearRecoveryView(view)
                view.dialog.dismiss()
                result.success(address)
            } catch (error: Exception) {
                view.error.text = error.message ?: "Invalid recovery phrase"
                view.error.visibility = TextView.VISIBLE
            }
        }
        showRecoveryView(view)
    }

    private data class RecoveryView(
        val dialog: Dialog,
        val fields: List<EditText>,
        val passphraseEnabled: CheckBox?,
        val passphrase: EditText?,
        val passphraseConfirmation: EditText?,
        val passphraseAcknowledged: CheckBox?,
        val selectedWordCount: () -> Int,
        val error: TextView,
        val cancel: Button,
        val confirm: Button
    )

    private fun recoveryView(
        title: String,
        message: String,
        words: List<String>?,
        wordCount: Int,
        includePassphrase: Boolean,
        selectableWordCount: Boolean = false,
        fieldNumbers: List<Int>? = null
    ): RecoveryView {
        val mint = Color.rgb(73, 234, 203)
        val ink = Color.rgb(5, 10, 13)
        val panel = Color.rgb(11, 21, 26)
        val muted = Color.rgb(151, 166, 173)
        var activeWordCount = if (selectableWordCount) 0 else wordCount
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(18))
            setBackgroundColor(ink)
        }
        root.addView(TextView(this).apply {
            text = title
            textSize = 27f
            setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        root.addView(TextView(this).apply {
            text = message
            textSize = 14f
            setTextColor(muted)
            setPadding(0, dp(10), 0, dp(16))
        })
        val grid = GridLayout(this).apply {
            columnCount = 2
            setPadding(0, 0, 0, dp(12))
        }
        val fieldHolders = mutableListOf<LinearLayout>()
        val fields: List<EditText> = (0 until wordCount).map { index ->
            val field: EditText = if (words == null) {
                AutoCompleteTextView(this).apply {
                    threshold = 3
                    setAdapter(
                        ArrayAdapter(
                            this@MainActivity,
                            android.R.layout.simple_dropdown_item_1line,
                            bip39Words,
                        )
                    )
                    dropDownHeight = dp(220)
                }
            } else {
                EditText(this)
            }
            field.apply {
                setText(words?.getOrNull(index) ?: "")
                hint = "word"
                textSize = 15f
                setTextColor(Color.WHITE)
                setHintTextColor(muted)
                isSingleLine = true
                isEnabled = words == null
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
                setPadding(dp(10), dp(11), dp(8), dp(11))
                background = GradientDrawable().apply {
                    setColor(panel)
                    setStroke(dp(1), mint)
                    cornerRadius = dp(12).toFloat()
                }
            }
            val holder = LinearLayout(this).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(TextView(this@MainActivity).apply {
                    text = "${fieldNumbers?.getOrNull(index) ?: index + 1}"
                    textSize = 11f
                    setTextColor(mint)
                    gravity = Gravity.CENTER
                }, LinearLayout.LayoutParams(dp(34), ViewGroup.LayoutParams.MATCH_PARENT))
                addView(field, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
            val params = GridLayout.LayoutParams().apply {
                width = 0
                height = ViewGroup.LayoutParams.WRAP_CONTENT
                columnSpec = GridLayout.spec(index % 2, 1f)
                rowSpec = GridLayout.spec(index / 2)
                setMargins(dp(4), dp(4), dp(4), dp(4))
            }
            fieldHolders.add(holder)
            grid.addView(holder, params)
            field
        }
        var passphraseEnabled: CheckBox? = null
        var passphrase: EditText? = null
        var passphraseConfirmation: EditText? = null
        var passphraseAcknowledged: CheckBox? = null
        val wordSection = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(grid)
            visibility = if (selectableWordCount) LinearLayout.GONE else LinearLayout.VISIBLE
        }
        val scrollContent = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        if (selectableWordCount) {
            scrollContent.addView(TextView(this).apply {
                text = "RECOVERY PHRASE LENGTH"
                textSize = 11f
                setTextColor(muted)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setPadding(dp(4), 0, dp(4), dp(7))
            })
            val twelveId = View.generateViewId()
            val twentyFourId = View.generateViewId()
            val selector = RadioGroup(this).apply {
                orientation = RadioGroup.HORIZONTAL
                addView(RadioButton(this@MainActivity).apply {
                    id = twelveId
                    text = "12 WORDS"
                    setTextColor(Color.WHITE)
                    buttonTintList = android.content.res.ColorStateList.valueOf(mint)
                }, RadioGroup.LayoutParams(0, dp(52), 1f))
                addView(RadioButton(this@MainActivity).apply {
                    id = twentyFourId
                    text = "24 WORDS"
                    setTextColor(Color.WHITE)
                    buttonTintList = android.content.res.ColorStateList.valueOf(mint)
                }, RadioGroup.LayoutParams(0, dp(52), 1f))
                setOnCheckedChangeListener { _, checkedId ->
                    activeWordCount = if (checkedId == twelveId) 12 else 24
                    fieldHolders.forEachIndexed { index, holder ->
                        holder.visibility = if (index < activeWordCount) LinearLayout.VISIBLE else LinearLayout.GONE
                        if (index >= activeWordCount) fields[index].text.clear()
                    }
                    wordSection.visibility = LinearLayout.VISIBLE
                }
            }
            scrollContent.addView(selector)
            scrollContent.addView(wordSection)
        } else {
            scrollContent.addView(wordSection)
        }
        if (includePassphrase) {
            val passphrasePanel = LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                visibility = LinearLayout.GONE
                setPadding(dp(4), dp(4), dp(4), dp(10))
            }
            fun passphraseField(label: String) = EditText(this).apply {
                hint = label
                textSize = 15f
                setTextColor(Color.WHITE)
                setHintTextColor(muted)
                isSingleLine = true
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                setPadding(dp(12), dp(10), dp(12), dp(10))
                background = GradientDrawable().apply {
                    setColor(panel)
                    setStroke(dp(1), mint)
                    cornerRadius = dp(12).toFloat()
                }
            }
            val firstPassphraseField = passphraseField("BIP-39 passphrase")
            val confirmationField = passphraseField("Confirm passphrase exactly")
            passphrase = firstPassphraseField
            passphraseConfirmation = confirmationField
            passphrasePanel.addView(TextView(this).apply {
                text = "WARNING: A passphrase creates a completely different wallet. Losing it or changing capitalization or spaces permanently locks the funds. The recovery words alone are not enough, and Kaspire cannot restore it."
                textSize = 12.5f
                setTextColor(Color.rgb(255, 183, 77))
                setPadding(0, 0, 0, dp(8))
            })
            passphrasePanel.addView(firstPassphraseField, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(48)).apply {
                bottomMargin = dp(5)
            })
            passphrasePanel.addView(confirmationField, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(48)).apply {
                bottomMargin = dp(4)
            })
            passphrasePanel.addView(CheckBox(this).apply {
                text = "Show passphrase"
                setTextColor(muted)
                setOnCheckedChangeListener { _, checked ->
                    val type = InputType.TYPE_CLASS_TEXT or if (checked) InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD else InputType.TYPE_TEXT_VARIATION_PASSWORD
                    firstPassphraseField.inputType = type
                    confirmationField.inputType = type
                    firstPassphraseField.setSelection(firstPassphraseField.text.length)
                    confirmationField.setSelection(confirmationField.text.length)
                }
            })
            passphraseAcknowledged = CheckBox(this).apply {
                text = "I stored this passphrase separately from the recovery words"
                setTextColor(Color.rgb(255, 183, 77))
            }
            passphrasePanel.addView(passphraseAcknowledged)
            passphraseEnabled = CheckBox(this).apply {
                text = "Use an optional BIP-39 passphrase"
                setTextColor(mint)
                setTypeface(typeface, android.graphics.Typeface.BOLD)
                setOnCheckedChangeListener { _, checked ->
                    passphrasePanel.visibility = if (checked) LinearLayout.VISIBLE else LinearLayout.GONE
                    if (!checked) {
                        firstPassphraseField.text.clear()
                        confirmationField.text.clear()
                    }
                }
            }
            wordSection.addView(passphraseEnabled)
            wordSection.addView(passphrasePanel)
        }
        if (words == null) {
            var distributing = false
            fields.first().addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(value: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(value: CharSequence?, start: Int, before: Int, count: Int) = Unit
                override fun afterTextChanged(value: Editable?) {
                    if (distributing || activeWordCount == 0) return
                    val pasted = value.toString().trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
                    if (pasted.size != activeWordCount) return
                    distributing = true
                    fields.take(activeWordCount).forEachIndexed { index, field ->
                        field.setText(pasted.getOrNull(index) ?: "")
                    }
                    distributing = false
                }
            })
            fields.forEach { field ->
                field.addTextChangedListener(object : TextWatcher {
                    override fun beforeTextChanged(value: CharSequence?, start: Int, count: Int, after: Int) = Unit
                    override fun onTextChanged(value: CharSequence?, start: Int, before: Int, count: Int) = Unit
                    override fun afterTextChanged(value: Editable?) {
                        if (distributing) return
                        val entered = value.toString().trim().lowercase()
                        field.error = when {
                            entered.isEmpty() -> null
                            bip39WordSet.contains(entered) -> null
                            bip39Words.none { word -> word.startsWith(entered) } ->
                                "Not an English BIP-39 word"
                            else -> null
                        }
                    }
                })
            }
        }
        root.addView(
            ScrollView(this).apply { addView(scrollContent) },
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
        )
        val error = TextView(this).apply {
            setTextColor(Color.rgb(255, 138, 101))
            textSize = 13f
            visibility = TextView.GONE
            setPadding(dp(4), dp(6), dp(4), dp(8))
        }
        root.addView(error)
        val cancel = Button(this).apply {
            setTextColor(mint)
            background = GradientDrawable().apply {
                setColor(Color.TRANSPARENT)
                setStroke(dp(1), mint)
                cornerRadius = dp(14).toFloat()
            }
        }
        val confirm = Button(this).apply {
            setTextColor(ink)
            background = GradientDrawable().apply {
                setColor(mint)
                cornerRadius = dp(14).toFloat()
            }
        }
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(cancel, LinearLayout.LayoutParams(0, dp(54), 1f).apply { marginEnd = dp(5) })
            addView(confirm, LinearLayout.LayoutParams(0, dp(54), 1f).apply { marginStart = dp(5) })
        })
        return RecoveryView(
            Dialog(this).apply {
                setContentView(root)
                setCancelable(false)
            },
            fields,
            passphraseEnabled,
            passphrase,
            passphraseConfirmation,
            passphraseAcknowledged,
            { activeWordCount },
            error,
            cancel,
            confirm
        )
    }

    private fun showRecoveryView(view: RecoveryView) {
        view.dialog.show()
        view.dialog.window?.apply {
            addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.rgb(5, 10, 13)))
            setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private fun selectedPassphrase(view: RecoveryView): String {
        if (view.passphraseEnabled?.isChecked != true) return ""
        val passphrase = view.passphrase?.text?.toString() ?: ""
        val confirmation = view.passphraseConfirmation?.text?.toString() ?: ""
        check(passphrase.isNotEmpty()) { "Enter a passphrase or turn off the passphrase option" }
        check(passphrase == confirmation) { "Passphrases do not match exactly" }
        check(view.passphraseAcknowledged?.isChecked == true) {
            "Confirm that the passphrase is backed up separately"
        }
        return passphrase
    }

    private fun clearRecoveryView(view: RecoveryView) {
        view.fields.forEach { it.text.clear() }
        view.passphrase?.text?.clear()
        view.passphraseConfirmation?.text?.clear()
        view.passphraseAcknowledged?.isChecked = false
    }

    private fun importPrivateKey(result: MethodChannel.Result) {
        val input = EditText(this).apply {
            hint = "64-character hexadecimal private key"
            maxLines = 3
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
            setPadding(48, 24, 48, 24)
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Import private key")
            .setMessage("Enter a raw 32-byte Kaspa private key. An optional 0x prefix is accepted.")
            .setView(input)
            .setNegativeButton("Cancel") { _, _ -> result.error("CANCELLED", "Private-key import cancelled", null) }
            .setPositiveButton("Import", null)
            .setCancelable(false)
            .create()
        dialog.setOnShowListener {
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                try {
                    val material = parseCore(SecureCore.importPrivateKey(input.text.toString()))
                    val privateKey = material.getString("privateKey")
                    val address = material.getString("address")
                    storeWallet("private:$privateKey", address)
                    input.text.clear()
                    dialog.dismiss()
                    result.success(address)
                } catch (error: Exception) {
                    input.error = error.message ?: "Invalid private key"
                }
            }
        }
        dialog.show()
    }

    private fun exportPrivateKey(address: String, result: MethodChannel.Result) {
        val secret = decryptSecret(address)
        val json = parseCore(SecureCore.exportPrivateKey(secret))
        showSecret("Private key", json.getString("privateKey"), result)
    }

    private fun exportRecoveryPhrase(result: MethodChannel.Result) {
        val secret = decryptSecret()
        check(secret.startsWith("mnemonic:") || secret.startsWith("mnemonic-passphrase:")) {
            "This wallet was imported from a private key and has no recovery phrase"
        }
        val backup = decodeMnemonicSecret(secret)
        if (backup.passphrase == null) {
            showSecret("Recovery phrase", backup.mnemonic, result)
        } else {
            showSecret(
                "Recovery backup",
                "24-word recovery phrase:\n${backup.mnemonic}\n\nBIP-39 passphrase:\n${backup.passphrase}",
                result,
                "Keep both secrets offline and backed up separately. Both are required to recover this wallet. Any change to capitalization or spaces opens a different wallet."
            )
        }
    }

    private fun showSecret(
        title: String,
        secret: String,
        result: MethodChannel.Result,
        warning: String = "Keep this secret offline. Anyone who obtains it can spend the wallet funds."
    ) {
        val text = TextView(this).apply {
            setPadding(48, 24, 48, 24)
            this.text = secret
            textSize = 17f
            setTextIsSelectable(true)
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle(title)
            .setMessage(warning)
            .setView(ScrollView(this).apply { addView(text) })
            .setPositiveButton("Done") { _, _ -> result.success(null) }
            .setCancelable(false)
            .create()
        dialog.setOnShowListener {
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
        dialog.show()
    }

    private fun backupPasswordFields(): Triple<EditText, EditText, LinearLayout> {
        fun field(label: String) = EditText(this).apply {
            hint = label
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val first = field("Backup password (12+ characters)")
        val second = field("Confirm backup password")
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(8), dp(24), 0)
            addView(first)
            addView(second)
        }
        return Triple(first, second, content)
    }

    private fun backupKey(password: CharArray, salt: ByteArray): ByteArray {
        val spec = PBEKeySpec(password, salt, 600_000, 256)
        return try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
            password.fill('\u0000')
        }
    }

    private fun argon2BackupKey(password: CharArray, salt: ByteArray): ByteArray {
        val passwordText = String(password)
        return try {
            val saltHex = salt.joinToString("") { "%02x".format(it.toInt() and 0xff) }
            val raw = SecureCore.deriveBackupKey(passwordText, saltHex)
            if (raw.trimStart().startsWith("{")) parseCore(raw)
            check(raw.length == 64) { "Argon2id key derivation failed" }
            ByteArray(32) { index ->
                raw.substring(index * 2, index * 2 + 2).toInt(16).toByte()
            }
        } finally {
            password.fill('\u0000')
        }
    }

    private fun exportEncryptedBackup(result: MethodChannel.Result) {
        val (first, second, content) = backupPasswordFields()
        val dialog = AlertDialog.Builder(this)
            .setTitle("Encrypted portable backup")
            .setMessage("Choose a unique password. Kaspire cannot recover either this password or a lost BIP-39 passphrase.")
            .setView(content)
            .setNegativeButton("Cancel") { _, _ -> result.error("CANCELLED", "Backup cancelled", null) }
            .setPositiveButton("ENCRYPT & SHARE", null)
            .setCancelable(false)
            .create()
        dialog.setOnShowListener {
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                try {
                    val one = first.text.toString()
                    check(one.length >= 12) { "Use at least 12 characters" }
                    check(one == second.text.toString()) { "Backup passwords do not match" }
                    val salt = ByteArray(32).also { SecureRandom().nextBytes(it) }
                    val key = argon2BackupKey(one.toCharArray(), salt)
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"))
                    val secret = decryptSecret()
                    val walletId = activeWalletId() ?: error("No active signing wallet")
                    val plaintext = JSONObject().apply {
                        put("secret", secret)
                        put("address", activeWalletAddress())
                        put("addresses", hdAddresses(walletId))
                        put("createdAt", System.currentTimeMillis())
                    }.toString().toByteArray(Charsets.UTF_8)
                    val encrypted = try { cipher.doFinal(plaintext) } finally { plaintext.fill(0) }
                    val backup = JSONObject().apply {
                        put("format", "kaspire-backup-v2")
                        put("kdf", "argon2id-v19")
                        put("memoryKiB", 32768)
                        put("iterations", 3)
                        put("parallelism", 1)
                        put("salt", Base64.encodeToString(salt, Base64.NO_WRAP))
                        put("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
                        put("ciphertext", Base64.encodeToString(encrypted, Base64.NO_WRAP))
                    }.toString()
                    key.fill(0); salt.fill(0); encrypted.fill(0)
                    first.text.clear(); second.text.clear(); dialog.dismiss()
                    startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                        type = "application/json"
                        putExtra(Intent.EXTRA_TEXT, backup)
                        putExtra(Intent.EXTRA_TITLE, "Kaspire encrypted wallet backup")
                    }, "Save encrypted Kaspire backup"))
                    result.success(null)
                } catch (error: Exception) {
                    first.error = error.message ?: "Backup encryption failed"
                }
            }
        }
        dialog.show()
    }

    private fun restoreEncryptedBackup(result: MethodChannel.Result) {
        val backupInput = EditText(this).apply {
            hint = "Paste the complete kaspire-backup-v1 or v2 JSON"
            minLines = 4
            maxLines = 8
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
        }
        val password = EditText(this).apply {
            hint = "Backup password"
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(8), dp(24), 0)
            addView(backupInput)
            addView(password)
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Restore encrypted backup")
            .setMessage("The backup is decrypted only inside Kaspire's native Android boundary.")
            .setView(ScrollView(this).apply { addView(content) })
            .setNegativeButton("Cancel") { _, _ -> result.error("CANCELLED", "Restore cancelled", null) }
            .setPositiveButton("RESTORE", null)
            .setCancelable(false)
            .create()
        dialog.setOnShowListener {
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                try {
                    val backup = JSONObject(backupInput.text.toString().trim())
                    val format = backup.getString("format")
                    check(format == "kaspire-backup-v1" || format == "kaspire-backup-v2") {
                        "Unsupported backup format"
                    }
                    val salt = Base64.decode(backup.getString("salt"), Base64.NO_WRAP)
                    check(salt.size == 32) { "Invalid backup salt" }
                    val iv = Base64.decode(backup.getString("iv"), Base64.NO_WRAP)
                    val encrypted = Base64.decode(backup.getString("ciphertext"), Base64.NO_WRAP)
                    val key = when (format) {
                        "kaspire-backup-v1" -> {
                            check(backup.optString("kdf") == "pbkdf2-sha256" &&
                                backup.getInt("iterations") == 600000) {
                                "Unsupported legacy backup KDF"
                            }
                            backupKey(password.text.toString().toCharArray(), salt)
                        }
                        else -> {
                            check(backup.optString("kdf") == "argon2id-v19" &&
                                backup.getInt("memoryKiB") == 32768 &&
                                backup.getInt("iterations") == 3 &&
                                backup.getInt("parallelism") == 1) {
                                "Unsupported Argon2id parameters"
                            }
                            argon2BackupKey(password.text.toString().toCharArray(), salt)
                        }
                    }
                    val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                    cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
                    val plaintext = try { cipher.doFinal(encrypted) } finally {
                        key.fill(0); salt.fill(0); iv.fill(0); encrypted.fill(0)
                    }
                    val decoded = try { JSONObject(plaintext.toString(Charsets.UTF_8)) } finally { plaintext.fill(0) }
                    val secret = decoded.getString("secret")
                    val material = if (secret.startsWith("private:")) {
                        parseCore(SecureCore.importPrivateKey(secret.removePrefix("private:")))
                    } else {
                        val mnemonic = decodeMnemonicSecret(secret)
                        parseCore(SecureCore.importWallet(mnemonic.mnemonic, mnemonic.passphrase ?: ""))
                    }
                    val address = material.getString("address")
                    check(address == decoded.getString("address")) { "Backup address verification failed" }
                    storeWallet(secret, address)
                    decoded.optJSONArray("addresses")?.let { registerHdAddresses(it.toString()) }
                    backupInput.text.clear(); password.text.clear(); dialog.dismiss()
                    result.success(address)
                } catch (error: Exception) {
                    password.error = error.message ?: "Wrong password or damaged backup"
                }
            }
        }
        dialog.show()
    }

    private fun resultFromCore(raw: String, result: MethodChannel.Result) {
        val json = parseCore(raw)
        result.success(json.toString())
    }

    private fun resultPreparedFromCore(
        raw: String,
        operation: String,
        result: MethodChannel.Result,
    ) {
        val json = parseCore(raw)
        val reviewHash = json.getString("reviewHash")
        val summary = when (operation) {
            "signTransaction" ->
                "Recipient ${json.getString("recipient")}\n" +
                    "Amount ${json.getLong("amountSompi")} sompi · " +
                    "Fee ${json.getLong("feeSompi")} sompi"
            "signKcc20Transfer" ->
                "Recipient ${json.getString("recipient")}\n" +
                    "${json.getLong("amount")} raw ${json.getString("ticker")} · " +
                    "Fee ${json.getLong("feeSompi")} sompi"
            "signReveal" ->
                "Recipient ${json.getString("recipient")}\n" +
                    "${json.getString("kind").uppercase()} reveal · " +
                    "Fee ${json.getLong("feeSompi")} sompi"
            "signPolicyTransaction" ->
                "Vault ${json.getString("action")}\n" +
                    "${json.getLong("vaultAmountSompi")} sompi governed by covenant · " +
                    "Fee ${json.getLong("feeSompi")} sompi"
            "signPskt" ->
                "PSKT ${json.getString("transactionId").take(16)}…\n" +
                    "${json.getInt("selectedInputCount")} of ${json.getInt("inputCount")} inputs · " +
                    "${json.getInt("outputCount")} outputs · Fee ${json.getLong("feeSompi")} sompi · " +
                    "${json.getJSONArray("warnings").length()} warning(s)"
            else -> error("Unsupported native review operation")
        }
        synchronized(authorizationLock) {
            val now = System.currentTimeMillis()
            nativeReviewSummaries.entries.removeIf { it.value.expiresAt <= now }
            nativeReviewSummaries[reviewHash] =
                NativeReviewSummary(operation, summary, now + 5 * 60_000L)
        }
        result.success(json.toString())
    }

    private fun resultFromCoreArray(raw: String, result: MethodChannel.Result) {
        if (raw.trimStart().startsWith("{")) parseCore(raw)
        result.success(JSONArray(raw).toString())
    }

    private fun parseCore(raw: String): JSONObject {
        val json = JSONObject(raw)
        if (json.has("error")) error(json.getString("error"))
        return json
    }

    private fun preferences() = getSharedPreferences(preferencesName, MODE_PRIVATE)

    private data class MnemonicBackup(val mnemonic: String, val passphrase: String?)

    private fun encodeMnemonicSecret(mnemonic: String, passphrase: String): String {
        if (passphrase.isEmpty()) return "mnemonic:$mnemonic"
        val encoded = passphrase.toByteArray(Charsets.UTF_8)
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        return "mnemonic-passphrase:$encoded:$mnemonic"
    }

    private fun decodeMnemonicSecret(secret: String): MnemonicBackup {
        if (secret.startsWith("mnemonic:")) {
            return MnemonicBackup(secret.removePrefix("mnemonic:"), null)
        }
        val encoded = secret.removePrefix("mnemonic-passphrase:")
        val separator = encoded.indexOf(':')
        check(separator >= 0) { "Invalid passphrase wallet backup" }
        val passphraseHex = encoded.substring(0, separator)
        check(passphraseHex.length % 2 == 0) { "Invalid passphrase wallet backup" }
        val bytes = ByteArray(passphraseHex.length / 2) { index ->
            passphraseHex.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
        val passphrase = try {
            bytes.toString(Charsets.UTF_8)
        } finally {
            bytes.fill(0)
        }
        return MnemonicBackup(encoded.substring(separator + 1), passphrase)
    }

    private fun walletKey(id: String, field: String) = "wallet_${id}_$field"

    private fun walletIds(): MutableList<String> {
        migrateLegacyWallet()
        val raw = preferences().getString(walletIdsKey, "[]") ?: "[]"
        val array = JSONArray(raw)
        return MutableList(array.length()) { index -> array.getString(index) }
    }

    private fun migrateLegacyWallet() {
        val prefs = preferences()
        if (prefs.contains(walletIdsKey)) return
        if (!prefs.contains(seedCiphertextKey) || !prefs.contains(seedIvKey) || !prefs.contains(addressKey)) {
            prefs.edit().putString(walletIdsKey, "[]").commit()
            return
        }
        val id = UUID.randomUUID().toString()
        prefs.edit()
            .putString(walletKey(id, "ciphertext"), prefs.getString(seedCiphertextKey, null))
            .putString(walletKey(id, "iv"), prefs.getString(seedIvKey, null))
            .putString(walletKey(id, "address"), prefs.getString(addressKey, null))
            .putString(walletKey(id, "name"), "Wallet 1")
            .putString(walletKey(id, "kind"), "native")
            .putString(walletIdsKey, JSONArray(listOf(id)).toString())
            .putString(activeWalletIdKey, id)
            .remove(seedCiphertextKey).remove(seedIvKey).remove(addressKey)
            .commit()
    }

    private fun hasNativeWallet(address: String? = null): Boolean {
        val prefs = preferences()
        return walletIds().any { id ->
            address == null || controlsAddress(id, address)
        }
    }

    private fun hdAddresses(id: String): JSONArray {
        val prefs = preferences()
        val stored = prefs.getString(walletKey(id, "addresses"), null)
        if (stored != null) try {
            return JSONArray(stored)
        } catch (_: Exception) {
            // Reconstruct the historical first-address record below.
        }
        val primary = prefs.getString(walletKey(id, "address"), null) ?: return JSONArray()
        return JSONArray().put(JSONObject().apply {
            put("address", primary)
            put("derivationPath", "m/44'/111111'/0'/0/0")
            put("coinType", 111111)
            put("account", 0)
            put("change", 0)
            put("index", 0)
            put("used", true)
        })
    }

    private fun controlsAddress(id: String, address: String): Boolean {
        if (preferences().getString(walletKey(id, "address"), null) == address) return true
        val addresses = hdAddresses(id)
        return (0 until addresses.length()).any { addresses.getJSONObject(it).optString("address") == address }
    }

    private fun hdPath(id: String, address: String): String? {
        val addresses = hdAddresses(id)
        return (0 until addresses.length())
            .map { addresses.getJSONObject(it) }
            .firstOrNull { it.optString("address") == address }
            ?.optString("derivationPath")
            ?.takeIf { it.startsWith("m/") }
    }

    private fun activeWalletId(): String? {
        val ids = walletIds()
        val active = preferences().getString(activeWalletIdKey, null)
        return if (active != null && ids.contains(active)) active else ids.firstOrNull()
    }

    private fun activeWalletAddress(): String? = activeWalletId()?.let {
        preferences().getString(walletKey(it, "address"), null)
    }

    private fun listWalletsJson(): JSONArray {
        val prefs = preferences()
        val active = activeWalletId()
        return JSONArray().apply {
            walletIds().forEach { id ->
                put(JSONObject().apply {
                    put("id", id)
                    put("address", prefs.getString(walletKey(id, "address"), ""))
                    put("name", prefs.getString(walletKey(id, "name"), "Wallet"))
                    put("kind", prefs.getString(walletKey(id, "kind"), "native"))
                    put("active", id == active)
                    put("addresses", hdAddresses(id))
                })
            }
        }
    }

    private fun selectWallet(id: String) {
        check(walletIds().contains(id)) { "Unknown wallet" }
        preferences().edit().putString(activeWalletIdKey, id).commit()
    }

    private fun renameWallet(id: String, requestedName: String) {
        check(walletIds().contains(id)) { "Unknown wallet" }
        val name = requestedName.trim()
        check(name.isNotEmpty() && name.length <= 40 && !name.any { it.isISOControl() }) {
            "Wallet name must contain 1 to 40 visible characters"
        }
        preferences().edit().putString(walletKey(id, "name"), name).commit()
    }

    private fun storeWallet(secret: String, address: String) {
        val prefs = preferences()
        val ids = walletIds()
        val existing = ids.firstOrNull { id -> prefs.getString(walletKey(id, "address"), null) == address }
        val id = existing ?: UUID.randomUUID().toString().also { ids.add(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, ensureVaultKey())
        val plaintext = secret.toByteArray(Charsets.UTF_8)
        val encrypted = try { cipher.doFinal(plaintext) } finally { plaintext.fill(0) }
        val committed = prefs.edit()
            .putString(walletKey(id, "ciphertext"), Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .putString(walletKey(id, "iv"), Base64.encodeToString(cipher.iv, Base64.NO_WRAP))
            .putString(walletKey(id, "address"), address)
            .putString(walletKey(id, "name"), prefs.getString(walletKey(id, "name"), "Wallet ${ids.indexOf(id) + 1}"))
            .putString(walletKey(id, "kind"), if (secret.startsWith("private:")) "private-key" else "mnemonic")
            .putString(walletKey(id, "addresses"), JSONArray().put(JSONObject().apply {
                put("address", address)
                put("derivationPath", if (secret.startsWith("private:")) "private-key" else "m/44'/111111'/0'/0/0")
                put("coinType", 111111)
                put("account", 0)
                put("change", 0)
                put("index", 0)
            }).toString())
            .putString(activeWalletIdKey, id)
            .putString(walletIdsKey, JSONArray(ids).toString())
            .commit()
        encrypted.fill(0)
        check(committed) { "Android rejected the encrypted wallet write" }
        check(walletIds().contains(id)) { "Encrypted wallet registration was not persisted" }
        check(prefs.getString(walletKey(id, "address"), null) == address) {
            "Stored wallet address verification failed"
        }
        check(prefs.contains(walletKey(id, "ciphertext")) && prefs.contains(walletKey(id, "iv"))) {
            "Stored wallet encryption record verification failed"
        }
    }

    private fun decryptSecret(address: String? = null): String {
        val prefs = preferences()
        val id = if (address == null) activeWalletId() else walletIds().firstOrNull {
            controlsAddress(it, address)
        }
        check(id != null) { "No signing wallet controls this address" }
        val encrypted = Base64.decode(prefs.getString(walletKey(id, "ciphertext"), null), Base64.NO_WRAP)
        val iv = Base64.decode(prefs.getString(walletKey(id, "iv"), null), Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, ensureVaultKey(), GCMParameterSpec(128, iv))
        val plaintext = try { cipher.doFinal(encrypted) } finally { encrypted.fill(0); iv.fill(0) }
        return try {
            val secret = plaintext.toString(Charsets.UTF_8)
            val path = address?.let { hdPath(id, it) }
            if (path != null && path != "m/44'/111111'/0'/0/0") "hd-path:$path:$secret" else secret
        } finally { plaintext.fill(0) }
    }

    private fun registerHdAddresses(raw: String) {
        val id = activeWalletId() ?: error("No active signing wallet")
        val source = JSONArray(raw)
        check(source.length() in 1..2000) { "Invalid HD address list" }
        val secret = decryptSecret()
        val verified = JSONArray()
        for (index in 0 until source.length()) {
            val candidate = source.getJSONObject(index)
            val coinType = candidate.getInt("coinType")
            val account = candidate.optInt("account", 0)
            val change = candidate.getInt("change")
            val addressIndex = candidate.getInt("index")
            val derived = JSONArray(SecureCore.deriveAddresses(secret, coinType, account, change, addressIndex, 1))
                .getJSONObject(0)
            check(derived.getString("address") == candidate.getString("address")) {
                "HD address verification failed"
            }
            derived.put("used", candidate.optBoolean("used", false))
            derived.put("explicit", candidate.optBoolean("explicit", false))
            verified.put(derived)
        }
        preferences().edit().putString(walletKey(id, "addresses"), verified.toString()).commit()
    }

    private fun deleteWallet(requestedId: String? = null) {
        val prefs = preferences()
        val ids = walletIds()
        val id = requestedId ?: activeWalletId() ?: return
        val wasActive = id == activeWalletId()
        check(ids.remove(id)) { "Unknown wallet" }
        prefs.edit()
            .remove(walletKey(id, "ciphertext"))
            .remove(walletKey(id, "iv"))
            .remove(walletKey(id, "address"))
            .remove(walletKey(id, "name"))
            .remove(walletKey(id, "kind"))
            .remove(walletKey(id, "addresses"))
            .putString(walletIdsKey, JSONArray(ids).toString())
            .apply {
                if (ids.isEmpty()) remove(activeWalletIdKey)
                else if (wasActive) putString(activeWalletIdKey, ids.first())
            }
            .commit()
        if (ids.isEmpty()) {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            if (store.containsAlias(vaultAlias)) store.deleteEntry(vaultAlias)
        }
    }

    private fun hasPin(): Boolean = preferences().contains(pinSaltKey) && preferences().contains(pinHashKey)

    private fun verifyUpdateManifest(payloadBase64: String, signatureBase64: String): Boolean {
        return try {
            val payload = Base64.decode(payloadBase64, Base64.NO_WRAP)
            val signatureBytes = Base64.decode(signatureBase64, Base64.NO_WRAP)
            val publicKeyBytes = Base64.decode(updateManifestPublicKey, Base64.NO_WRAP)
            val publicKey = KeyFactory.getInstance("RSA")
                .generatePublic(X509EncodedKeySpec(publicKeyBytes))
            Signature.getInstance("SHA256withRSA").run {
                initVerify(publicKey)
                update(payload)
                verify(signatureBytes)
            }.also {
                payload.fill(0)
                signatureBytes.fill(0)
                publicKeyBytes.fill(0)
            }
        } catch (_: Exception) {
            false
        }
    }

    private val updateManifestPublicKey =
        "MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAmp4KFfshDFHNu8Cf2fZFdgocNGVDjGuXHD0LXcikROMVXumX18+wtL8n6tDA4EN2mKyIGMJFydCFXd8w1LoC2zs/SD10QF4yFmd9AxQ5y44nzQbyimLmLVYK3uHKzxRum8CU/KPwC/aBA1GnQWHsJqDQv55bmXsyEM3eWQ+a/PcPHdNqXpuRkHk8IP+mFxrBCTQ4Y7G299llcCQ5/IL5lOtJqpPb2vdiYrO5IaAE/6kw6bV3ur29Yy2gUWCzGlFhABaWjEzUOqrmCATTfsOhs0tiQY8P2Dvxc1/uHbjwPmOmBDUqZcGGWShbv6hmO2oorCZ5zHCR3LTPxndj0vL6EYuR3u5XYH4camhYieehnvYFJA5RClxlo/BlPzqZqT0K7sREfwfyVUE4GkX7Qq3JN75qHKi1jEVOdGTWg1AQnYRPoUIDmaZZ38Nf4ulZLDzki4/SU3mvstbHvprB8hK3mmsM48il+ihu+4JhO9FE9WT8eyTziD6ZYPqG5c1qr72460/YhMecjJq5GGI3NYl5l7UzR+giEx0hDfYMTW+PQRIYO5q3OBQlDIanX579TjrfrP2+9Jg8ebemZwlCTpxW8iJJBLQqag6GTdO+gtENHJSnaSll6JLzZWK+D+3gcvkLa+52H//YS2RUeVDzkbTkZi/tKh+67DzfCg0I/VcIYx0CAwEAAQ=="

    private fun pinDigest(pin: CharArray, salt: ByteArray): ByteArray {
        val spec = PBEKeySpec(pin, salt, 210_000, 256)
        return try {
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded
        } finally {
            spec.clearPassword()
            pin.fill('\u0000')
        }
    }

    private fun configurePinDialog(result: MethodChannel.Result) {
        val first = EditText(this).apply {
            hint = "4–8 digit PIN"
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
            isSingleLine = true
        }
        val second = EditText(this).apply {
            hint = "Confirm PIN"
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
            isSingleLine = true
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(8), dp(24), 0)
            addView(first)
            addView(second)
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle(if (hasPin()) "Change Kaspire PIN" else "Create Kaspire PIN")
            .setMessage("Use 4–8 digits. After repeated failures Kaspire temporarily locks PIN approval.")
            .setView(content)
            .setNegativeButton("Cancel") { _, _ -> result.success(false) }
            .setPositiveButton("Save PIN", null)
            .setCancelable(false)
            .create()
        dialog.setOnShowListener {
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val one = first.text.toString()
                val two = second.text.toString()
                if (!one.matches(Regex("^[0-9]{4,8}$"))) {
                    first.error = "Enter 4–8 digits"
                    return@setOnClickListener
                }
                if (one != two) {
                    second.error = "PINs do not match"
                    return@setOnClickListener
                }
                val salt = ByteArray(32).also { SecureRandom().nextBytes(it) }
                val hash = pinDigest(one.toCharArray(), salt)
                preferences().edit()
                    .putString(pinSaltKey, Base64.encodeToString(salt, Base64.NO_WRAP))
                    .putString(pinHashKey, Base64.encodeToString(hash, Base64.NO_WRAP))
                    .remove(pinFailuresKey).remove(pinLockedUntilKey)
                    .commit()
                salt.fill(0); hash.fill(0); first.text.clear(); second.text.clear()
                dialog.dismiss()
                result.success(true)
            }
        }
        dialog.show()
    }

    private fun authorizeOperation(
        operation: String,
        binding: String,
        sessionMinutes: Int,
        result: MethodChannel.Result,
    ) {
        check(sessionMinutes == 0 || sessionMinutes == 5 ||
            sessionMinutes == 10 || sessionMinutes == 15) {
            "Invalid authorization session duration"
        }
        val promptText = authorizationPrompt(operation, binding)
        if (promptText == null || binding.isEmpty() || binding.length > 16_384) {
            result.error("INVALID_AUTHORIZATION", "Invalid operation authorization request", null)
            return
        }
        if (operation == "signPersonalMessage") {
            showPersonalMessageReview(
                binding,
                promptText,
                operation,
                result,
                sessionMinutes,
            )
            return
        }
        authorizeAfterNativeReview(
            operation,
            binding,
            promptText,
            result,
            sessionMinutes,
        )
    }

    private fun showPersonalMessageReview(
        binding: String,
        promptText: String,
        operation: String,
        result: MethodChannel.Result,
        sessionMinutes: Int,
    ) {
        val separator = binding.indexOf('\u0000')
        if (separator <= 0 || separator == binding.lastIndex) {
            result.error("INVALID_AUTHORIZATION", "Invalid KIP-5 review binding", null)
            return
        }
        val address = binding.substring(0, separator)
        val message = binding.substring(separator + 1)
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(24), dp(8), dp(24), dp(8))
            addView(TextView(this@MainActivity).apply {
                text = "ADDRESS\n$address"
                setTextIsSelectable(true)
                setPadding(0, 0, 0, dp(16))
            })
            addView(TextView(this@MainActivity).apply {
                text = "MESSAGE\n$message"
                setTextIsSelectable(true)
            })
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Review KIP-5 message")
            .setView(ScrollView(this).apply { addView(content) })
            .setNegativeButton("Cancel") { _, _ -> result.success(null) }
            .setPositiveButton("Continue", null)
            .setCancelable(false)
            .create()
        dialog.setOnShowListener {
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                dialog.dismiss()
                authorizeAfterNativeReview(
                    operation,
                    binding,
                    promptText,
                    result,
                    sessionMinutes,
                )
            }
        }
        dialog.show()
    }

    private fun authorizeAfterNativeReview(
        operation: String,
        binding: String,
        promptText: String,
        result: MethodChannel.Result,
        sessionMinutes: Int,
    ) {
        val sessionActive = sessionMinutes > 0 &&
            System.currentTimeMillis() - lastSessionAuthenticationAtMs <
                sessionMinutes * 60_000L
        if (sessionActive) {
            AlertDialog.Builder(this)
                .setTitle("Review Kaspire operation")
                .setMessage(promptText)
                .setNegativeButton("Cancel") { _, _ -> result.success(null) }
                .setPositiveButton("Approve") { _, _ ->
                    result.success(issueAuthorization(operation, binding))
                }
                .setCancelable(false)
                .create()
                .apply {
                    setOnShowListener {
                        window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    show()
                }
            return
        }
        val pinAvailable = hasPin()
        val authenticators = if (pinAvailable) {
            // A custom negative button cannot be combined with DEVICE_CREDENTIAL.
            // Prefer biometrics and expose the independently rate-limited Kaspire
            // PIN as the explicit fallback instead.
            BiometricManager.Authenticators.BIOMETRIC_STRONG
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
        } else {
            BiometricManager.Authenticators.BIOMETRIC_STRONG
        }
        if (BiometricManager.from(this).canAuthenticate(authenticators) !=
            BiometricManager.BIOMETRIC_SUCCESS
        ) {
            if (pinAvailable) {
                authorizeWithKaspirePin(operation, binding, promptText, result)
            } else {
                authorizeWithDeviceCredential(operation, binding, promptText, result)
            }
            return
        }
        val prompt = BiometricPrompt(
            this,
            ContextCompat.getMainExecutor(this),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(
                    authenticationResult: BiometricPrompt.AuthenticationResult,
                ) {
                    lastSessionAuthenticationAtMs = System.currentTimeMillis()
                    result.success(issueAuthorization(operation, binding))
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    if (pinAvailable &&
                        errorCode == BiometricPrompt.ERROR_NEGATIVE_BUTTON
                    ) {
                        authorizeWithKaspirePin(
                            operation,
                            binding,
                            promptText,
                            result,
                        )
                    } else {
                        result.success(null)
                    }
                }
            },
        )
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Authorize Kaspire")
            .setSubtitle(promptText)
            .setAllowedAuthenticators(authenticators)
            .apply {
                if (pinAvailable) setNegativeButtonText("Use Kaspire PIN")
            }
            .build()
        prompt.authenticate(promptInfo)
    }

    private fun authorizeWithKaspirePin(
        operation: String,
        binding: String,
        promptText: String,
        result: MethodChannel.Result,
    ) {
        verifyPinDialog(promptText, object : MethodChannel.Result {
            override fun success(value: Any?) {
                if (value == true) {
                    lastSessionAuthenticationAtMs = System.currentTimeMillis()
                    result.success(issueAuthorization(operation, binding))
                } else {
                    result.success(null)
                }
            }

            override fun error(code: String, message: String?, details: Any?) =
                result.error(code, message, details)

            override fun notImplemented() = result.notImplemented()
        })
    }

    private fun authorizationPrompt(operation: String, binding: String): String? = when (operation) {
        "signTransaction", "signKcc20Transfer", "signReveal", "signPolicyTransaction", "signPskt" ->
            synchronized(authorizationLock) {
                nativeReviewSummaries[binding]
                    ?.takeIf {
                        it.operation == operation &&
                            it.expiresAt >= System.currentTimeMillis()
                    }
                    ?.text
            }
        "signPersonalMessage" -> "Authorize the KIP-5 address and message shown by Kaspire"
        "exportPrivateKey" -> "Reveal the private key for\n$binding"
        "exportRecoveryPhrase" -> "Reveal this wallet's recovery phrase"
        "exportEncryptedBackup" -> "Export this wallet as an encrypted backup"
        "deleteWallet" -> "Permanently delete this wallet from the device"
        else -> null
    }

    private fun issueAuthorization(operation: String, binding: String): String {
        val token = UUID.randomUUID().toString()
        synchronized(authorizationLock) {
            val now = System.currentTimeMillis()
            operationAuthorizations.entries.removeIf { it.value.expiresAt <= now }
            operationAuthorizations[token] =
                OperationAuthorization(operation, binding, now + authorizationLifetimeMs)
        }
        return token
    }

    private fun authorizeWithDeviceCredential(
        operation: String,
        binding: String,
        promptText: String,
        result: MethodChannel.Result,
    ) {
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        if (!keyguard.isDeviceSecure || pendingDeviceCredentialAuthorization != null) {
            result.error(
                "AUTH_UNAVAILABLE",
                "Configure a Kaspire PIN or secure Android lock screen first",
                null,
            )
            return
        }
        val intent = keyguard.createConfirmDeviceCredentialIntent(
            "Authorize Kaspire",
            promptText,
        )
        if (intent == null) {
            result.error("AUTH_UNAVAILABLE", "Android device credential is unavailable", null)
            return
        }
        pendingDeviceCredentialAuthorization = Triple(operation, binding, result)
        startActivityForResult(intent, deviceCredentialRequestCode)
    }

    @Deprecated("Android activity-result compatibility path for API 26–29")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == deviceCredentialRequestCode) {
            val pending = pendingDeviceCredentialAuthorization
            pendingDeviceCredentialAuthorization = null
            if (pending != null) {
                if (resultCode == RESULT_OK) {
                    lastSessionAuthenticationAtMs = System.currentTimeMillis()
                    pending.third.success(issueAuthorization(pending.first, pending.second))
                } else {
                    pending.third.success(null)
                }
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun requireAuthorization(
        call: io.flutter.plugin.common.MethodCall,
        operation: String,
        binding: String,
    ) {
        val token = call.argument<String>("authorizationToken")
            ?: error("Missing operation authorization")
        val authorization = synchronized(authorizationLock) {
            operationAuthorizations.remove(token)
        } ?: error("Invalid or already consumed operation authorization")
        if (
            authorization.expiresAt < System.currentTimeMillis() ||
            authorization.operation != operation ||
            !MessageDigest.isEqual(
                authorization.binding.toByteArray(Charsets.UTF_8),
                binding.toByteArray(Charsets.UTF_8),
            )
        ) {
            error("Operation authorization does not match this request")
        }
        if (operation in setOf("signTransaction", "signKcc20Transfer", "signReveal")) {
            synchronized(authorizationLock) {
                nativeReviewSummaries.remove(binding)
            }
        }
    }

    private fun verifyPinDialog(reason: String, result: MethodChannel.Result) {
        if (!hasPin()) { result.success(false); return }
        val prefs = preferences()
        val now = System.currentTimeMillis()
        val lockedUntil = prefs.getLong(pinLockedUntilKey, 0L)
        if (lockedUntil > now) {
            result.error("PIN_LOCKED", "PIN locked for ${(lockedUntil - now + 999) / 1000} seconds", null)
            return
        }
        val input = EditText(this).apply {
            hint = "Kaspire PIN"
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD
            isSingleLine = true
            setPadding(dp(24), dp(12), dp(24), dp(12))
        }
        val dialog = AlertDialog.Builder(this)
            .setTitle("Authorize with PIN")
            .setMessage(reason)
            .setView(input)
            .setNegativeButton("Cancel") { _, _ -> result.success(false) }
            .setPositiveButton("Authorize", null)
            .setCancelable(false)
            .create()
        dialog.setOnShowListener {
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val entered = input.text.toString()
                if (!entered.matches(Regex("^[0-9]{4,8}$"))) {
                    input.error = "Enter your 4–8 digit PIN"
                    return@setOnClickListener
                }
                val salt = Base64.decode(prefs.getString(pinSaltKey, null), Base64.NO_WRAP)
                val expected = Base64.decode(prefs.getString(pinHashKey, null), Base64.NO_WRAP)
                val actual = pinDigest(entered.toCharArray(), salt)
                val valid = MessageDigest.isEqual(expected, actual)
                salt.fill(0); expected.fill(0); actual.fill(0); input.text.clear()
                if (valid) {
                    prefs.edit().remove(pinFailuresKey).remove(pinLockedUntilKey).commit()
                    dialog.dismiss()
                    result.success(true)
                } else {
                    val failures = prefs.getInt(pinFailuresKey, 0) + 1
                    val editor = prefs.edit().putInt(pinFailuresKey, failures)
                    if (failures >= 5) {
                        val exponent = (failures - 5).coerceAtMost(5)
                        val seconds = (30L shl exponent).coerceAtMost(900L)
                        editor.putLong(pinLockedUntilKey, System.currentTimeMillis() + seconds * 1000)
                        editor.commit()
                        dialog.dismiss()
                        result.error("PIN_LOCKED", "Too many attempts. PIN locked for $seconds seconds", null)
                    } else {
                        editor.commit()
                        input.error = "Incorrect PIN · ${5 - failures} attempts before lock"
                    }
                }
            }
        }
        dialog.show()
    }

    private fun clearPin() {
        preferences().edit()
            .remove(pinSaltKey).remove(pinHashKey)
            .remove(pinFailuresKey).remove(pinLockedUntilKey)
            .commit()
    }

    private fun ensureVaultKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(vaultAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        return try {
            generator.init(keySpec(strongBox = Build.VERSION.SDK_INT >= Build.VERSION_CODES.P))
            generator.generateKey()
        } catch (_: Exception) {
            if (store.containsAlias(vaultAlias)) store.deleteEntry(vaultAlias)
            generator.init(keySpec(strongBox = false))
            generator.generateKey()
        }
    }

    private fun keySpec(strongBox: Boolean): KeyGenParameterSpec {
        val builder = KeyGenParameterSpec.Builder(vaultAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .setKeySize(256)
        // Authentication is enforced immediately before import, export and signing by
        // AndroidX Biometric. Avoiding auth-bound Cipher.init fixes incompatible OEM
        // Keystore implementations while the secret remains hardware-encrypted at rest.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) builder.setIsStrongBoxBacked(strongBox)
        return builder.build()
    }

    private fun isHardwareBacked(): Boolean {
        val key = ensureVaultKey()
        val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java) as KeyInfo
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            info.securityLevel == KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT || info.securityLevel == KeyProperties.SECURITY_LEVEL_STRONGBOX
        } else @Suppress("DEPRECATION") info.isInsideSecureHardware
    }
}
