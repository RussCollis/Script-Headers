# Info Headers

[![Buy me a coffee](https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=&slug=russcollis&button_colour=FFDD00&font_colour=000000&font_family=Cookie&outline_colour=000000&coffee_colour=ffffff)](https://www.buymeacoffee.com/russcollis)

A native macOS SwiftUI app for Jamf Pro admins that adds a standard header to any **Jamf Pro script** or **extension attribute**. It reads the code to fill in the header, so a reader can see what the script does, how it's deployed, what it needs and what has changed without reading the code.

The current version is **1.0.36 (build 36)**

## ✨ Features

- **Load straight from Jamf Pro.** Connect with an API client, pick scripts or extension attributes, and push the updated header back with **Update in Jamf Pro**. Script parameter labels from Jamf Pro name the Parameters, the script's Info or EA description fills an empty Description, and an EA's data type is used for Deployment. Each update is read back to check it was saved.
- **See what's been updated.** When browsing Jamf Pro, each script and extension attribute shows whether it already has a standard header, with its version and Updated date, or *No header*. It also shows when it was last pushed from this Mac. Filter by **All**, **Updated** or **Not Updated**. Extension attributes that don't use a script are hidden.
- **Open, drop or paste** Bash, zsh, sh, Python, PowerShell, AppleScript and JavaScript scripts.
- **Reads the code** for exit codes (and the message printed before each one), Jamf parameters `$4`–`$11`, functions or section markers, files written, binaries used, root checks and `launchctl asuser`.
- **Scripts or extension attributes.** Pick the policy trigger and frequency, or the EA data type, and the Deployment and Output fields are written for you.
- **Rebuild existing headers.** A script that already has a header keeps its wording unless you turn on **Rebuild in the current format** (per script, or as the default in the Jamf Pro browser). Output, Deployment, Requirements, Exit Codes, Sections and the Disclaimer are then rebuilt from the code, while Description, Author, Created and the Change Log are kept.
- **Always bumps the version.** Adding a header is a change: the version goes up (patch, minor or major) from the script's version, or from 1.0.0 if it has none, and the Change Log says *Header added*. Updating an existing header adds your own Change Log note instead.
- **Never guesses the author.** Author is kept from the existing header, or left as *Unknown*. Updated and the Change Log record who made the change (Russell Collis by default, set in *Updated By*).
- **Optional Disclaimer** field (on by default, with editable wording that's remembered).
- **Keeps the shebang on line 1** and `# shellcheck` / `#Requires` directives in the code.
- **Check These** lists the fields to confirm, such as an assumed minimum OS, unexplained exit codes, or an email address or token in the header.
- **Save** writes the header into the original file and keeps its permissions. **Save As** saves an executable copy.

## 🧰 Requirements

- macOS 27 or later
- Xcode 27 or later to build
- For Jamf Pro: an API client (Settings › API Roles and Clients) whose role has **Read Scripts**, **Update Scripts**, **Read Computer Extension Attributes** and **Update Computer Extension Attributes**. The client secret is stored in your keychain.

## 🏗️ Building

1. Open `Untitled Project.xcodeproj` in Xcode.
2. Choose the **MyApp** scheme with **My Mac** as the destination.
3. Build and run (⌘R).

## 🔢 Versioning

Every successful build and every commit is an iteration. `tools/bump-build.sh` moves the build number on by one and sets the version's third part to match, e.g. 1.0.7 (build 7), and records the version that was just built in this README.

- Builds: the scheme's Build post-action runs the script. Failed builds aren't counted.
- Commits: enable the hook once with `git config core.hooksPath tools/git-hooks`.
- Set `SKIP_BUILD_BUMP=1` to leave the number alone.

The app icon is drawn by `tools/make-icon.swift`.

## ⚠️ Disclaimer

Info Headers is provided as is, without warranty of any kind. It only changes the comment header, but always review the result and test scripts before deploying them. You're responsible for anything pushed to Jamf Pro.

## 📄 Licence

MIT License. Copyright © 2026 Russell Collis.
