## Releasing

```
# .envrc
export DEVELOPER_ID=""
export TEAM_ID=""
```

```
xcrun notarytool store-credentials "notarytool" --apple-id <your-apple-id> --team-id <your-team-id>
```

Generate an App Specific password at https://account.apple.com/account/manage and enter it.

