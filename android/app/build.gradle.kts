import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
// Release signing: reads ~/.drawplay-release/keystore.properties (storeFile, storePassword, keyAlias, keyPassword).
// The key stays outside the repository. Without it (for example in a fork) the release build is signed with the debug key.
val signingProps = Properties().apply {
    val f = File(System.getProperty("user.home"), ".drawplay-release/keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "dev.drawplay"
    compileSdk = 36
    defaultConfig { applicationId = "dev.drawplay"; minSdk = 29; targetSdk = 36; versionCode = 3; versionName = "0.3.0" }
    signingConfigs {
        if (signingProps.isNotEmpty()) create("release") {
            storeFile = File(signingProps.getProperty("storeFile"))
            storePassword = signingProps.getProperty("storePassword")
            keyAlias = signingProps.getProperty("keyAlias")
            keyPassword = signingProps.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (signingProps.isNotEmpty()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
