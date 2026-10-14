// Module build file for the SecurityCam Android app.
// minSdk 21 (Android 5.0) so old spare phones work; target/compile on modern SDKs.

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.securitycam"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.example.securitycam"
        minSdk = 21
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            // Debug signing keeps CI simple; replace with your own keystore
            // before distributing outside your household.
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    // Only AndroidX core libs — no camera/server third-party dependencies.
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("androidx.core:core-ktx:1.13.1")
}
