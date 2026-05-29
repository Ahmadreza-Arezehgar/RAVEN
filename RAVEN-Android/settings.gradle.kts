// 🔴 Round 7 (2026-05-19) — Android project bootstrap.
//
// Goal: pixel-perfect port of the iOS Swift RAVEN app to Android.
// This is Phase 0 (Foundation only) — modules, design system, network,
// storage, security. Auth and feature screens come in subsequent rounds.
//
// Architecture: multi-module Gradle.
//   :app                — entrypoint, MainActivity, navigation graph
//   :core:design        — color / typography / shape / spacing
//                         tokens that mirror iOS DS.* values
//   :core:network       — Retrofit + OkHttp + auth interceptor
//   :core:storage       — Room (SQLCipher) + DataStore
//   :core:security      — Android Keystore wrapper (iOS Keychain twin)
//
// Picking the same minSdk as a real BLE-peripheral capable Android:
//   26 = Android 8.0 Oreo — required for BluetoothLeAdvertiser
//   support, foreground services with type, and a sane Compose
//   baseline. Below that we can't run mesh peripheral anyway.

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// foojay-resolver tells Gradle where to download JDK toolchains.
// Required for the daemon auto-provisioning declared in
// gradle/gradle-daemon-jvm.properties.
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.10.0"
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "RAVEN-Android"

include(
    ":app",
    ":core:design",
    ":core:network",
    ":core:storage",
    ":core:security",
    ":feature:auth",
    ":feature:shell",
    ":feature:chat",
    ":feature:feed",
    ":feature:profile",
    ":feature:discover",
    ":feature:notifications",
    ":feature:e2ee",
    ":feature:groups",
)
