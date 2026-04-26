# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**

# Keep all classes in our app package
-keep class com.cablebee.** { *; }

# Keep native method names (JNI)
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep ProcessBuilder / Runtime.exec (used for adb binary)
-keep class java.lang.Process { *; }
-keep class java.lang.ProcessBuilder { *; }
-keep class java.lang.Runtime { *; }

# AndroidX + USB
-keep class androidx.core.content.FileProvider { *; }
-keep class android.hardware.usb.** { *; }

# Kotlin coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# OkHttp / http package
-dontwarn okhttp3.**
-dontwarn okio.**
-keepnames class okhttp3.internal.publicsuffix.PublicSuffixDatabase

# Gson / JSON
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn sun.misc.**

# Archive library
-keep class org.apache.commons.compress.** { *; }
-dontwarn org.apache.commons.**

# General
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Google Play Core (referenced by Flutter split AOT; not present in non-Play builds)
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }
