# Safe Handoff · Local Flow Lab

**Exploratory browser prototype. Not a native feature; do not merge or deploy.**

Open `index.html` directly in a browser. No installation, build, credentials, network, or microphone needed. Alternatively, from this directory run `python3 -m http.server 5173 --bind 0.0.0.0`. Run the exact embedded decision model's tests with `node --test handoff.test.mjs` (Node 22+).

## Try it in 20 seconds

1. **Start sample in Notes**, then click the **Team chat** field before the five-second simulated transcription finishes. **Finish now** skips the remaining delay.
2. Neither field receives the result. Click Notes, choose an insertion point, then **Insert into Notes**. Merely returning to Notes never inserts a held result.
3. **Reset demo**, choose **Without guard**, repeat. The same sample now lands in Team chat. This is a source-informed simulation, **not a macOS reproduction**.
4. Reset, turn Safe Handoff back on, and stay in Notes: insertion is automatic. Also try editing Notes during the delay, switching away and back, cancelling, copying, and discarding.

Switching comparison modes resets the two stand-in fields. Reset clears the fields and pending result but keeps your editable sample and selected mode. Reload clears all user-entered text. Copy is an explicit, real system-clipboard write; reload/discard cannot erase that external copy. Nothing sends a chat message.

## Why this idea clears the bar

**Observed evidence, not a claim about incident frequency:**

- Jared said “Sometimes I accidentally lose the paste” on October 29 in the [project conversation](https://devin-gtm.devinenterprise.com/sessions/419248a7f79547b3bf7672ffa9652f2f). [PR #32](https://github.com/jzone3/local-flow/pull/32) already delivered **Copy Last Transcription**. That recovery feature is explicitly not this proposal.
- At baseline [`d0d60cf`](https://github.com/jzone3/local-flow/commit/d0d60cf), [`DictationController.endRecording`](https://github.com/jzone3/local-flow/blob/d0d60cf/LocalFlow/Capture/DictationController.swift#L180-L200) awaits transcription and then invokes `TextInserter.insert`. [`TextInserter`](https://github.com/jzone3/local-flow/blob/d0d60cf/LocalFlow/Capture/TextInserter.swift#L5-L23) reads the currently focused cursor context and posts Command-V, without comparing it to the original destination. The existing retry path already avoids auto-paste because “the cursor has long moved on.”
- Novelty check: all 38 PR descriptions, 127 issue/PR comments, no review comments or standalone issues, the current capture/insertion source, and the promoted conversation's user-message history plus a full focus-related message search. No prior destination-change guard proposal was found. Clipboard restoration, retries, copy-last, app-aware cleanup, and native onboarding focus fixes already exist; they are not presented as new.
- Rejected as out of scope or already decided: stats/WPM, automatic dictionary learning, model/provider expansion, dictionary packs, file transcription, and the open iPhone preview. No changes to [PR #28](https://github.com/jzone3/local-flow/pull/28).

**Product hypothesis:** privacy includes where text lands, not just which model hears it. A slow result should not follow a user into a shared conversation. This guard intervenes only when the destination changes or becomes unverifiable; the ordinary hold-to-talk flow remains unchanged. No analytics or usage-impact claims.

## Real vs simulated

| Real, running in the browser | Simulated / not implemented |
| --- | --- |
| Editable sample and two genuine text fields | Notes and Team chat as native apps |
| Exact field/value/selection checks, interruption latch, fail-closed unknown target | macOS Accessibility identity, focus capture, secure fields, OS paste race |
| Automatic insertion only when unchanged; hold and explicit confirmation otherwise | Fn hotkey, microphone, Whisper, any provider or cloud request |
| Selection-aware explicit insertion into the original field; never silently reactivate an app | Native cleanup profiles and clipboard-preserving paste |
| Copy on request, discard, cancel, reset, stale-result rejection | Native retention/audio lifecycle or History integration |
| Memory-only page state and CSP-blocked external requests | OS-level secure deletion guarantees |

The held transcript is in a separate review area, **not the listening bar**. A native implementation would need stable process/window/element identity, unchanged insertion context, safe handling of inaccessible fields, final revalidation at paste time, and OS-level runtime tests. None are claimed verified here. This PR deliberately does not modify the native code.

## Attribution and boundaries

- All prototype code and tests were written by **Devin in this session**. No existing application code was copied or modified.
- The only existing file modified is `vercel.json`, originally authored by **Devin AI** in [`176bde1`](https://github.com/jzone3/local-flow/commit/176bde1). The added branch-specific `git.deploymentEnabled: false` prevents automatic Vercel deployment for this experiment, using [Vercel's documented setting](https://vercel.com/docs/project-configuration/git-configuration#git.deploymentenabled). Other branches are unchanged.
- The inspected native insertion/controller code is credited by git history to **Devin AI / devin-ai-integration[bot]**; it is untouched. This is not a claim that Jared wrote it.
- The prototype lives outside `site/` and `LocalFlow/`, so it is neither part of the released app nor the website. No dependency, native project, CI, release, signing, or iPhone changes.

## Verification

The unit tests execute the same inline decision model the browser uses, not a separate mock. They cover unchanged/different fields, caret/content changes, away-and-back, unknown/non-editable destinations, explicit confirmation, stale/duplicate completions, cancellation, discard, and plain-text handling. Browser results and evidence are attached to the PR after testing. Native runtime verification is intentionally outside scope.
