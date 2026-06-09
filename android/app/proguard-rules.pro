# AGP 9+ enables R8 full mode by default, which aggressively strips classes
# that libraries access via reflection. If more libraries break with R8,
# consider switching to compat mode in gradle.properties:
#
#   android.enableR8.fullMode=false
#
# See: https://github.com/googlesamples/mlkit/issues/1018

# Quickie bundles Google ML Kit barcode scanning, whose internals are resolved via
# reflection and can be over-stripped by R8 full mode. Keep ML Kit to be safe.
-keep class com.google.mlkit.** { *; }
