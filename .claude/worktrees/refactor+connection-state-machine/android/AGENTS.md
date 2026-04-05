# Android AGENTS Instructions

- `versionCode` is automatically resolved by the gradle-play-publisher plugin (`ResolutionStrategy.AUTO`), which queries the Play Store for the highest existing version code and increments it. No manual management is needed.
- `versionName` is read from `android/VERSION`. Update that file to change the version (or use `scripts/release.sh`).
