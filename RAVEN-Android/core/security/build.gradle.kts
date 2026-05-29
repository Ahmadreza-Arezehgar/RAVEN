plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

android {
    namespace = "app.raven.core.security"
    compileSdk = 35
    defaultConfig {
        minSdk = 26
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    api(project(":core:network"))
    implementation(libs.androidx.security.crypto)
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlin.coroutines)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    // BouncyCastle — Ed25519 + X25519 + (future Phase 2d) ChaCha20-Poly1305
    // for the iOS-compatible Noise IK transport. AndroidKeyStore on
    // minSdk 26 only supports RSA + EC P-256/384 keys, so we keep
    // the Curve25519 keypair material in app-managed bytes inside
    // SecureStore (which is already Keystore-fenced).
    implementation(libs.bouncycastle.bcprov)
}
