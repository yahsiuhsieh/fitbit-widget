# Share sync access, not raw health data

Both the companion app and Widget extension may synchronize Google Health so the Widget can update while the app is closed. They share OAuth tokens through the Data Protection Keychain, while the App Group contains only global settings and the normalized current snapshot. The snapshot relies on App Sandbox, App Group access controls, and Apple Silicon Data Protection for encryption at rest, is excluded from backups, and never includes raw API responses or historical health data.
