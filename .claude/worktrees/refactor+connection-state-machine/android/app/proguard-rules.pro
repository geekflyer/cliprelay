# AGP 9+ enables R8 full mode by default, which aggressively strips classes
# that libraries access via reflection. If more libraries break with R8,
# consider switching to compat mode in gradle.properties:
#
#   android.enableR8.fullMode=false
#
# See: https://github.com/googlesamples/mlkit/issues/1018

# Google ML Kit / GMS Code Scanner
# R8 in AGP 9.x strips internal classes that the GMS barcode scanner
# resolves via reflection, causing a NullPointerException in zzny.<init>.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_code_scanner.** { *; }
