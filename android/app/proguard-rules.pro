# Python calls this interface by method name through Chaquopy reflection.
# Keep both the interface and implementations from R8 renaming/class merging.
-keep interface dev.abhishek.vidfetch.ProgressCallback { *; }
-keep class * implements dev.abhishek.vidfetch.ProgressCallback { *; }
