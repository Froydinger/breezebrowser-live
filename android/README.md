# Breeze Android

Native Kotlin/Compose browser with GeckoView. This is a private development build, not a Play release candidate.

## Current scope

- Ask-first routing, browser navigation, tabs and private tabs, local history, bookmarks, and saved chats.
- Dark and light themes, configurable glass surfaces, wallpapers, tab wall, and local settings.
- Android Keystore encrypted app records and a separate device-authenticated local password vault.
- Gecko tracking protection, site dialogs and file inputs, find and desktop-site controls, and SAF downloads.
- Existing Breeze Cloud chat Worker supports mobile chat, research, fact-check, summarize, and YouTube tasks. Deployed Worker version: `6ec70490-4311-404f-ac9a-ab90f2cef16c`; configured model: `gpt-6-luna` with web search.
- **Cloud sync — Coming soon.** There is no account creation or cloud-sync connection in this build. Local password storage does not upload credentials.

## Build

Requires JDK 17, SDK platform 37.1, build tools 36, and the checked-in Gradle wrapper. Target SDK is 36; newer compile SDK is required by current GeckoView. Development packaging currently targets arm64 devices such as the connected Pixel.

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@17 \
ANDROID_HOME=/opt/homebrew/share/android-sdk \
./gradlew :app:assembleDebug
```

Debug builds read the existing local `.breeze-client-token` without printing it. It is embedded only in the private development APK. **Do not redistribute this APK or upload it to Play.** Release builds do not include that credential; production authorization and attestation remain release requirements. No provider API key is stored in the app.

Install with `adb -s DEVICE install -r app/build/outputs/apk/debug/app-debug.apk`. The development package is `com.froydinger.breeze.dev`, separate from a future production package.

## Evidence and limits

Five live Worker checks for chat, research, fact-check, summarize, and YouTube completed successfully; results are recorded in [cloud-results.json](qa/cloud-results.json). Emulator checks also covered conversational chat, clickable research citations and source links, page summarization using rendered text from example.com, and the keyboard-visible chat composer. Theme and screen captures are in [qa/screenshots](qa/screenshots).

Independent visual review passed the revised reference screens (see `qa/VISUAL-REVIEW.md`). The reviewed build was installed and opened on the Pixel; functional interaction evidence is from the emulator unless explicitly stated in BUILD-STATUS.md. These checks cover the described flows, not every feature or device configuration. The private debug credential makes this APK unsuitable for public distribution or Play release.

Website passkey provider authorization remains a release requirement; there is no passkey toggle claiming that provider setup is complete. The local password vault uses encrypted device storage and system authentication. The temporary encrypted JSON app store must become transactional indexed storage before large-history scaling or sync.

## Files

- `app/src/main/java/com/froydinger/breeze/BrowserState.kt`: local browser/session/chat orchestration.
- `ui/`: shared optical surfaces, library/settings/chat, and password vault.
- `data/`: encrypted records and separate auth-bound vault.
- `cloud/`: bounded HTTPS SSE protocol client.
- `deferred/desktop/`: future Swift sync wire format; excluded from desktop build.
- `../cloudflare/breeze-chat-worker/MOBILE-RESPONSES.md`: mobile route and protocol notes.
- `../android-design/`: approved references and plan with subsequent scope amendments.
