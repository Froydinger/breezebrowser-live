plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}
android {
    namespace = "com.froydinger.breeze"
    compileSdk { version = release(37) { minorApiLevel = 1 } }
    defaultConfig {
        applicationId = "com.froydinger.breeze"
        minSdk = 29
        targetSdk = 36
        ndk { abiFilters += "arm64-v8a" }
        versionCode = 5
        versionName = "0.1.4"
    }
    buildTypes {
        debug {
            applicationIdSuffix = ".dev"; versionNameSuffix = "-dev"
            val tokenFile = rootProject.file("../cloudflare/breeze-chat-worker/.breeze-client-token")
            val token = if (tokenFile.exists()) tokenFile.readText().trim() else ""
            require(token.matches(Regex("[A-Za-z0-9._~+/=-]*"))) { "Invalid local development credential format" }
            buildConfigField("String", "CLOUD_TOKEN", "\"$token\"")
            buildConfigField("String", "CLOUD_URL", "\"https://breeze-chat.jakefroydinger.workers.dev/v1/mobile/responses\"")
        }
        release {
            isMinifyEnabled = false
            val tokenFile = rootProject.file("../cloudflare/breeze-chat-worker/.breeze-client-token")
            require(tokenFile.exists()) { "Local Breeze Cloud client credential required for release" }
            val token = tokenFile.readText().trim()
            require(token.matches(Regex("[A-Za-z0-9._~+/=-]+"))) { "Invalid local client credential format" }
            buildConfigField("String", "CLOUD_TOKEN", "\"$token\"")
            buildConfigField("String", "CLOUD_URL", "\"https://breeze-chat.jakefroydinger.workers.dev/v1/mobile/responses\"")
        }
    }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    buildFeatures { compose = true; buildConfig = true }
    packaging { resources.excludes += "/META-INF/{AL2.0,LGPL2.1}" }
}
dependencies {
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.fragment:fragment-ktx:1.8.9")
    implementation("androidx.webkit:webkit:1.15.0")
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("org.mozilla.geckoview:geckoview:156.0.20260921121718")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    testImplementation("junit:junit:4.13.2")
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }
