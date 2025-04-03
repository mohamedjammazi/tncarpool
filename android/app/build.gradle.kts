plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin") // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("com.google.gms.google-services") // ✅ Ensure Google Services plugin is here
}

android {
    namespace = "com.example.carpooling_app"
    compileSdk = 35 // ✅ Set a fixed value or use `flutter.compileSdkVersion`

    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.example.carpooling_app"
        minSdk = 24 // ✅ Correct syntax
        targetSdk = 35 // ✅ Set a fixed value or use `flutter.targetSdkVersion`
        versionCode = 1 // ✅ Set an integer
        versionName = "1.0.0" // ✅ Set a string
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
