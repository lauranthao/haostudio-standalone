# HAo Studio — R8 keep rules for WorkManager / Room.
#
# better_player_plus 1.4.1 pulls in androidx.work:work-runtime:2.10.5.
# WorkManager auto-inits at startup via androidx.startup.InitializationProvider
# and builds its Room database reflectively (Class.getDeclaredConstructor on
# WorkDatabase_Impl). The Flutter Gradle plugin turns R8 minify ON for release
# builds by default (FlutterPlugin.kt:218), and R8 strips the generated Impl's
# no-arg constructor — the app then dies on launch, before any Dart code runs:
#   java.lang.RuntimeException: Unable to get provider
#   androidx.startup.InitializationProvider: NoSuchMethodException:
#   androidx.work.impl.WorkDatabase_Impl.<init> []
# Proven by the real crash log, GitHub Actions run #3, 2026-11-19.
# better_player_plus ships consumer-rules.pro, but it only keeps its own
# classes + Media3 — nothing keeps androidx.work / Room.
#
# These rules keep the generated Room implementation and everything
# WorkManager needs to construct it. Do NOT remove them while
# better_player_plus (or any other plugin) still depends on work-runtime.
-keep class androidx.work.impl.WorkDatabase_Impl { <init>(...); }
-keep class androidx.work.impl.WorkDatabase { *; }
-keep class * extends androidx.room.RoomDatabase { *; }
-keep class androidx.work.** { *; }
-dontwarn androidx.work.**
