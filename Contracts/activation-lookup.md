# Activation lookup — v1 (Plan LS)

What the phone reads when someone types an activation key, and what the licence host must answer.
The file's name and bytes are the ones Plan CT 3a defined and `ActivationKeyMint` writes; this
contract adds only where the file is served and what each answer means.

## The request

```
GET https://licence.avenkin.com/a/<name>
```

`<name>` is hex(SHA-256(`"openglasses.activation-id.v1\n"` + the sixteen canonical characters of the
key)), 64 lowercase hex characters, exactly as on the public site. The phone sends nothing else: no
query, no cookie, no identifier. Only someone holding the key can compute the name.

Only `GET` and `HEAD`, and only names of that shape, answer under `/a/`. There is no listing.

## The answers

| Status | Means | Body | Headers |
|---|---|---|---|
| `200` | Issued and current | The sealed file, unchanged: base64 text, a few hundred bytes | `Content-Type: text/plain; charset=utf-8`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff` |
| `404` | The host looked; no key has this name | Empty | `Cache-Control: no-store` |
| `410` | The host looked; this key was withdrawn | Empty | `Cache-Control: no-store` |
| `5xx` | The host could not look | Any | `Cache-Control: no-store` |

- **Served before shown.** The file is in place before the portal shows the key, so a key typed the
  moment it is read out resolves.
- **No answer is cached anywhere**, a miss above all. A key tried too early must work on the next try.
- **A `404` is a statement, not a default.** When the host, or anything in front of it, cannot tell
  whether the key exists, the answer is a `5xx`.
- **The phone reads only the status of an error** (`BoundedHTTPClient.Profile.activationKey`,
  `readsOnlyTheStatusOfAnError`): an error page's type, size and body do not matter. A `2xx` must be
  `text/plain` or `application/octet-stream`, at most 8 KiB.
- **The path is permanent** once a build reads it.

## What the phone does with them

`ActivationKeyResolver` asks the licence host first, then the public site
(`https://avenkin.com/activation/<name>`, keys issued before this contract) only when the licence host
had no file or could not answer.

| Licence host | Public site | The phone |
|---|---|---|
| `200`, opens | not asked | Uses it |
| `200`, does not open | not asked | "not recognised" |
| `410` | not asked | "not recognised" |
| `404` | `200`, opens | Uses it |
| `404` | anything else | "not recognised" |
| `5xx`, timeout, offline | `200`, opens | Uses it |
| `5xx`, timeout, offline | anything else | "couldn't look up — connect and try again" |

The file then opens and verifies exactly as before: what the host serves is a candidate, and a host can
withhold a licence but never forge one.

## Tests

`ActivationKeyTests` (every row above), `BoundedHTTPClientTests` (an error answer is its status
alone, `text/plain; charset=utf-8` accepted), `PublicSiteGuardTests` (the host and `/a/` pinned, the
same origin a code's profile address names, written only in `LicenceHost`).
