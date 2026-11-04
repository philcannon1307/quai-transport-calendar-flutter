# Building the web app (GitHub Actions)

The workflow `.github/workflows/web-build.yml` builds the Flutter web app. It uses the public settings in `config/public-config.json` (the Railway server address). No secrets are involved.

## Run it
1. Open the repository on GitHub, then the **Actions** tab.
2. Click **Build web** in the left list, then **Run workflow** (green button) and confirm. It also runs by itself on every push to `main`.
3. Wait about 5 to 10 minutes until the run shows a green check.

## Download the result
1. Open the finished run.
2. Scroll to **Artifacts** at the bottom and click **web-build** (a zip file; kept 14 days).
3. Unzip it: that folder is the complete website, ready to upload to a web host.

## Notes
- The run fails early if the config has no Railway address or has an old Supabase/Lovable address.
- Tests run in a separate job: if one fails, the web-build artifact is still produced. Failing test names are listed on the run page; the test-log artifact has the full output and build-log has the build output.
- If a run is red, send a screenshot of the red step or the log artifact.
- An Android job exists in the file but is switched off (`if: false`). iOS is not set up.
