# Keep release builds (R8) from failing on optional annotation classes that
# the Keystore-backed secure storage library references.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
-dontwarn org.checkerframework.**
