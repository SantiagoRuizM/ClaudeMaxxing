# Phone app: remote access without Tailscale

**Status: design, not implemented.** Written on 2026-11-22 against `feat/ambientes` at `0d46fe0`, plus the call button (`a9a7718`), since brought to the same branch. Names of functions are given rather than line numbers: check that they still exist before starting.

## Goal

The phone reaches its PC from any network with nothing but the ClaudeMaxxing app and a server in between.

- No Tailscale, no second app, no account for the user.
- The user's own VPN stays on, on the phone and on the PC.
- The server cannot read or change what travels.
- On the same Wi-Fi it keeps working as today, without the server.

Out of scope: push notifications, iPhone, reaching anything on the PC other than the phone API, waking a PC that sleeps.

## Decisions

| | Decision | State |
|---|---|---|
| D1 | A relay on Cloudflare: one Worker and one Durable Object per PC | Chosen |
| D2 | LAN first, relay as fallback | Chosen |
| D3 | End to end is the TLS we already have, pinned by the QR. No new cryptography | Chosen |
| D4 | Cloudflare's clause 2.2.1(j) (see [Terms](#terms)) | The owner reviewed it on 2026-11-22 and considers that this design does not infringe it. No written confirmation from Cloudflare |
| D5 | Who runs the relay | **Open.** Recommended: the project runs one, and its URL can be changed for whoever deploys their own |
| D6 | Domain of the relay | **Open.** `workers.dev` is for the prototype only |

## Today

```
App timers ── a new TLS connection per request ──► MobileGate :47830 ──► queue ──► tray UI thread
              LAN or Tailscale                     (lib/mobile.cs)                 (Invoke-MobileRequest)
```

| What | Where | Why it has to change |
|---|---|---|
| Three independent polls: state and voices every 3 s, messages every 2 s, plus the call's every 2 s | `home.dart`, `voices.dart`, `call.dart` | About 4,200 requests per hour of use |
| No lifecycle handling | `mobile/lib` | Polling goes on while the process lives, and the notification's foreground service keeps it alive |
| A TLS handshake per request (`Connection: close`) | `MobileGate.Write` | `GET /info` measured 7 socket writes and reads and 2.3 KB, for 170 bytes of HTTP |
| Addresses are fixed at pairing, and all of them are private | `PairInfo`, `Get-MobileHosts` | No route from outside |
| The network filter takes part in security | `MobileGate.IsAllowed` | A relay has no source address worth checking |
| Requests are resent after a lost answer | `Api.call` | See R2 |

## Required before any relay

These also improve the app as it is, and ship on their own.

### R1. The pin applies to every certificate

**Done on 2026-11-22** in `_client` (`mobile/lib/api.dart`), tested by `mobile/test/pin_test.dart`. An Android phone gets it with the next APK.

Dart calls `badCertificateCallback` only for a certificate that it does not trust, so the client must trust none:

```dart
HttpClient(context: SecurityContext(withTrustedRoots: false))
```

Tested with Dart 3.5.3 on loopback, with that context and the app's callback. These five cases are in the test:

| Server presents | Must be | With the empty context |
|---|---|---|
| The pinned certificate | Accepted | Accepted |
| Another self-signed certificate | Refused | Refused |
| A certificate from a CA the device trusts | Refused | Refused |
| Another leaf, with the pinned certificate appended as its chain | Refused | Refused |
| The same, when the pinned certificate has no key-usage limits | Refused | Refused |

Not tested on Android.

### R2. An action runs once

`Api.call` resends any request without a raw body when it gets no answer, `POST /prompt` and `POST /action` included. If only the answer was lost, the session gets the prompt twice. `MobileGate` can also answer 503 after 30 s while the request stays queued and runs later.

- Resend only `GET`.
- Every `POST` carries a random request id. The tray keeps each device's recent ids with their answers for 10 minutes and repeats the answer instead of the action.
- A request whose waiter gave up is not run.

This comes from reading the code and was not reproduced.

## Target

```
┌───────────────── phone ──────────────────┐        ┌──────────────── PC (tray) ─────────────────┐
│ screens · notification · voices · call   │        │ Invoke-MobileRequest (UI thread)           │
│                   │                      │        │                  ▲                         │
│              PcConnection                │        │             MobileGate                     │
│       one per PC · sync · lifecycle      │        │   TLS · keep-alive · waiters · queue       │
│           │                 │            │        │      ▲                          ▲          │
│       LanRoute         RelayRoute        │        │ TCP :47830                 MobileRelay     │
└───────────┼─────────────────┼────────────┘        └──────┼──────────────────────────┼──────────┘
            └─────────────────┼── same network ────────────┘                          │
                              │                                                       │
                              └── WSS 443 ──► Worker + Durable Object ◄── WSS 443 ────┘
                                              sees ciphertext only
```

Three layers, each replaceable without touching the others:

1. **API**: the routes of `Invoke-MobileRequest`, plus `/sync` and `/relay`.
2. **Secure channel**: TLS 1.2 with the PC's certificate and HTTP/1.1 keep-alive, identical on both routes.
3. **Route**: a TCP socket on the LAN, or a pair of WebSockets through the relay.

### Phone

**`PcConnection`** (new). One per paired PC, owned by `Root`. The screens, `SessionNotification`, `VoiceStore` and the call listen to it, and none keeps a network timer of its own.

It runs one sync loop:

```
GET /sync?rev=<last>&session=<id on screen or in call>&after=<offset>&voices=<cursor>

200 { "rev": "...", "state": {...}, "messages": {...}, "voices": [...] }   only what changed
200 { "rev": "..." }                                                        nothing in 25 s
```

| App | Sync |
|---|---|
| In front | State, voices and the session on screen |
| Behind, with a call | State and the call's session |
| Behind, with the sessions notification | State only |
| Behind, with neither | Stopped. One sync on return |

**Routes.** On start, on return and on a change of network, try the LAN addresses (1.5 s at most), then the relay. While on the relay, try the LAN again every minute in front. Never race the two routes with a `POST`. The header says which route is in use.

**`RelayRoute`.** Dart's `SecureSocket` needs a real socket, so the route opens a listener on `127.0.0.1` with a random port that takes one connection and copies it to the WebSocket. TLS and the pin stay in `HttpClient`, unchanged. The listener closes after that connection.

### Relay

A new `relay/` folder with the Worker and the Durable Object. It is not installed on PCs, so it stays out of `lib/installer.ps1`.

| Endpoint | Who | Authorization |
|---|---|---|
| `GET /v1/pc/<room>` | The tray's control socket | The PC's secret: `room == hex(SHA-256(secret))` |
| `GET /v1/pc/<room>/<stream>` | The tray, one socket per stream | The PC's secret |
| `GET /v1/phone/<room>` | The phone, one socket per stream | That phone's relay key, or the pairing key |

1. The tray opens the control socket and sends the hashes of the valid phone keys.
2. A phone connects. The relay checks its key, creates a stream id and tells the control socket `{stream, device}`.
3. The tray opens that stream's socket. The relay pairs both and sends `ready` to the phone.
4. From there it copies binary messages, 64 KiB at most each, and stores none. When one side closes, it closes the other.

One WebSocket per stream means no multiplexing protocol of our own. With keep-alive a phone holds two or three.

Rules for the Durable Object:

- Use the Hibernation API (`acceptWebSocket`, tags, attachments). A plain `accept()` bills all the time a socket is connected.
- Answer keep-alives with `setWebSocketAutoResponse` or protocol pings, so they do not wake it.
- Refuse requests with an `Origin` header: no browser is a client.
- The only destination is the other half of the room. No host, port or URL is ever taken from a client.
- Log no headers, keys or payloads.

### PC

**`MobileRelay`** (new, `lib/mobilerelay.cs`). An outbound `ClientWebSocket`, which Windows PowerShell 5.1 already has. It reconnects with backoff and jitter, honors the system proxy, and wraps each stream's socket in a `System.IO.Stream`.

**`MobileGate`**:

- `Serve` takes `(Stream, remote, via, device)` instead of only a `TcpClient`. The relay hands its stream over in process. **Do not connect to `127.0.0.1:47830`**: every remote phone would then pass `IsAllowed` as loopback.
- Keep-alive, with short timeouts until a request has a valid token and a longer idle one after.
- `/sync` waits on a C# waiter, never on the tray's UI thread, and does not hold one of the 16 worker slots. Limit waiters per device.
- The UI thread recomputes the revision once a second, only while someone waits, and leaves out fields that tick by themselves (elapsed time, "renews in").
- `lib/mobile.cs` opens with "only takes connections from loopback, private networks and Tailscale", and the header of `lib/mobile.ps1` with "No server of ours in between". Both stop being true.

### Pairing and keys

| Secret | Made by | Kept in | The relay sees |
|---|---|---|---|
| Certificate's private key | PC (exists) | Windows certificate store | Never |
| API token, one per phone | PC (exists) | Phone's secure storage, its hash on the PC | Never, it travels inside TLS |
| Pairing code | PC (exists) | Memory, 5 minutes, 5 tries | Never, it travels inside TLS |
| Relay secret of the PC | PC | DPAPI, as the other keys | Yes, it authenticates the room |
| Relay key, one per phone | PC, at pairing | Phone's secure storage, its hash on the PC | Yes, it opens a stream and nothing more |
| Pairing relay key | PC, per QR | Memory, 5 minutes | Yes |

- The QR adds `u` (relay URL), `r` (room) and `k` (pairing relay key) to `cmx://pair?h&p&f&c&n`. `PairInfo.parse` must accept an empty `h` when those three come.
- A stream opened with the pairing key can only call `/info` and `/pair`.
- On a relayed stream the API token must belong to the same device as the relay key.
- Phones paired before this get their relay key over the LAN with an authenticated `GET /relay`. They do not pair again.
- Revoking a phone removes both hashes, updates the relay and closes its open streams.
- A new certificate already unpairs every phone. It also replaces the relay secret.

### Switches and policy

- Off by default: **From outside your network**, in the Phone section.
- A separate policy module, `relay`, off by default in the Business edition. Check it at every entry point: start, section, pairing, reconnection. `mobile` off turns it off too.
- The PC can change the relay URL. Changing it means pairing again.
- The firewall rule is needed for the LAN route only.

## Threats

A paired phone can write to the sessions, so reaching the API is close to running commands on the PC.

| Threat | Answer | What is left |
|---|---|---|
| The relay, or whoever takes it over, reads or alters traffic | TLS with the pin (R1) | It sees IPs, times and sizes, and can cut the service |
| The relay replays traffic | TLS | None known |
| A leaked relay key | It gives a TLS stream with no API token. Revocable | Noise against that PC |
| A stolen phone | Revoke it in Phone | Full access until then. Consider the device lock for prompts and for Power |
| Guessing the pairing | 64-bit code, 5 tries, 5 minutes, plus the pairing key | None practical |
| Strangers use the public relay as their own pipe, since anyone can make a room | Limits per IP and per room: streams, messages, bytes per day | **Open.** An open-source client cannot prove that it is ours. Watch usage. It also matters for the terms |
| A flood from the internet | Refused at the relay before it reaches the PC | The relay's daily quota |
| The APK is replaced | The project's release key | Losing that key |

Cloudflare's rate-limit binding is approximate and per location, so the caps per room are counted in the Durable Object.

## Capacity and cost

Prices read on 2026-11-22. Durable Objects on the free plan: 100,000 requests and 13,000 GB-s a day for the whole account. Paid: $5 a month with 1 million requests and 400,000 GB-s, then $0.15 per million and $12.50 per million GB-s. 20 incoming WebSocket messages bill as one request. Outgoing ones are free. Past the free quota the relay fails until 00:00 UTC.

| Scenario | Billed requests per phone and day | Phones on the free plan | 1,000 phones on paid |
|---|---|---|---|
| Today's app through a relay, alive all day | 28,800 to 50,400 | 2 or 3 | Not viable |
| Today's app, 2 h of use | 4,200 | ~23 | Not worth it |
| This design, 2 h of use | 540 | ~185 | ~$7.4 a month |
| This design, 2 h of use and the notification the other 22 | ~1,015 | ~98 | ~$9.5 a month |

That last row uses about 390,000 GB-s, just under the 400,000 included: more compute per message than assumed adds $12.50 a month per million.

Assumptions, to replace with the prototype's numbers: 10 messages per request today and 3 with keep-alive, one sync every 2 s in use and every 25 s idle, about 5 ms of billed compute per message. The domain is extra.

## Compatibility

- `/info` gains `proto: 2`. An app that does not see it keeps polling over the LAN, as today.
- The tray keeps `/state`, `/messages` and `/voices` for older apps.
- Tailscale keeps working: its address is just one more LAN route.
- This is a minor version (see [VERSIONING.md](../VERSIONING.md)): a new module that sends data off the PC, off by default. Removing the old routes would be a major one.

## Plan

Each phase ships by itself.

### 0. Safety

`mobile/lib/api.dart`, `lib/mobile.cs`, `lib/mobile.ps1`.

- [x] R1, with its five cases as a test
- [ ] R1 checked on an Android phone
- [ ] R2, with a test that drops the answer of a prompt and finds it delivered once

### 1. Connection (LAN only, no server)

New `mobile/lib/connection.dart`. Changes in `api`, `main`, `home`, `voices`, `notify`, `call`, `lib/mobile.cs`, `lib/mobile.ps1`. The call's own polling goes too.

- [ ] Keep-alive: 100 requests use at most 3 TLS handshakes
- [ ] `/sync` replaces the polls, and the tray's window stays responsive with three phones waiting
- [ ] Behind with no call and no notification: no requests in 5 minutes
- [ ] An old app works with the new tray, and a new app with an old tray

### 2. Relay prototype (owner's account, `workers.dev`)

New `relay/`, `lib/mobilerelay.cs`, `mobile/lib/relay_route.dart`.

- [ ] Works on mobile data, with another VPN on the phone, and with one on the PC
- [ ] Hibernates when idle, and .NET Framework's keep-alive does not wake it (it may send pongs rather than pings)
- [ ] A 25 MB upload arrives whole, and the Durable Object's memory holds with a slow receiver
- [ ] A 30-minute call survives a change from Wi-Fi to mobile data. Latency written down here
- [ ] Switching networks, or a PC that sleeps and wakes, reconnects alone
- [ ] Measured messages and GB-s replace the assumptions above

### 3. Product

`lib/hubmobile.ps1`, `lib/business.ps1`, `business/policy.example.json`, `lib/lang/en.json`, `mobile/lib/strings.dart`, README, CHANGELOG, CLAUDE.md.

- [ ] D5 and D6 decided
- [ ] Switch, policy, QR, migration of paired phones and revocation
- [ ] Abuse limits and a usage alert on the Cloudflare account
- [ ] README's Privacy, "no relay" lines and Tailscale texts rewritten, saying what the relay sees
- [ ] An end-to-end test with a local Worker (`wrangler dev`), next to `test/mobile-e2e.ps1`
- [x] The release attaches the APK (`release.yml`)

## Alternatives considered

| Option | Why not |
|---|---|
| The same relay on a VPS | The fallback if Cloudflare objects or the price changes. A server to look after |
| Cloudflare Tunnel | An account and a domain per user. Cloudflare ends the TLS, so it would see the token |
| Quick Tunnels | For testing only: the URL changes and there is no uptime promise |
| WebRTC with Cloudflare TURN | Direct connections and 1 TB free, but far more code on both sides |
| iroh | No official .NET or Dart SDK. Production relays from $19 a month |
| Tailscale embedded (tsnet) | Go in both apps, and still a Tailscale account |
| Tailscale Funnel | The PC still needs Tailscale |
| ngrok | 20,000 requests a month on the free plan, and it ends the TLS |
| Claude Code's Remote Control | No ClaudeMaxxing panel, and the transcript is stored on Anthropic's servers |

## Terms

Cloudflare's Self-Serve Subscription Agreement (updated 2025-09-12), 2.2.1(j), says not to "use the Services to provide a virtual private network or other similar proxy services".

What keeps this design away from that, and must stay true:

- it serves this app's API only;
- nobody chooses a destination;
- it gives no access to the internet or to the PC's network;
- rooms are capped, so it is of no use as a general pipe.

Read the clause again before launch. If Cloudflare objects, the same protocol moves to a VPS and only the URL changes.

## Sources

- Durable Objects: [pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/), [limits](https://developers.cloudflare.com/durable-objects/platform/limits/) (32 MiB per received message), [WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/), [lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/)
- Cloudflare: [terms](https://www.cloudflare.com/terms/), [rate limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/), [workers.dev](https://developers.cloudflare.com/workers/configuration/routing/workers-dev/), [deploy button](https://developers.cloudflare.com/workers/platform/deploy-buttons/), [Tunnel](https://developers.cloudflare.com/tunnel/get-started/), [Quick Tunnels](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/), [TURN](https://developers.cloudflare.com/realtime/turn/faq/)
- Android: [one VPN at a time](https://developer.android.com/develop/connectivity/vpn), [Doze](https://developer.android.com/training/monitoring-device-state/doze-standby)
- Dart: [badCertificateCallback](https://api.dart.dev/dart-io/HttpClient/badCertificateCallback.html)
- Others: [iroh languages](https://docs.iroh.computer/languages), [iroh pricing](https://www.iroh.computer/pricing), [tsnet](https://tailscale.com/kb/1244/tsnet), [Funnel](https://tailscale.com/kb/1223/funnel), [ngrok limits](https://ngrok.com/docs/pricing-limits/free-plan-limits), [Remote Control](https://code.claude.com/docs/en/remote-control)
- Prior art: [Paseo's relay](https://github.com/getpaseo/paseo/tree/main/packages/relay), end to end encrypted on Durable Objects. Its configuration now also names an upstream on Fly.io
