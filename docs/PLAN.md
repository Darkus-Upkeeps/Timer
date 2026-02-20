# PLAN.md — Private One-Tap Updater (Stable/Beta)

## Root Cause
Current repository has CI that builds signed APK artifacts, but the app itself has no in-app update flow. Updating requires manual GitHub navigation, download, and install.

## Goal
Enable a one-tap **Update App** flow inside the app for single-user private distribution, with channel support:
- **Stable** → `main`
- **Beta** → `Timer-Working`

## Constraints
- Repo is private.
- Distribution target is Markus only.
- APK must remain signed with the same release key.

## Architecture
1. **Build/Publish lane (GitHub Actions)**
   - Keep signed APK build job.
   - Add workflow output metadata (`versionName`, `versionCode`, `channel`, `commit`, `timestamp`).
   - Upload APK + `update.json` artifact.

2. **Private update manifest endpoint**
   - Lightweight endpoint returns latest per channel:
     - `versionCode`
     - `versionName`
     - `channel`
     - `apkUrl`
     - `sha256`
     - `notes`
   - App reads this endpoint.

3. **In-app updater UI/logic**
   - Add settings/update panel with:
     - Channel selector: Stable/Beta
     - Button: Check for update
     - Button: Install latest
   - Compare remote `versionCode` with local app version.
   - Download APK to app storage.
   - Trigger Android package installer intent.

4. **Android permissions/security**
   - Handle unknown sources / package install permission path.
   - Verify SHA256 before install.
   - Require HTTPS for manifest/APK URL.

## Implementation Steps
1. Add/update dependencies for package info + download + installer launch.
2. Implement updater service in Dart (manifest fetch, compare, download, checksum).
3. Add update UI with channel toggle and progress/errors.
4. Extend CI workflow to emit `update.json` and channel-aware outputs.
5. Validate on-device install flow for both channels.

## Verification
1. Push commit to `main` and `Timer-Working`.
2. Confirm CI artifacts contain signed APK + manifest.
3. In app on Stable channel:
   - Check shows newer version after `main` push.
   - Install succeeds.
4. Switch to Beta channel:
   - Check resolves `Timer-Working` build.
   - Install succeeds.
5. Downgrade prevention / same-version no-op works cleanly.

## Notes
Current `lib/main.dart` snapshot appears incomplete/non-buildable. If confirmed, first step is to restore a compilable Flutter baseline before wiring updater components.
