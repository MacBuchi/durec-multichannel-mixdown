# DurecMix release secrets — NEVER commit, NEVER share

- `durecmix-release.keystore` — the Android release signing key (alias `durecmix`).
  Every published APK must be signed with it; losing it permanently breaks
  in-place updates for all installations. Master copy: `~/durecmix-keys/`.
- `PASSWORDS.txt` — store/key password + alias (same values as the GitHub
  secrets `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_PASSWORD`).
- `keystore.base64` — the keystore base64-encoded, i.e. the exact value of
  the `ANDROID_KEYSTORE_BASE64` GitHub secret (for re-creating it).

`android/key.properties` (also untracked) points the local release build at
this keystore. This whole directory is gitignored (/secrets/ in .gitignore) —
back it up outside the repo (password manager / encrypted backup).
