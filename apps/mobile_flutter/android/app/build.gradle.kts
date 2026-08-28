plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "space.kasvault.wallet"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    val uploadStoreFile = System.getenv("KASPIRE_UPLOAD_STORE_FILE")
    val uploadPasswordFile = System.getenv("KASPIRE_UPLOAD_PASSWORD_FILE")
    val uploadKeyAlias = System.getenv("KASPIRE_UPLOAD_KEY_ALIAS")
    val hasUploadSigning =
        !uploadStoreFile.isNullOrBlank() &&
            !uploadPasswordFile.isNullOrBlank() &&
            !uploadKeyAlias.isNullOrBlank()

    signingConfigs {
        if (hasUploadSigning) {
            create("playUpload") {
                val uploadPassword = file(uploadPasswordFile!!).readText().trim()
                storeFile = file(uploadStoreFile!!)
                storePassword = uploadPassword
                keyAlias = uploadKeyAlias
                keyPassword = uploadPassword
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "space.kaspire.wallet"
        // Android 11 through Android 16. Requiring API 30 removes the
        // incompatible pre-30 BiometricPrompt authenticator combinations.
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // The security core must exist for every advertised ABI. Excluding
            // x86_64 prevents an emulator-only Flutter slice from installing
            // without the native wallet/signing library.
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    buildTypes {
        release {
            // Google Play builds provide the upload-key environment variables.
            // F-Droid intentionally builds an unsigned release and signs the
            // resulting APK inside its own controlled signing infrastructure.
            if (hasUploadSigning) {
                signingConfig = signingConfigs.getByName("playUpload")
            }
            // Keep the public Mainnet test build unminified. This also preserves
            // the JNI boundary and avoids a memory-heavy R8 pass on CI.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        jniLibs {
            // Some Flutter plugins bundle emulator libraries independently of
            // target-platform. Do not let partial x86_64 contents advertise an
            // ABI for which Kaspire's Rust security core is not shipped.
            excludes += setOf("lib/x86_64/**")
            // Rust workspace helper crates also declare cdylib targets, but
            // libkaspa_secure_core links them statically and has no DT_NEEDED
            // entry for these hashed helper files.
            excludes += setOf("**/libworkflow_*.so")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter { source = "../.." }

configurations.configureEach {
    resolutionStrategy {
        // Tangem SDK 3.9.2 calls BroadcastChannel.asFlow(), which remained
        // binary-compatible through Coroutines 1.8.1 and was removed in 1.9.0.
        // Modern Kaspire dependencies require at least 1.7.x, making 1.8.1 the
        // common compatible release without downgrading to Tangem's old 1.3.9.
        force("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
        force("org.jetbrains.kotlinx:kotlinx-coroutines-core-jvm:1.8.1")
        force("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
        force("org.jetbrains.kotlinx:kotlinx-coroutines-jdk8:1.8.1")
    }
}

dependencies {
    implementation("androidx.biometric:biometric:1.1.0")
    // Fixed official Tangem SDK release. The rescue flow sends only locally
    // verified Kaspa ECDSA sighashes to the card; no private key is exported.
    implementation("com.github.Tangem:tangem-sdk-android:3.9.2")
}
