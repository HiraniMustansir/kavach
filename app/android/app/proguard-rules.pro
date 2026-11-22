# Native code looks these up by name (JNI), so R8 must not rename or strip them.
-keep class net.zetetic.database.** { *; }
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**
# Manifest-declared services/receivers/activities are kept by AGP; keep the agent wholesale for safety.
-keep class app.kavach.agent.** { *; }
