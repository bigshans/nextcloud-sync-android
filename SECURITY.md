# Security

## Credentials

- Only the Nextcloud **app password** is stored, never the account password.
- Credentials live in the Android Keystore backed `flutter_secure_storage`
  (EncryptedSharedPreferences). They are never written to the SQLite database,
  logs, or backups unless you explicitly export a backup **with** credentials.

## Data on disk

- Sync metadata (paths, etags, mtimes) lives in the app's private SQLite DB.
- Automatic backups (`Documents/NextcloudSync/ncsync-config.json`) contain the
  server URL, username, settings and sync pairs — **never** the password.

## Network

- All traffic goes to the server you configure. There is no telemetry, no
  analytics and no third-party endpoint.
- TLS verification is never bypassed.

## Reporting

Please open a private security advisory (or email the maintainer) instead of a
public issue for vulnerabilities.
