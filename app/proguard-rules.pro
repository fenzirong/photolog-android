# R8 rules for the release build.
#
# Debug builds do not run R8, so a missing rule here is invisible until release — which is
# exactly when a stripped class turns into a crash on someone else's device.

# --------------------------------------------------------------------------- #
# Room
# --------------------------------------------------------------------------- #
# Room's generated DAO implementations are looked up by name at runtime.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-dontwarn androidx.room.paging.**

# --------------------------------------------------------------------------- #
# CameraX
# --------------------------------------------------------------------------- #
# The camera backend is chosen reflectively from the classpath (`camera-camera2` here).
# Without these the release build warns on the optional camera extensions it cannot find.
-dontwarn androidx.camera.**
-keep class androidx.camera.camera2.** { *; }
-keep class androidx.camera.core.** { *; }

# --------------------------------------------------------------------------- #
# ExifInterface
# --------------------------------------------------------------------------- #
-dontwarn androidx.exifinterface.**

# --------------------------------------------------------------------------- #
# Kotlin coroutines
# --------------------------------------------------------------------------- #
# Coroutine internals are resolved by name through the generated state machines.
-dontwarn kotlinx.coroutines.**
