import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

android {
    namespace = "app.raven"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.raven"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables.useSupportLibrary = true

        // ── OAuth wiring (per-machine, NOT committed) ──
        // Read from local.properties so production credentials never
        // hit version control. Defaults to a clearly-broken sentinel
        // so a forgotten config fails loudly at runtime instead of
        // misbehaving silently.
        val localProps = Properties()
        val localPropsFile = rootProject.file("local.properties")
        if (localPropsFile.exists()) {
            localPropsFile.inputStream().use { stream -> localProps.load(stream) }
        }
        val googleWebClientId: String =
            localProps.getProperty("raven.google.webClientId")
                ?: "REPLACE_WITH_GOOGLE_WEB_CLIENT_ID"
        val appleServicesId: String =
            localProps.getProperty("raven.apple.servicesId")
                ?: "REPLACE_WITH_APPLE_SERVICES_ID"
        val appleRedirectUri: String =
            localProps.getProperty("raven.apple.redirectUri")
                ?: "https://raven-server-516053629173.europe-west1.run.app/api/auth/oauth/apple/callback"

        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"$googleWebClientId\"")
        buildConfigField("String", "APPLE_SERVICES_ID", "\"$appleServicesId\"")
        buildConfigField("String", "APPLE_REDIRECT_URI", "\"$appleRedirectUri\"")
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Sign config is configured by the release build pipeline,
            // not committed here.
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    implementation(project(":core:design"))
    implementation(project(":core:network"))
    implementation(project(":core:security"))
    implementation(project(":core:storage"))
    implementation(project(":feature:auth"))
    implementation(project(":feature:chat"))
    implementation(project(":feature:feed"))
    implementation(project(":feature:profile"))
    implementation(project(":feature:discover"))
    implementation(project(":feature:notifications"))
    implementation(project(":feature:shell"))
    // Phase 2f: RootViewModel touches PrekeyBundleService + the
    // PrekeyRotationScheduler directly. These flow in transitively
    // through :feature:chat -> :feature:e2ee, but `implementation` is
    // not transitive on the compile classpath — KSP needs the symbol
    // here to bind the @Inject constructor.
    implementation(project(":feature:e2ee"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.material)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)
    debugImplementation(libs.androidx.compose.ui.tooling)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.navigation.compose)

    implementation(libs.hilt.android)
    implementation(libs.hilt.navigation.compose)
    ksp(libs.hilt.compiler)

    implementation(libs.coil.compose)
    implementation(libs.kotlin.coroutines)
    // Pre-existing NoiseSession.kt + RumProtocolV2.kt protocol stubs
    // pull in BouncyCastle for ChaCha20-Poly1305 + X25519.
    implementation(libs.bouncycastle.bcprov)

    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
