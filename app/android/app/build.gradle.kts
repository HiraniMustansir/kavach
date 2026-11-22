import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "app.kavach"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.kavach"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26 // Android 8.0 (PRD §8 device support)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // One config source for Flutter (--dart-define-from-file) and the native agent: repo-root .env
        val env = Properties().apply { rootProject.file("../../.env").takeIf { it.exists() }?.inputStream()?.use { load(it) } }
        buildConfigField("String", "SUPABASE_URL", "\"${env.getProperty("SUPABASE_URL", "")}\"")
        buildConfigField("String", "SUPABASE_KEY", "\"${env.getProperty("SUPABASE_PUBLISHABLE_KEY", "")}\"")
    }

    buildFeatures { buildConfig = true }

    buildTypes {
        release {
            // shortcut: debug signing; Tier A provisioning needs the real release key's checksum (README).
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

// Firebase is optional: without google-services.json the app builds and runs, push just stays off.
if (file("google-services.json").exists()) apply(plugin = "com.google.gms.google-services")

dependencies {
    implementation("net.zetetic:sqlcipher-android:4.6.1@aar")
    implementation("androidx.sqlite:sqlite:2.4.0")
    implementation("com.google.ai.edge.litert:litert:1.0.1")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    // Our FCM service subclasses the plugin's; same BoM as firebase_core so versions match.
    implementation(platform("com.google.firebase:firebase-bom:35.2.0"))
    implementation("com.google.firebase:firebase-messaging")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303") // real org.json on the JVM (Android's is a stub in unit tests)
}
