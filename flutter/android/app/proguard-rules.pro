# ============================================================
# Media Nest — Android R8/ProGuard rules
# Flutter 3.22+ enables R8 by default for release builds via
# FlutterPlugin.kt's shouldShrinkResources() → true.
# The Flutter Gradle plugin auto-applies this file when it exists.
# ============================================================

# --- Flutter embedding (belt-and-suspenders on top of flutter_proguard_rules.pro) ---
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# --- App-specific classes referenced only from AndroidManifest.xml meta-data ---
# R8 cannot see class references inside <meta-data android:value="..."> strings.
-keep class com.medianest.app.CastOptionsProvider { *; }
-keep class com.medianest.app.BackgroundKeepAliveService { *; }

# --- FFmpeg Kit (ffmpeg_kit_flutter_new_min) ---
# The plugin uses proguardFiles (library-local) not consumerProguardFiles,
# so these rules do NOT propagate to the consuming app automatically.
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-dontwarn com.antonkarpenko.ffmpegkit.**
-keepclasseswithmembernames class * { native <methods>; }
-keepattributes *Annotation*
-keepattributes Signature
-keepattributes InnerClasses

# --- Cast SDK (com.google.android.gms:play-services-cast-framework) ---
-keep class com.google.android.gms.cast.** { *; }
-keep class com.google.android.gms.cast.framework.** { *; }
-dontwarn com.google.android.gms.cast.**
-dontwarn com.google.android.gms.cast.framework.**

# --- MediaRouter ---
-keep class androidx.mediarouter.** { *; }
-dontwarn androidx.mediarouter.**

# --- photo_manager (uses reflection for media queries) ---
-keep class com.fluttercandies.photo_manager.** { *; }
-dontwarn com.fluttercandies.photo_manager.**

# --- video_player_android (ExoPlayer) ---
-keep class com.google.android.exoplayer2.** { *; }
-dontwarn com.google.android.exoplayer2.**
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# --- General: keep all native JNI method bindings ---
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
