import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Flutter's `target-platform` names and the Android ABI each one builds.
val flutterAbis = mapOf(
    "android-arm" to "armeabi-v7a",
    "android-arm64" to "arm64-v8a",
    "android-x64" to "x86_64",
)

android {
    namespace = "com.thenex.nex_music"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Keep the APK small to share and install on phones with little space.
    packaging {
        jniLibs {
            // Compress native libraries inside the APK; Android unpacks them
            // on install.
            useLegacyPackaging = true
            // `--target-platform android-arm64` only ships Flutter's own
            // libraries for that ABI, so drop plugin libraries for the rest.
            val targetAbis = (findProperty("target-platform") as String?)
                ?.split(",")
                ?.mapNotNull { flutterAbis[it] }
            if (targetAbis != null) {
                excludes += (flutterAbis.values - targetAbis.toSet()).map { "lib/$it/**" }
            }
        }
        resources {
            // Protocol buffer sources, Kotlin reflection metadata and build
            // metadata are not read at runtime.
            excludes += listOf(
                "google/**/*.proto",
                "kotlin/**",
                "DebugProbesKt.bin",
                "META-INF/*.version",
                "META-INF/*.kotlin_module",
                "META-INF/LICENSE*",
                "META-INF/NOTICE*",
                "META-INF/DEPENDENCIES*",
                "kotlin-tooling-metadata.json",
            )
        }
    }

    androidResources {
        // All app text is English, so library translations are not needed.
        localeFilters += "en"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.thenex.nex_music"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = if (keystorePropertiesFile.exists() &&
                keystoreProperties.getProperty("storeFile")?.let { file(it).exists() } == true
            ) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// nexMusic plays plain audio and video files. The audio and video plugins also
// pull in ExoPlayer's streaming formats (DASH, HLS, RTSP, SmoothStreaming), so
// leave them out to reduce APK size. The app refuses streaming links
// before they reach a player.
configurations.configureEach {
    exclude(group = "androidx.media3", module = "media3-exoplayer-dash")
    exclude(group = "androidx.media3", module = "media3-exoplayer-hls")
    exclude(group = "androidx.media3", module = "media3-exoplayer-rtsp")
    exclude(group = "androidx.media3", module = "media3-exoplayer-smoothstreaming")
}

dependencies {
    implementation("com.google.mlkit:translate:17.0.3")
    implementation("com.google.mlkit:language-id:17.0.6")
    implementation("com.google.android.gms:play-services-cast-framework:22.1.0")
}
