plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.FileInputStream
import java.util.Properties

// fplayer-core (IJK)：flv_lzc 把 AAR 放在自己的 android/libs/ 里，但 Gradle 解析
// :app 的 releaseRuntimeClasspath 时只用 :app 自己的仓库，不会去看插件的仓库，
// 所以构建找不到 io.github.flutterplayer:fplayer-core:1.0.4-purelive16k。
// AAR 和 .pom 已放到仓库内的 android/maven-repo，这里声明成本地 Maven 仓库。
repositories {
    maven {
        url = uri("../maven-repo")
    }
}

// Release signing: values come from android/key.properties, which is
// generated on the build machine from Codemagic environment variables
// (ANDROID_KEYSTORE_BASE64 / ANDROID_KEYSTORE_PASSWORD /
// ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD). No secret is ever stored
// in this file or in git (key.properties is gitignored). Without
// key.properties (local dev) release falls back to the debug key.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.haostudio.standalone"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    defaultConfig {
        applicationId = "com.haostudio.standalone"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // minSdk 24 / targetSdk 36 / compileSdk 36 are the Flutter 3.47
        // template defaults (flutter.minSdkVersion etc.) — they match the
        // plugin floor (better_player_plus, audio_session and
        // url_launcher_android all require minSdk 24).
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // Local dev without key.properties: debug keys, so
                // `flutter run --release` still works.
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
