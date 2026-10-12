// `import` must be the very first thing in a .gradle.kts script.
//
// Without it, `java.util.Properties()` does not compile: in a Gradle Kotlin DSL
// script the bare name `java` resolves to the `JavaPluginExtension` that the
// Android plugin registers, which shadows the `java` package. The error is
// "Unresolved reference: util", which points at the wrong thing entirely.
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

// --------------------------------------------------------------------------- //
// Release signing
// --------------------------------------------------------------------------- //
//
// Signing configuration, looked for in two places.
//
// Locally the file lives one level UP, outside the repository, so it cannot be committed even
// by accident. In CI there is no "one level up" — the workflow writes it into the checkout from
// repository secrets, where `.gitignore` keeps it out of the commit.
//
// The filename is project-specific on purpose. A shared `keystore.properties` would sign this
// app with an unrelated app's key, permanently linking their signing identities.
//
// When neither file exists the release build produces an *unsigned* APK instead of failing.
// That is deliberate: a project that cannot build without a secret is a project nobody can
// contribute to.
val keystorePropertiesFile = listOf(
    rootProject.file("../photolog-keystore.properties"),
    rootProject.file("photolog-keystore.properties"),
).firstOrNull { it.exists() }
val hasReleaseSigning = keystorePropertiesFile != null
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile != null) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

/**
 * Reads a required signing property.
 *
 * The error message names the BOM trap on purpose. Java's `Properties.load()`
 * does not strip a UTF-8 byte-order mark, so a `keystore.properties` written by a
 * tool that adds one has its **first** key silently renamed to `\uFEFFstoreFile`.
 */
fun signingProperty(name: String): String =
    keystoreProperties.getProperty(name)
        ?: error(
            "keystore.properties has no `$name` key. If the file visibly contains it, " +
                "the file was written with a UTF-8 BOM: Properties.load() keeps the BOM " +
                "in the first key name. Rewrite it as UTF-8 WITHOUT a BOM.",
        )

android {
    namespace = "io.photolog.android"
    compileSdk = 35

    // Pinned explicitly. AGP 8.7's implicit default here is 34.0.0, which is not
    // what a fresh SDK install brings in.
    buildToolsVersion = "35.0.0"

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(signingProperty("storeFile"))
                storePassword = signingProperty("storePassword")
                keyAlias = signingProperty("keyAlias")
                keyPassword = signingProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = "io.photolog.android"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

ksp {
    // Emit the Room schema next to the sources so schema drift shows up in review
    // instead of only in a runtime crash on someone else's device.
    arg("room.schemaLocation", "$projectDir/schemas")
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.core.splashscreen)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.navigation.compose)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons.extended)

    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)

    implementation(libs.androidx.datastore.preferences)

    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)

    implementation(libs.androidx.exifinterface)

    implementation(libs.kotlinx.coroutines.android)

    implementation(libs.coil.compose)

    debugImplementation(libs.androidx.compose.ui.tooling)

    // The export planner and the caption-document builder are pure functions over the photo
    // list, so the ordering contract — the one thing about this app that cannot be checked by
    // looking at it — is verified on the JVM instead of on a device.
    testImplementation(libs.junit)
}
