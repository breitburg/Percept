# Percept

AssistantExtensions plugin that routes Siri queries to an OpenAI-compatible chat API.

Compatible with iOS 7.0+.

## Install

Add `https://breitburg.github.io/Percept/repo` as a repository in Cydia, then install
**Percept**. It depends on [AssistantExtensions](https://k3a.me/) (`me.k3a.ae`),
`preferenceloader` and `mobilesubstrate`.

## Settings

Settings → Percept:

| Field | Default | Notes |
| --- | --- | --- |
| API Key | *(empty)* | Sent as `Authorization: Bearer <key>` |
| Base URL | `https://api.openai.com/v1/` | `chat/completions` is appended; a trailing slash is added if missing |
| Model | `gpt-5.6-luna` | Any model the endpoint accepts |

Any OpenAI-compatible endpoint works — point Base URL at a local or self-hosted gateway
and set Model accordingly. Errors returned by the API are spoken back verbatim, so a
wrong key, URL or model name is diagnosable from the device.

Enable the extension in AssistantExtensions settings. No respring is needed.

## No proxy

Earlier versions routed requests through a PHP proxy to work around TLS. That is not
necessary. iOS 9 validates `api.openai.com` fine — its chain terminates at **GTS Root R4**,
cross-signed by the 1998 **GlobalSign Root CA**, which is in the system trust store;
`SecTrustEvaluate` returns `kSecTrustResultUnspecified` (success).

The real failure was the API, not the certificate. `+[NSURLConnection sendSynchronousRequest:…]`
has no delegate to answer the TLS server-trust challenge and so fails with `-1012`
(`NSURLErrorUserCancelledAuthentication`). Using `NSURLSession` — whose default handling
evaluates server trust properly — the same request succeeds against the API directly.

## Building

Needs `clang` (Xcode), `ldid` and `dpkg`, plus a legacy iOS SDK such as
[theos/sdks](https://github.com/theos/sdks). No theos installation required.

```sh
SDK=/path/to/iPhoneOS9.3.sdk ./package.sh
```

This compiles both bundles as fat armv7 + arm64, fake-signs them, builds the `.deb`
into `build/`, and refreshes the repo index under `repo/`.

Three stub libraries in the theos SDK need patching first, or the link fails:

- `usr/lib/system/liblaunch.tbd` — missing entirely, but referenced by `libSystem`'s re-export chain
- `libsystem_c.tbd` — add `_memset` and friends; armv7 emits real `mem*` calls where arm64 inlines them
- `libunwind.tbd` — add `__Unwind_Resume`; the stub carries only the SjLj (armv7) unwinder, not the DWARF one arm64 uses
