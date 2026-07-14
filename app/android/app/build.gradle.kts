import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Brick 10: upload-key credentials for the Play Store build.
//
// key.properties is gitignored and the .jks it points at lives outside the repo,
// so a fresh clone won't have either. We therefore treat the key as OPTIONAL at
// configure time — otherwise `flutter build apk --debug` would fail on any
// machine without the signing key. Release builds still hard-fail below if the
// key is missing, so an unsigned/debug-signed AAB can never reach Play by
// accident.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}
val hasUploadKey = keystorePropertiesFile.exists()

android {
    namespace = "com.jobhuntagent.jobhunt_agent"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Permanent — Play identifies the app by this forever, and it is baked into
        // google-services.json (FCM) and the Supabase OAuth redirect scheme in
        // AndroidManifest.xml. Changing it means shipping a different app.
        applicationId = "com.jobhuntagent.jobhunt_agent"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storePassword = keystoreProperties.getProperty("storePassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
            }
        }
    }

    buildTypes {
        release {
            if (hasUploadKey) {
                signingConfig = signingConfigs.getByName("release")
            }
            // R8: strip unused code and resources, and obfuscate. Flutter, Firebase
            // and the plugins ship their own consumer ProGuard rules; proguard-rules.pro
            // holds only what those don't cover.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

// Fail loudly rather than quietly emitting a debug-signed release that Play will
// reject at upload (or worse, that ships unsigned to a tester).
gradle.taskGraph.whenReady {
    val buildingRelease = allTasks.any { it.name.contains("Release") }
    if (buildingRelease && !hasUploadKey) {
        throw GradleException(
            "Release build requested but android/key.properties is missing. " +
                "Restore it from your password manager (see docs/PLAY_CONSOLE.md).",
        )
    }
}

flutter {
    source = "../.."
}
