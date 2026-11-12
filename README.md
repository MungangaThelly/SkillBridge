# SkillBridge

SkillBridge is a neighbourhood skill exchange: learn a neighbour's useful skill and pay them back in time credits, never money. This repository contains a locally runnable Erlang/OTP MVP and responsive browser interface, with no third-party Erlang dependencies.

## Getting started

Install Erlang/OTP 24 or newer and [Rebar3](https://rebar3.org/). The application includes a fallback JSON codec when a standard JSON module is unavailable.

```powershell
rebar3 shell
```

Open [http://localhost:8080](http://localhost:8080). The HTTP listener only binds to `127.0.0.1` by default. On first run the application seeds five Stockholm neighbours so matching, profiles, and exchanges are immediately visible.

On Windows, build and start the app with:

```powershell
.\start.ps1
```

The launcher also works around the `inet_gethost` native resolver issue present in some older Windows Erlang installations.

### Build without Rebar3

```powershell
New-Item -ItemType Directory -Force -Path ebin | Out-Null
erlc -o ebin src\skillbridge_store.erl src\skillbridge_json.erl src\skillbridge_http.erl src\skillbridge_sup.erl src\skillbridge_app.erl
Copy-Item src\skillbridge.app.src ebin\skillbridge.app
erl -pa ebin -noshell -eval "application:ensure_all_started(skillbridge), timer:sleep(infinity)."
```

Use `SKILLBRIDGE_PORT` to select an alternate local port. Set `SKILLBRIDGE_DATA` to select the directory for the durable database file. With the default configuration, the data file is `data/skillbridge.dets` relative to the app's working directory. Use a separate `SKILLBRIDGE_DATA` directory for development instances. Keep the data file private and back it up before moving an installation. OTP 27 and newer include a JSON encoder. The bundled JSON codec provides the fallback on older versions.

## The product loop

1. Browse and search for a neighbour who can help with a specific skill.
2. Ask for one or two hours, optionally including an introductory message.
3. Meet and learn. The confirmation page keeps both neighbours informed.
4. Both people confirm the exchange. SkillBridge then awards the helper one credit per hour and deducts the same amount from the learner.
5. Spend your earned time credits with any participating neighbour.

New members start with three community credits so someone can ask for help before earning their first credits. People can search and browse without registering. Matching highlights offers that meet the signed-in member's learning needs, prioritizes nearby neighbours, and supports sorting by relevance, credits, or membership date. Without a reachable backend, the browser falls back to local demo data in that browser's local storage; this data is not shared with other members or verified by the server.

## Feature overview

- **Discover:** Filter members by name, location, biography, available skills, and learning goals. See shared-interest match hints and neighbour ratings.
- **Profiles:** Share a short introduction, neighbourhood, skills to offer, and things you hope to learn.
- **Exchanges:** Create one- or two-hour skill requests; browse pending and complete exchanges; confirm your side of a shared activity.
- **Time credits:** On the second confirmation, debit the learner's balance and credit the helper's balance as one durable transaction.
- **Messages:** Send neighbourhood members messages of up to 1,000 characters and review previous conversations.
- **Trust:** Show ratings, keep a member-initiated conduct reporting path, and surface practical first-meeting advice.
- **Languages:** Switch the interface between English, Swedish, and French; remember the selected language and use the browser language as a first-visit default. Member-written biographies and messages stay in the language their authors entered them.
- **Mobile and accessibility:** The interface adapts from narrow mobile screens through desktop widths, with semantic forms, descriptive control labels, visible keyboard focus, and searchable results. Press `Ctrl+K` or `⌘K` to focus search; press `Escape` to close a dialog.

## HTTP API

The JSON API listens on the same local server as the browser app. Submit JSON objects with the `Content-Type: application/json` header.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| `GET` | `/api/health` | Health check |
| `GET` | `/api/state` | Read community, exchanges, and messages |
| `POST` | `/api/session` | Find a member profile by email: `email` |
| `GET` | `/api/members` | List community members |
| `POST` | `/api/members` | Create a member profile |
| `POST` | `/api/exchanges` | Request an exchange: `from`, `to`, `skill`, and `duration` |
| `POST` | `/api/exchanges/:id/confirm` | Confirm as one exchange participant using `memberId` |
| `POST` | `/api/messages` | Send a message: `from`, `to`, and `body` |
| `POST` | `/api/reports` | Report a member using `memberId` and `reporterId` |

Example requests from a PowerShell session:

```powershell
$base = 'http://localhost:8080'
$community = Invoke-RestMethod "$base/api/state"
$member = Invoke-RestMethod "$base/api/members" -Method Post -ContentType 'application/json' `
  -Body (@{name='Alex Rivera';email='alex@example.org';city='Stockholm';bio='Learning a new language.';offers=@('Cooking');seeks=@('English')} | ConvertTo-Json)
$neighbour = $community.members | Where-Object { $_.id -eq 'jamie' }
$exchange = Invoke-RestMethod "$base/api/exchanges" -Method Post -ContentType 'application/json' `
  -Body (@{from=$member.id;to=$neighbour.id;skill='English conversation';duration=1} | ConvertTo-Json)
```

## OTP application layout

```text
start.ps1                  Windows build and launch helper
src/
  skillbridge.app.src     OTP metadata and startup environment
  skillbridge_app.erl     OTP application entry point
  skillbridge_sup.erl     Supervision tree
  skillbridge_store.erl   Serialized domain operations and DETS persistence
  skillbridge_http.erl    Concurrent standard-library HTTP server and JSON API
  skillbridge_json.erl    JSON compatibility codec
priv/static/
  index.html              Product structure and interface
  presentation.css        Responsive page presentation
  styles.css              Responsive visual system
  app.js                  Search, matching, messages, exchanges, and dialogs
  favicon.svg
.gitignore                Build, local data, and crash dump exclusions
```

DETS writes and syncs the community state for each operation. A single supervised store serializes exchange confirmation and credit settlement to prevent double spending. The HTTP listener spawns a process per connection. Browser network calls use the same-origin API, and browser local storage allows interactive design review when the OTP server is not running.

## Trust and deployment

This is a locally runnable MVP, not a production-ready community service. The current session lookup uses an email address without authentication, and API actions trust member IDs supplied by the client. Before operating it for real members, add account verification, authentication and authorization, CSRF protection, rate limiting, real consent-based trust signals, abuse review and appeals, private backups, and monitored HTTPS behind a production reverse proxy. Demo members use fictional `example.local` contact details and are for local product preview. The default listener binds to localhost and is **not** an authenticated public service. Browser offline data belongs to that browser and should not be considered a verified community record.
