# Keep Retrofit interface methods.
-keepclasseswithmembers class * {
    @retrofit2.http.* <methods>;
}
# Keep @Serializable types — kotlinx-serialization needs reflection-y bits.
-keep,includedescriptorclasses class **$$serializer { *; }
-keepclassmembers class * {
    *** Companion;
}
-keepclasseswithmembers class * {
    kotlinx.serialization.KSerializer serializer(...);
}
