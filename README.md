# Percept

Replaces Siri's answers with any OpenAI-compatible endpoint, on iOS 9.

## Install

Add `https://breitburg.github.io/Percept/repo` as a repository in Cydia, then install
**Percept**. Respring afterwards. It needs `mobilesubstrate` and `preferenceloader` — and,
unlike 1.x, **no longer depends on AssistantExtensions**.

## Settings

Settings → Percept:

| Field | Default |
| --- | --- |
| API Key | *(empty)* — sent as `Authorization: Bearer <key>` |
| Base URL | `https://api.openai.com/v1/` — `chat/completions` is appended |
| Model | `gpt-5.6-luna` |
| System Prompt | `You are Siri. Respond with 1-2 concise paragraphs.` — leave empty to send none |

Any OpenAI-compatible endpoint works. Errors from the API are spoken back verbatim, so a
wrong key, URL or model name is diagnosable from the device.

## Rich formatting

Replies render as HTML by default, so the markdown models emit — bold, italics, code,
bullet lists — displays as formatting rather than literal asterisks. Toggle it off under
**Rich Formatting** in settings to fall back to a plain utterance.

`SAUIHtmlView` ships no headers and is dictionary-backed, so the selector carrying its markup
cannot be known ahead of time; it is resolved at runtime from a list of candidates and logged
to `/var/tmp/percept.log`. If none binds, Percept falls back to a plain utterance rather than
rendering nothing.

The markup carries no styling of its own — the Siri sheet supplies that.

Speech is unaffected either way: TTS is driven by `speakableText`, inherited from `SAAceView`
by every view type, and is always set to the plain text.

## Conversation history

Follow-ups work: every exchange is kept and replayed with each request, so "how old is Elon
Musk?" then "where was he born?" resolves as you would expect.

The history is **uncapped** — it grows for as long as SpringBoard runs and is only cleared by
a respring. Two consequences worth knowing:

- Each request carries every prior turn, so payload, token cost and latency grow with use.
- Eventually the model's context limit is reached, after which the endpoint returns an error,
  which Percept speaks back verbatim. Respring to start fresh.

It lives in memory only; nothing is written to disk. Failed requests are not recorded, so a
network error never enters the history as though the assistant had said it.

## What it does, and does not, do

Apple still performs **speech recognition**. iOS 9 has no on-device recogniser — the
transcript itself comes back from Apple's servers, so it cannot be avoided if voice input is
wanted. **Your queries still reach Apple.** Only the *answer* is replaced. Percept is not a
privacy tool.

## How it works

A Substrate tweak in SpringBoard, hooking three points found by instrumenting the live
frameworks:

- **Transcript** — `-[AFConnection _tellSpeechDelegateSpeechRecognized:]` carries an
  `SASSpeechRecognized`, whose `af_bestTextInterpretation` is the recognised text.
- **Injection** — the reply is built as `SAUIAssistantUtteranceView` → `SAUIAddViews` →
  `SARequestCompleted` and pushed through `-[AFUISiriSession performAceCommand:]`. TTS is
  driven by `speakableText` (inherited from `SAAceView`), *not* `text`; setting only `text`
  renders a silent bubble.
- **Suppression** — Apple's own answer arrives at
  `-[AFConnectionClientServiceDelegate requestDidReceiveCommand:reply:]` as an `SAUIAddViews`
  and is dropped there.

Three things that look reasonable but do not work:

1. **Cancelling the request** after recognition. Apple's answer arrives in the same second
   regardless — it is already committed server-side.
2. **Emptying the command's `views`** instead of dropping it. These ace objects are
   dictionary-backed, so mutating `views` does not affect rendering.
3. **Dropping inbound `SAUIAddViews` by class.** Our own injected reply is echoed back
   through the *same* inbound path, so this suppresses it too. The two are told apart by
   matching the text just injected.

`AssistantExtensions` (`me.k3a.ae`), which 1.x depended on, is dead on iOS 9: its dylib fails
to load with `Symbol not found: _OBJC_CLASS_$_AFUISnippetController`, an iOS 5/6-era
AssistantUI class absent from the shared cache. No extension of it can run.

## Building

Needs `clang` (Xcode), `ldid` and `dpkg`, plus a legacy iOS SDK such as
[theos/sdks](https://github.com/theos/sdks). No theos installation required.

```sh
SDK=/path/to/iPhoneOS9.3.sdk ./package.sh
```

Builds both binaries as fat armv7 + arm64, fake-signs them, produces the `.deb` in `build/`,
and refreshes the repo index under `repo/`.

Three stub libraries in the theos SDK need patching first, or the link fails:

- `usr/lib/system/liblaunch.tbd` — missing entirely, but referenced by `libSystem`'s re-export chain
- `libsystem_c.tbd` — add `_memset` and friends; armv7 emits real `mem*` calls where arm64 inlines them
- `libunwind.tbd` — add `__Unwind_Resume`; the stub carries only the SjLj (armv7) unwinder, not the DWARF one arm64 uses
