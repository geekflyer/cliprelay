import org.gradle.api.GradleException
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.github.triplet.play")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("keystore.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

fun signingValue(propertyKey: String, envKey: String): String? {
    val value = keystoreProperties.getProperty(propertyKey) ?: System.getenv(envKey)
    return value?.trim()?.takeIf { it.isNotEmpty() }
}

val releaseStoreFile = signingValue("storeFile", "CLIPRELAY_STORE_FILE")
val releaseStorePassword = signingValue("storePassword", "CLIPRELAY_STORE_PASSWORD")
val releaseKeyAlias = signingValue("keyAlias", "CLIPRELAY_KEY_ALIAS")
val releaseKeyPassword = signingValue("keyPassword", "CLIPRELAY_KEY_PASSWORD")

val releaseSigningValues = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword
)

val releaseSigningConfigured = releaseSigningValues.all { it != null }
val releaseSigningPartiallyConfigured = releaseSigningValues.any { it != null } && !releaseSigningConfigured

if (releaseSigningPartiallyConfigured) {
    throw GradleException(
        "Incomplete Android release signing configuration. " +
            "Provide all values in android/keystore.properties (storeFile, storePassword, keyAlias, keyPassword) " +
            "or via CLIPRELAY_STORE_FILE, CLIPRELAY_STORE_PASSWORD, CLIPRELAY_KEY_ALIAS, CLIPRELAY_KEY_PASSWORD."
    )
}

val playProperties = Properties()
val playPropertiesFile = rootProject.file("play.properties")
if (playPropertiesFile.exists()) {
    playPropertiesFile.inputStream().use { playProperties.load(it) }
}

fun playValue(propertyKey: String, envKey: String): String? {
    val value = playProperties.getProperty(propertyKey) ?: System.getenv(envKey)
    return value?.trim()?.takeIf { it.isNotEmpty() }
}

val playServiceAccountFile = playValue("serviceAccountCredentials", "PLAY_SERVICE_ACCOUNT_JSON")
val playTrack = playValue("track", "PLAY_TRACK") ?: "internal"

android {
    namespace = "org.cliprelay"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.cliprelay"
        minSdk = 31
        targetSdk = 36
        versionCode = 1  // Auto-incremented by Play plugin's resolutionStrategy
        versionName = file("../VERSION").readText().trim()

        val gitHash = providers.exec {
            commandLine("git", "rev-parse", "--short", "HEAD")
        }.standardOutput.asText.get().trim()
        buildConfigField("String", "GIT_HASH", "\"$gitHash\"")
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFile!!)
                storePassword = releaseStorePassword!!
                keyAlias = releaseKeyAlias!!
                keyPassword = releaseKeyPassword!!
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

}

play {
    defaultToAppBundles.set(true)
    track.set(playTrack)
    resolutionStrategy.set(com.github.triplet.gradle.androidpublisher.ResolutionStrategy.AUTO)

    if (playServiceAccountFile != null) {
        serviceAccountCredentials.set(rootProject.file(playServiceAccountFile))
    }
}

gradle.taskGraph.whenReady {
    val releaseTaskRequested = allTasks.any { task ->
        task.project == project && task.name.contains("Release", ignoreCase = true)
    }

    val playPublishTaskRequested = allTasks.any { task ->
        task.project == project && (
            task.name.contains("publish", ignoreCase = true) ||
                task.name.contains("promote", ignoreCase = true)
            )
    }

    if (releaseTaskRequested && !releaseSigningConfigured) {
        throw GradleException(
            "Android release signing is not configured. " +
                "Create android/keystore.properties (storeFile, storePassword, keyAlias, keyPassword) " +
                "or set CLIPRELAY_STORE_FILE, CLIPRELAY_STORE_PASSWORD, CLIPRELAY_KEY_ALIAS, CLIPRELAY_KEY_PASSWORD."
        )
    }

    if (playPublishTaskRequested) {
        if (playServiceAccountFile == null) {
            throw GradleException(
                "Google Play publishing credentials are not configured. " +
                    "Create android/play.properties with serviceAccountCredentials=<path-to-json> " +
                    "or set PLAY_SERVICE_ACCOUNT_JSON."
            )
        }

        val credentialsFile = rootProject.file(playServiceAccountFile)
        if (!credentialsFile.exists()) {
            throw GradleException(
                "Google Play service account file not found at ${credentialsFile.path}."
            )
        }
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.08.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.9.3")

    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.activity:activity-ktx:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
