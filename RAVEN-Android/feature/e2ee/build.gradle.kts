plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

android {
    namespace = "app.raven.feature.e2ee"
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
    api(project(":core:security"))
    implementation(project(":core:network"))
    implementation(project(":core:storage"))

    implementation(libs.kotlin.coroutines)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.retrofit)
    implementation(libs.androidx.core.ktx)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    // Phase 2f SPK rotation runs on WorkManager. We use the plain
    // androidx.work runtime (CoroutineWorker) and pull dependencies
    // through Hilt's EntryPointAccessors at worker-run time — no
    // @HiltWorker assisted-injection plumbing needed. Trades a tiny
    // run-time DI lookup for one fewer ksp processor + no manifest
    // edits to disable the default WorkManagerInitializer.
    implementation(libs.androidx.work.runtime)
    implementation(libs.bouncycastle.bcprov)
}
