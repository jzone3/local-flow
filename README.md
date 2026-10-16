# Local Flow

Open-source, privacy-first dictation for the Mac. Hold a key, talk, let go — your words are typed wherever your cursor is.

- **Hold to talk.** Fn by default; pick any key in Settings. Double-tap it to keep listening hands-free, tap again to stop. A small Liquid Glass bar shows while you speak.
- **Local by default.** Whisper (whisper.cpp with Metal) runs on your Mac. Three models to pick from — Best (default), Classic, Tiny — downloaded in-app.
- **Or bring your own key.** OpenAI, ElevenLabs Scribe or Gemini, with retries and automatic fallback to the local model. Setup finds keys already in your shell environment.
- **One dictionary.** A plain list of names, products and jargon. Sent to the model as a hint and used to fix spelling on-device. Setup lets you add word packs for your field (engineering, product, sales, legal…).
- **Cleanup that never leaves your Mac.** Ums and uhs, capitalisation, punctuation and "new paragraph" are handled with rules, not a model. On by default, one toggle to turn off.
- **Short-lived history.** Transcripts and recordings stay on your Mac only while the app is running — wiped when you quit (and on launch), and never kept longer than 12 hours.
- **Self-updating.** Checks GitHub Releases once a day and installs the new DMG in place.

## Install

Download the latest `Local-Flow.dmg` from [Releases](https://github.com/jzone3/local-flow/releases/latest), drag Local Flow to Applications and open it. Grant Microphone and Accessibility access when asked (Accessibility is what lets it see the hotkey in other apps and paste the text).

Requires macOS 14 or later. Liquid Glass needs macOS 26; older systems get a frosted bar.

## Build

```sh
brew install xcodegen
scripts/fetch-whisper.sh          # downloads the pinned whisper.cpp xcframework into Vendor/ (checksum verified)
xcodegen generate
xcodebuild -project LocalFlow.xcodeproj -scheme LocalFlow -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open "build/Build/Products/Debug/Local Flow.app"
```

Tests for the pure-Swift core (cleanup rules, dictionary spelling fixes, env-key scan, version compare) run with `scripts/test-core.sh`.

## Layout

```
LocalFlow/
  App.swift                 menu bar app, windows
  Core/                     TextCleanup, Vocabulary, EnvironmentKeys, Version — no AppKit, covered by Tests/
  Capture/                  HotkeyMonitor, AudioRecorder (16 kHz mono), TextInserter (paste), DictationController
  Transcription/            TranscriptionProvider protocol, LocalWhisper (+ model downloader), CloudProviders, TranscriptionService
  Model/                    AppSettings, Keychain, HistoryStore (wiped on quit, 12 h purge), UpdateChecker
  UI/                       DictationBar (Liquid Glass), Settings, Onboarding, History
```

### Adding a provider

1. Add a case to `CloudProviderID` in `LocalFlow/Transcription/CloudProviders.swift` with its models, key URL and env var names.
2. Write a `TranscriptionProvider` that turns a `TranscriptionRequest` (16 kHz samples + WAV + dictionary) into text. Throw `TranscriptionError.http`/`.network` so retries and fallback work.
3. Return it from `makeProvider(model:)`. Settings and onboarding pick it up automatically.

Local engines work the same way: `LocalWhisper` is just another `TranscriptionProvider`.

## Privacy

- Local mode: audio and text never leave the Mac.
- Cloud mode: only the audio clip and the dictionary hint go to the provider you chose, using your key (stored in the Keychain).
- Cleanup and spelling fixes are deterministic and on-device. There is no LLM cleanup pass.
- History (`~/Library/Application Support/Local Flow/History`) is one `history.json` plus one `.wav` per dictation, nothing else. The whole folder is emptied when the app quits and again at launch (so a crash leaves nothing behind); Delete removes files right away; while running, the 12-hour purge runs every 5 minutes, on wake and whenever the app comes to the front, and also removes orphaned audio. The folder is excluded from Time Machine so backups never keep a copy.
- Transcripts are pasted through the pasteboard, which is restored 0.6 s later; a third-party clipboard manager could still record them, as with any dictation app.

## Release

Same pipeline as [New Media Writer](https://github.com/jzone3/new-media-writer): `release.yml` builds, signs, notarizes and publishes `Local-Flow-<version>.dmg` plus a stable `Local-Flow.dmg` on every push to `master` (or a `v*` tag). Push a `release-dry-run/**` branch to get the DMG as a workflow artifact without publishing.

Secrets the workflow needs:

| Secret | Purpose |
| --- | --- |
| `MAC_CERT_P12` | base64 Developer ID Application certificate |
| `MAC_CERT_PASSWORD` | password for the certificate |
| `APPLE_TEAM_ID` | Apple Developer team ID |
| `NOTARY_KEY_P8` | base64 App Store Connect `.p8` key |
| `NOTARY_KEY_ID` | App Store Connect key ID |
| `NOTARY_ISSUER_ID` | App Store Connect issuer ID |

## License

MIT
