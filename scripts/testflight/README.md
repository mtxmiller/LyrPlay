# TestFlight upload

`upload.sh` archives the committed code, uploads it to App Store Connect and
hands the build to TestFlight groups — no Xcode clicks. `/cut-build` runs it
as its last step.

```bash
scripts/testflight/upload.sh ios  --notes-file whats-new.txt
scripts/testflight/upload.sh tvos --groups "Internal Testers"
scripts/testflight/upload.sh ios  --no-distribute     # upload only
python3 scripts/testflight/asc.py groups               # list groups / test the key
```

What it does:
1. Refuses to run with uncommitted changes to tracked files.
2. Reads the version and build number from the project (set by `/cut-build`).
3. Archives (Release) and uploads, without changing the build number.
4. Waits for Apple's processing (polls every 30s, up to 1h).
5. Sets "What to Test" from `--notes-file`, adds the build to the groups,
   and submits it for beta review if any group is external.

Logs and the archive go to `build/testflight/<platform>-<version>-<build>/`.

## One-time setup

1. **API key.** App Store Connect → Users and Access → Integrations →
   App Store Connect API → Team Keys → generate a key with the **Admin**
   role. Admin is needed for Xcode's cloud-managed distribution certificate;
   App Manager can upload but may fail at signing. Download the `.p8` file
   (only possible once) and note the Key ID and the Issuer ID shown above
   the key list.
2. **Config file** at `~/.config/lyrplay/testflight.env`, outside the repo.
   Never commit the key.

   ```bash
   mkdir -p ~/.config/lyrplay && chmod 700 ~/.config/lyrplay
   mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.config/lyrplay/
   chmod 600 ~/.config/lyrplay/AuthKey_*.p8
   cat > ~/.config/lyrplay/testflight.env <<'EOF'
   ASC_KEY_ID=XXXXXXXXXX
   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ASC_KEY_PATH=~/.config/lyrplay/AuthKey_XXXXXXXXXX.p8
   TESTFLIGHT_GROUPS=Group One,Group Two
   EOF
   ```

   Run `python3 scripts/testflight/asc.py groups` to check the key and see
   the exact group names.
3. **Keychain access for code signing.** When run outside Terminal (for
   example from Claude Code), `codesign` can't show the keychain prompt and
   fails with `errSecInternalComponent`. Allow the signing tools to use the
   key without a prompt, once (asks for your Mac login password):

   ```bash
   security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
     ~/Library/Keychains/login.keychain-db
   ```

   Running `upload.sh` from Terminal works without this: answer the prompt
   with "Always Allow".

Python needs the `cryptography` package (`pip3 install cryptography`).
