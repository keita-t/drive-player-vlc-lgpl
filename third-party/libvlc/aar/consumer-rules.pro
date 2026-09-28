# libvlc.so and libvlcjni.so find the bindings' classes, fields and callbacks by name from native
# code (JNI_OnLoad looks them up, events are dispatched into them), so none of them may be renamed
# or removed by an app that shrinks its code.
-keep class org.videolan.libvlc.** { *; }
