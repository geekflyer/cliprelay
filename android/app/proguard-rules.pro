# Google ML Kit / GMS Code Scanner
# R8 in AGP 9.x strips internal classes that the GMS barcode scanner
# resolves via reflection, causing a NullPointerException in zzny.<init>.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_code_scanner.** { *; }
