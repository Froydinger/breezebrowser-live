# Google Play setup: short steps

Status, September 23, 2026: the user reports that the developer account is set up and verified. The Console previously confirmed account creation and the registration receipt. No further identity action is pending from the user in this task. App listing and distribution remain future release work.

## 1. Create the developer account

1. Choose **Personal** if publishing as yourself. Choose **Organization** for an existing eligible registered entity; Google requires organization verification, generally including a D‑U‑N‑S number.
2. Supply the requested legal identity, contact details and developer name. Review what Google will display publicly.
3. Review the developer agreement and pay Google’s **one-time US$25 registration fee** when ready.
4. Complete Google’s identity and device verification requests.

I can handle routine setup in the signed-in session. Account-type and factual legal details come from you. The computer-use confirmation policy requires confirmation at the agreement step; the fee needs an explicit amount authorization before payment. Identity documents or private contact details need specific authorization before transmission. Password entry or changes are handed to you.

Sources: [Google account setup](https://support.google.com/googleplay/android-developer/answer/6112435?hl=en), [Required account information](https://support.google.com/googleplay/android-developer/answer/13628312?hl=en).

## 2. Prepare Breeze’s listing

1. Create the app entry after deciding the permanent Android application ID and public publisher/support details.
2. Prepare title, short/full description, actual app screenshots, icon and feature graphic.
3. Add privacy policy and account-deletion URLs on the existing Breeze website.
4. Complete Data safety, content rating, audience, ads and app-access declarations based on actual behavior. Give reviewers working access/instructions for account-required features.
5. Include in-app reporting for AI output and account deletion in both the app and web support flow.

The privacy policy must explain encrypted sync, metadata, selected content sent to AI providers, retention/deletion, diagnostics and permission use. Private browsing is excluded from persistence/sync. Do not declare that the AI service cannot read prompts.

Sources: [User Data policy](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en-GB), [Account deletion](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en), [AI-generated content policy](https://support.google.com/googleplay/android-developer/answer/13985936?hl=en-GB).

## 3. Upload and test

1. Build a release **Android App Bundle (AAB)** targeting the current required API level, with compatible native libraries.
2. Enroll in Play App Signing. Keep the upload key backed up securely outside Git; Google’s app-signing key and our upload key have different jobs.
3. Use the internal test track first for installation and release checks.
4. For a new personal developer account, run the required closed test: **at least 12 testers continuously opted in for 14 days**.
5. Apply for production access after meeting the requirement. Google reviews the application; approval is not automatic.

As checked for this plan, new submissions require Android 16/API 36 or higher. Recheck before upload. Internal testing does not replace the personal-account closed-test requirement.

Sources: [App signing](https://developer.android.com/studio/publish/app-signing), [Closed testing requirement](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en), [Target API requirement](https://support.google.com/googleplay/android-developer/answer/11926878?hl=en).

## 4. Release

1. Resolve pre-launch findings and finish real Pixel plus desktop sync checks.
2. Review the concrete release build, listing, production cloud changes and cost limits.
3. Submit after your release instruction, starting with a controlled rollout where available.
4. Monitor crashes, ANRs, authentication/sync failures and cloud spend; pause rollout for serious regressions.
5. Keep Gecko and native dependencies current and maintain a rollback/recovery procedure. A cloud rollback must remain compatible with already-installed clients.

You can install a development build on your Pixel before Play approval. That is separate from being ready for public distribution.
