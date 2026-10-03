# Vault

The vault keeps secrets out of plaintext files. Every master (the Mac app and `kanban-code-server`) runs it; the box is its home and the Mac keeps a replica.

## Storage

`~/.kanban-code/vault/` on each master:

| File | Content |
|------|---------|
| `vault.age` | All secrets, age-encrypted to the vault key, with an HMAC keyed from the same key so only key holders can write a replica. Secrets of tier ask and never are inside it only as ciphertext for the owner keys (see Owner-only secrets) |
| `leases.json` | Card leases: card, secret, expiry. No values |
| `audit.jsonl` | Append-only log of this machine: time, card, secret, tier, outcome, decider, command. Each line names the hash of the line before |
| `audit-mirror/<machine>.jsonl` | The audit log of each peer master, as it pushed it. Lines are only added |
| `device-key.bin` | Mac only: the Secure Enclave's handle to this Mac's owner key. Useless on another machine and without Touch ID |
| `device-approvals.jsonl` | Mac only: the vault requests answered on this Mac, chained like the audit log |
| `backup-before-owner-seal/vault.age` | The file as it was before the first owner-only secret was sealed |
| `pending.age` | Approval requests still waiting for the human, age-encrypted to the vault key (an add carries the new value). Removed when none are open |
| `card-tokens.json` | SHA-256 of each card session token and its card. No tokens |
| `scrub-index.json` | Fingerprints of the values, for the scrubber. No values, no key |

The vault key (the machine key) is an age X25519 identity. On the box it is `vault/identity.txt` (0600, root). On the Mac it is the login keychain item `io.kanbancode.vault` / `age-identity`, readable without a prompt only by the signed app. To give a machine the key, write it to `~/.kanban-code/vault/identity.import`; the master imports it at start and deletes the file.

Recovery without Kanban Code: `age -d -i identity.txt vault.age` gives `{"doc": <base64 JSON>, "auth": ...}`; the `doc` field is the secrets. An owner-only secret there has an empty `value` and a `sealed` field: `base64 -d` it into a file and `age -d -i recovery.txt <file>` gives `{"name", "value"}`.

Replicas sync with the configured peers every minute (`GET`/`POST /v1/vault/replica`, peer token). Each secret's newest edit wins; a delete is an edit.

## Owner-only secrets

Two sets of secrets:

| Set | Tiers | Who can read the values |
|-----|-------|-------------------------|
| Unattended | open, judged | The machine key: the master releases them on its own |
| Owner-only | ask, never | The owner keys: a device after Touch ID or Face ID, or the recovery key. The machine key, and so root on the box, reads only ciphertext |

An owner key is one of:

- A device key: P-256, made inside the Secure Enclave of the Mac (Kanban Code) or the iPhone (Kanban Code Mobile), not exportable, usable only after biometry with the fingers or face enrolled when it was made (`.biometryCurrentSet`, no password or passcode fallback). Adding a finger or resetting Face ID ends that key; enrol the device again from another one.
- The recovery key: an age X25519 identity, shown once in Settings > Vault > Owner Keys and kept only in 1Password.

Each owner-only secret is its own age file, encrypted to every owner key (`piv-p256` stanzas for the devices, an `X25519` stanza for recovery), holding `{"name", "value"}`. It is the `sealed` field of the secret; `value` is empty. The store keeps that invariant on every write: with owner keys in place, a secret of tier ask or never is sealed, also one a replica merge brought in plain.

Sealing starts when the owner keys hold the recovery key and at least one device. Until then ask and never secrets stay as before, and `kv owner` says how many.

### An approval is the decryption

A request that needs a sealed value carries the ciphertext on its attention request (`unseal`). Approving it on the Mac sheet or the phone runs the Secure Enclave key agreement (the Touch ID or Face ID prompt), opens the value on the device, and sends it with the answer (`POST /v1/attention/{id}/resolve`, `unsealed`). The master uses it for that request and forgets it.

- "Approve once": the value is used for that one release.
- "Approve for this card (2 days)": the master keeps the value in memory until the lease ends, so the card's next uses need no prompt. A restart of the master forgets it: the lease is still there, the next use asks again with "it opens only with your Touch ID or Face ID".
- An approval that arrives without what the key unlocked (an older app, a banner button on a build without the key) is refused with HTTP 409 and the request stays open.
- A hook-wrapped command goes on without a sealed secret, as it does for anything that asks.

The device checks what it opens: the name inside the sealed value must be the secret the request names, or one of its earlier names. It refuses otherwise ("the request names X but the sealed value belongs to Y"). The detail sheet lists what the approval does on the device ("Unlocks here", "Mints here", "Owner keys after") from the request's own `unseal` data.

### Tier changes

- Into ask or never: the master still has the value and seals it.
- Out of ask or never: the edit's approval carries the sealed value, the device opens it, and the master stores it under the machine key. From Settings > Vault the Mac does it with its own key (Touch ID).
- A new value (`kv set`) for an owner-only secret is sealed as it is stored.
- Two secrets cannot be merged by `kv mv` when either is sealed: their values cannot be compared.

### Devices

`Settings > Vault > Owner Keys` on the Mac sets it up: "Create Keys" makes the Mac's key and the recovery key, shows the recovery key once, and "Seal N Secrets" (enabled by "I stored the recovery key in 1Password") encrypts every ask and never secret. The recovery key is then gone from the Mac: it was only in the sheet, and the clipboard is cleared when it still holds it. "Check the recovery key" takes a pasted key and tries it on a sealed secret.

A second device (the iPhone: Machines > Vault key > Enrol this phone) sends its public key to a master (`POST /v1/vault/owner/enrol`). That raises an approval, "wants to change the keys that unlock the owner-only secrets", listing every key after the change with its fingerprint. Approve it on a device that already holds a key, after comparing the fingerprint with the one the new device shows: that device opens each sealed secret and encrypts it again to the new set, and only ciphertext goes back. Removing a key works the same way from the Owner Keys sheet.

`kv owner` lists the keys (kind, fingerprint, name) and how many secrets are sealed.

### What it does and does not cover

- Root on the box cannot read an owner-only value at rest, and cannot make a device open one without the human's biometry.
- A value in use is in the memory of the master and of the command that got it. Leased values and minted AWS credentials stay in the master's memory for their window.
- The request text (card, reason, command) comes from the master. A master under someone else's control can word a request as it likes; the device shows the names it really unlocks and the role it really assumes.
- New owner-only values pass through the master in plain on their way in (`kv set`), and are encrypted to the owner keys the vault file lists.
- Copies of the vault from before the seal still hold the old values under the machine key: the backup folders and the box's restic snapshots (which carry `identity.txt`). `Scripts/vault-owner-cleanup.sh` reports them; `--delete-backups` and `--restic` remove them, each after a typed confirmation at a terminal.

## Names, projects and environments

A secret has a key (the environment variable it fills), a project and an environment. Its name is its id:

| Name | Meaning |
|------|---------|
| `OPENAI_API_KEY` | Shared: no project, no environment |
| `shop/dev/OPENAI_API_KEY` | The `shop` project's own value for `dev` |
| `shop/api/prod/DATABASE_URL` | Project `shop/api` (a subfolder of the repository), environment `prod` |

The last part is the key, the one before it the environment, the rest the project. Listings carry `key`, `project` and `environment` as fields, and approvals, the audit log and `kv ls` show a project's secret as "label · project · environment".

The project of a folder is the name of its repository's main checkout folder, plus the path below it for a subfolder (`VaultProjects`). A linked worktree counts as its main checkout, a submodule as a subfolder of the repository that holds it. Outside a repository the root is the nearest folder with a `.env.vault` manifest, else the folder itself. A `.vault-project` file in the root holding one line replaces the folder name, for two repositories with the same folder name. Characters a secret name does not allow become `-`.

The environment is `dev` unless said: `.env.prod.vault` or `--env prod` selects `prod`, `.env.X.vault` selects `X`.

A renamed secret keeps its earlier names as aliases (`aliases` in the listing): every lookup by an old name resolves to it, and the answer comes back under the name that was asked. The old entry becomes a tombstone, so the rename reaches the other replica like any edit. `kv mv OLD NEW` renames; onto a name that already holds the same value it merges the two (stricter tier, both sources and aliases), onto a different value it refuses.

Listings also carry a `fingerprint`: an HMAC of the value under the vault key, cut to 8 bytes. Two secrets with the same value have the same fingerprint; it says nothing else about the value.

## Tiers and decisions

| Tier | Release |
|------|---------|
| open | Any card session, logged |
| judged | Jev reads the command, the reason, the card title, the card's recent prompts and the secret's rules: allow, ask or deny |
| ask | Rogerio approves on the Mac or the phone; the approval unlocks the value with Touch ID or Face ID |
| never | Refused. Used for the long-lived AWS keys, which only a device opens to mint credentials |

Order, first match wins:

1. Tier never: deny.
2. The caller is not inside a card session: ask, whatever the tier.
3. More than 20 releases of the secret in 5 minutes: ask. A yes from the human starts the count again.
4. The card holds a lease and the secret allows leases: allow.
5. Open: allow. Judged: the project's own development secret is allowed, anything else goes to Jev (allow needs at least 60% probability; Jev unreachable asks). Ask: the human.
6. Allowed, but the value is sealed and the master holds no value for it (or it is an AWS profile and the master holds no credentials): ask, for the device to unlock it.

"The project's own development secret" is a judged secret with environment `dev` and no rules, asked for by a process inside a card whose working directory is in that secret's project folder (or a worktree of it, or a subfolder). The master reads the working directory from the process itself (`lsof` on macOS, `/proc` on Linux), not from the request. It is allowed with no Jev call and logged with decider `rule`. Shared secrets, other environments, secrets with rules, with "every use asks", of tier ask or never, AWS profiles, and callers that are OpenClaw agents or outside a card keep the path above.

Jev gets one question per distinct rules text in a request, naming every secret under those rules (`secret_names`); its answer is the verdict of each. Every secret still gets its own audit line.

"Inside a card session" is checked by the master, not claimed by the client. kv calls the local master over loopback; the master finds the calling process from the TCP connection (`lsof` on macOS, `/proc/net/tcp` on Linux), walks its parents, and matches them against the pane shells of the cards' tmux sessions and the assistant processes rush hosts for cards. A rush host belongs to the card whose terminal is `rush-<host id>` (or `agtop-<host id>` for a host started before rush was renamed from agtop) in Kanban's links, whoever started it (the master, a rush view, `rush session start`); its own `--meta kanban_card` is never read. Accepted risk: a local process can start a host for a card's session id and act as that card; such a process already runs as the user. `KANBAN_CARD_ID` is only shown to the human when it could not be verified. Requests over the network are never inside a card.

A process that left its session's tree (`setsid nohup ... &` reparents it to launchd or init) is placed by its session token. When the master starts or resumes a card session on its own machine it makes a random token (`VaultCardTokens`), keeps only its SHA-256 in `vault/card-tokens.json`, and gives the session `KANBAN_CARD_ID` and `KANBAN_CARD_TOKEN` in its environment: `tmux new-session -e` for a tmux card and `rush session start --env` for a rush card, never typed into the pane or logged. kv sends the token in `X-Kanban-Card-Token`. The ancestry is checked first; when it finds no card, a token whose hash is on file and whose card still has a session makes the caller that card, and the audit line says "by session token". A wrong or missing token changes nothing. A card has one token: a new session replaces it, and a token whose card has had no session for 15 minutes is removed. Sessions started before the token existed have none. `KANBAN_CARD_TOKEN` is in `InheritedSessionEnvironment`, so an app or tmux server started from a card's shell does not hand it to other cards. On Linux, rush hosts are also subreapers, so the ancestry usually still finds such a process.

### Cards on another machine

A card on one master that runs a command on the other over ssh (`ssh root@box 'kv run ...'`) has no session there: its process chain ends in `sshd`. It is placed by its session token, which only the master that issued it has on file.

1. ssh carries the two variables. The client sends them (`~/.ssh/config`, for the peer's host: `SendEnv KANBAN_CARD_ID KANBAN_CARD_TOKEN`) and the server takes them (`/etc/ssh/sshd_config.d/60-kanban-card-env.conf`: `AcceptEnv KANBAN_CARD_ID KANBAN_CARD_TOKEN`, then `sshd -t` and a reload). The token is never on a command line and never logged. Set up from the Mac to the box; the other direction needs the same two lines the other way round (the Mac's sshd config needs an administrator).
2. kv on the remote side sends the token in `X-Kanban-Card-Token`, as it does locally.
   A shared ssh connection (`ControlMaster`) opened before the sshd reload keeps the old server settings and drops the variables: close it once with `ssh -O exit <host>`. `ssh <host> 'echo ${KANBAN_CARD_TOKEN:+set}'` from a card session prints `set` when they arrive.
3. The master does not know the token, so it sends its SHA-256 to each enabled peer (`POST /v1/vault/card-token`, peer token; `VaultPeerTokenVerifier`). The master that issued it answers with the card id, the card's title and its own machine name while the card has a session, else 404.
4. The caller is then that card: its leases, its one question per thing asked, the card's prompts for Jev when this master has the card's transcript (the peer mirror), none otherwise. The request names the card by its title, the details say "Card: <title>, via ssh from <machine>" (plain "from <machine>" without sshd in the chain), and the audit line ends with "by session token, verified by <machine>".

A yes is kept for 60 seconds, a no for 15. A peer that does not answer is neither: the caller is outside every card, as before, and the next call asks again. The own-project development rule does not apply to such a caller: this master verified neither the session nor the folder the card works in, so a judged secret goes to Jev.

The variables an ssh login brought do not reach sessions started later on that machine: `InheritedSessionEnvironment` unsets both from a tmux server's environment before a card session starts there, a card session gets its own values, and `kanban-code-server` drops them from its own environment at start.

OpenClaw agents on a Linux master count like card sessions under the principal `openclaw:<agent>`: the master finds, in the caller's ancestry, a process whose cgroup is the gateway's systemd unit (`openclaw-gateway.service`, set by systemd, not by the process), then the topmost process below the gateway whose working directory is an agent workspace from `~/.openclaw/openclaw.json` (the agent runtime the gateway started; a child that changes directory does not change it). The gateway itself, resolving SecretRefs, is `openclaw:gateway`. Each principal holds its own leases. Commands an agent starts outside the unit (`systemd-run`, cron) are outside, so they ask.

Human approvals are attention requests of kind `vaultApproval` with the options "Approve for this card (2 days)", "Approve once", "Deny". A secret with "every use asks" never offers the lease. No answer in 60 minutes denies; kv says so when it starts waiting.

### One question per thing asked

A request that asks the human what an open request already asks joins it: no second attention request, no second notification. Two requests are the same question when they come from the same caller (the verified card or OpenClaw agent; outside a card, the same claimed card, device and folder), are the same kind (a release in the same mode, a lease, the same edit) and ask for the same secrets. The command and the reason do not count; the human sees those of the first.

- The same call again (a retry, parallel `credential_process` calls) gets the id of the open request and waits on it.
- A release that asks the same secrets but returns something else (other open secrets next to them, another folder) waits under its own id on the same question and gets its own values.
- The answer goes to every waiter: approve, deny or timeout.

The open request does not depend on its caller. When the caller gives up (a tool call that timed out, a `credential_process` that was killed), the request stays open for the 60 minutes, and the same call made again waits on it. An approval that was not fetched stays for 10 minutes: the same call made again takes it at once, then it is used up. A fetched result stays 30 seconds for the other callers waiting on the same id.

"Approve for this card" grants the lease and then settles every other open request of that card whose secrets its leases now cover: their callers get the secrets (audit decider `lease`), their attention requests close on every master, and the Mac notifications and the phone rows go. A Pushover message cannot be taken back; with one question per thing asked there is one message.

### Answering

`POST /v1/attention/{id}/resolve` takes the first answer. The same answer sent again succeeds and changes nothing. A different answer to a settled request gets HTTP 409 "This was already answered on the phone: Approve once."; a request that is gone gets 404 "This request is no longer open.". No answer text names a request id.

A master lists its own requests and mirrors its peers' every 4 seconds. A device that follows several masters (`AttentionFleet` in KanbanCodeRemoteKit) shows each request once, from the master that raised it. While that master's event stream is live its list decides: a mirror's copy of a request it no longer lists is not shown. Without the owner the mirror's copy shows, and the answer is forwarded.

On the phone a tapped answer shows "Sending..." on that option at once and the row takes no other tap (`AttentionAnswerState`). The row leaves when the master took the answer, or when it says the request was already settled (a short note at the top of the list says so). When the call fails the row stays with "Not sent: ..." and working buttons. The Mac sheet does the same.

### What Jev reads

For a caller the master matched to a card, Jev also gets the card's recent prompts, read from its transcript on the master that runs it (its own path, the peer mirror, or the session id under `~/.claude/projects`; Claude Code and Codex). `CardPromptReader` keeps the last 5 prompts entered in the session, each cut to its first 900 and last 400 characters, 4000 characters in all, and up to 20 older prompts before them, each cut to its first 200 characters, another 4000 in all, so an instruction given early in the task still counts. Jev gets them under `what_rogerio_asked_this_card`, oldest first, the older ones marked as shortened. The agent's `--reason` goes as `agent_reason_unverified`, a claim Jev trusts only as far as those prompts back it.

Text the harness writes (task notifications, messages between Claude sessions, compact summaries, command output, tool results) is left out. Every Kanban path that pastes another sender's text marks it, and prompts that open with a marker are listed under `messages_from_other_senders` with their sender, never as Rogerio's:

| Marker | Sent by |
|--------|---------|
| `[DM from @x]:` | `kanban dm` |
| `[Message from #c @x]:` | a channel message |
| `[Message from @x]:` | `kanban send` or `kanban subagent send` run inside card `@x` (on this master or forwarded to another) |
| `[Message from NAME (remote agent)]:` | `POST /v1/cards/{id}/prompt` with an agent-scope device token |
| `[Self-compact follow-up from this card]:` | the follow-up of `kanban self-compact` |
| `You are running as subagent card` | the goal a parent agent gives its subagent |
| `From NAME (Slack):` | the Slack bridge |
| the public share link warning | a message through a shared channel link |

Assistant commands (text starting with `/`) are never marked. Prompts Rogerio sends from the app (chat box, queued prompts, the phone with a full-scope token) and `kanban send` from a shell outside any card stay unmarked. When the transcript is not on the master, Jev judges without prompts.

### Restarts

An open approval survives a restart of its master. The broker keeps open requests and their attention requests in `pending.age`; at start it raises them again and keeps waiting from the original creation time, so the timeout is unchanged. A poll that arrives before that finishes waits for it. Answered results are not saved, since a result can carry values; its caller fetches it within a couple of seconds.

kv waits out a master that does not answer: on a refused connection, or HTTP 502/503, it prints `the master ... is not answering (...), probably restarting; waiting up to 2 min...` and retries with backoff (1, 2, 4, 8, then 10 seconds) for up to 2 minutes. A GET is always retried; a POST only when the connection was refused, so a request that may have reached the master is never sent twice. `kv exec-provider` does not wait: OpenClaw gets `UNREACHABLE` at once.

### What the human sees

The notification (Mac, Pushover, the phone app) has two lines:

- Title: who wants what, e.g. "Kanban Chat Claude wants AWS lw-dev access", "... wants to use the Slack user token", "... wants to change the AWS lw-dev rules", "... wants to use the Slack user token for 2 days" (a lease). Outside a card it reads "A process outside any card wants ...".
- Body: the agent's `--reason` and nothing else. A missing reason, or one that reads like a command or has under four words, shows "No reason given. Asked by: <command>" (the command on one line, cut to 140 characters), or "No reason given." when there is no command.

Secrets are named by their label: the `label` field when set (`kv label NAME "..."`, `kv add --label`), else one derived from the name (`aws:lw-dev` is "AWS lw-dev", `aws:lw-prod:read` is "AWS lw-prod read-only", `SLACK_USER_TOKEN` is "Slack user token").

Clicking the Mac notification opens the card and a sheet with every detail; on the phone the request's Details page shows the same. The details are the `vault` field of the attention request (`VaultApprovalDetails` in KanbanCodeRemoteKit): card, secrets with tier, the action, the proposed values of an edit, why the vault asks (tier, rate limit, Jev's verdict), the command, the working directory, the reason, the lease the card approval grants, and the process ancestry. `AttentionCopy` builds the title and body; questions and plan approvals use the same title style ("<card> is asking you a question", "<card> wants you to approve a plan", "<card> needs your permission").

When it reaches you: the Mac notification posts at once and the Dock icon shows the number of open requests. The phone (Pushover) gets one high priority message when the request is still open after the alert delay (Settings > Notifications, 3 min by default), or at once when the Mac is away. A macOS banner set to Temporary closes after 5 seconds, so Settings > Notifications warns when Kanban Code's alert style is not Persistent. When the request's card is open on screen (Kanban in front, its terminal or chat showing), a vault approval opens its detail sheet in the app instead of a notification; questions, plans and permission prompts show in the chat or terminal and get no notification. A sheet still open after the alert delay goes to the phone too, and the Mac notification posts once Kanban leaves the front. Sheets show one at a time: the next waits in line, the open one says how many wait after it, and a request answered elsewhere, withdrawn or timed out closes its sheet and the next one opens. The Dock count includes requests shown only in the app. Every raise, delivery decision and send result is in `~/.kanban-code/logs/kanban-code.log` under `[attention]`.

### Reasons

The reason is the only text the human reads before deciding, so it must be one short plain sentence saying what the agent wants to do and why, e.g. `--reason "Deploy the langwatch staging app to check the fix for the login bug"`. kv refuses (exit 2, before asking the master) a reason that is missing where required (`kv request`), shorter than four words, longer than one sentence (200 characters or a newline), or that reads like a command (starts with a command name, has flags or shell operators). `--reason` is optional for `kv run`, `env`, `get`, `aws`, `add`, `tier`, `rules`, `label`; `KV_REASON` in the environment stands in for it, under the same rules. `aws`, `kubectl`, `helm` and `terraform` reach `kv aws` through `credential_process` and cannot pass `--reason`, so agents set `KV_REASON` on those commands: `KV_REASON="Check the dev cluster pods after the nlpgo deploy" kubectl get pods`. When a request reaches the human without a usable reason, the pending message tells the agent how to write one next time.

## kv

`kv` talks to `http://127.0.0.1:<remote control port>` (`KANBAN_VAULT_URL` overrides it). It needs no token. Exit code 77 means denied.

`kanban vault ...` is the same command as `kv ...`: same arguments, output and exit code.

```
kv run NAME [NAME..] [--reason "..."] -- <cmd> [args..]
kv env [.env.vault] [--env E] [--project P] [--names] -- <cmd> [args..]
kv get NAME [--reason "..."]
kv request NAME[:scope] [NAME..] --reason "..."
kv aws <profile> [--reason "..."]
kv set KEY [--project P|.] [--env E] [--tier t] [--rules "..."] [--label "..."] [--reason "..."]   value on stdin (kv add is the same)
kv ls [--project P] | kv log | kv leases | kv status   (status also says who the master takes you for)
kv owner                                     the keys of the owner-only secrets, and how many are sealed
kv audit check                               broken chain, lines missing on a machine (exit 1 on a problem)
kv mv OLD NEW [--reason "..."] | kv mv --plan renames.json [--dry-run] --reason "..."   asks Rogerio, one approval
kv rm NAME [NAME..] --reason "..." | kv rm --plan names.txt [--dry-run] --reason "..."   asks Rogerio, one approval
kv tier NAME <tier> [--every-use-asks|--leases] | kv rules NAME "..." | kv label NAME "..."  [--reason "..."]   asks Rogerio
kv tiers <tier> [NAME..] [--value-prefix P].. [--every-use-asks|--leases] --reason "..."   one approval for all
kv import [--apply]
kv exec-provider                             OpenClaw exec SecretRef provider
```

`kv exec-provider` speaks OpenClaw's exec provider protocol (`{"protocolVersion":1,"ids":[...]}` on stdin, `{"values":{...},"errors":{...}}` on stdout); each id is a vault secret name. It never waits on a human: a secret that needs approval comes back as `NEEDS_APPROVAL` and its request stays open for the next `openclaw secrets reload`.

`kv rm` deletes secrets (`POST /v1/vault/delete`): the names given, or with `--plan` the names in a file (a JSON array, or one name per line, `#` for comments). All of them are one approval with Face ID, and the reason is required. `--dry-run` prints what each name would do (`delete`, `missing`, or the secret an earlier name resolves to) and asks nothing. A deleted secret becomes a tombstone that reaches the other replica like any edit, and each one gets an audit line with action `delete`. Its aliases stop resolving.

### kv env and the manifest

`kv env -- <cmd>` loads the project's own secrets for the environment as a group: every secret named `project/environment/*`, each under its key. The project is the one of the manifest's folder (the current folder without a manifest), or `--project`. A manifest's folder gets the group of its own project only. A folder without a manifest gets the group of the nearest project up to the repository root that has any secrets. A project with only its own secrets needs no manifest.

`.env.vault` is the manifest for what the group does not cover. `.env.prod.vault` is the manifest for `prod`.

| Line | Meaning |
|------|---------|
| `KEY` | The project's value for the environment, else the shared secret `KEY` |
| `KEY={{vault:NAME}}` | The secret `NAME` (any name or alias), under the variable `KEY` |
| `KEY=value` | A plain value, passed through |

The manifest's own lines win over the group. Without a file argument kv uses the manifest of the environment found from the current folder up to the repository root (in a worktree without one, the main checkout's). `kv env --names` prints which secret each variable would get, without values (`POST /v1/vault/resolve`).

`kv set KEY --project . --env prod` stores the current folder's project's own value; without `--project` the secret is shared. `kv import` names a second value of a key after the project and environment of the files it came from.

### AWS

AWS profiles are vault entries named `aws:<profile>` that carry a role (`roleArn`, optional session policies) and the name of the long-lived key secret (tier never, value `{"accessKeyId","secretAccessKey"}`). `kv aws <profile>` prints the `credential_process` JSON.

The long-lived key is owner-only, so the master cannot call STS. The approving device does: after biometry it opens the key, calls STS AssumeRole (or GetSessionToken without a role) itself, and sends only the temporary credentials to the master. It asks for the longest session STS grants: 12 hours for a role, then 8, 4, 2 and 1 when STS answers that the length exceeds the role's `MaxSessionDuration` (36 hours, then 12 and 1, for a session token). A role left at the IAM default allows one hour; `aws iam update-role --role-name R --max-session-duration 43200` raises it.

The master keeps the credentials a device minted for a profile in memory until 15 minutes before they expire. While it holds them, a release the policy allows (Jev for a judged profile, a lease or an approval for an ask profile) is served from them with no prompt, and the audit line says "credentials a device minted N min ago". When it holds none, the release asks with "its long-lived AWS key opens only with your Touch ID or Face ID", also for a judged profile Jev allowed. A profile with "every use asks" is minted on every approval and never kept. Before the owner keys exist the master calls STS itself for one hour, as it did.

Use it from `~/.aws/config`:

```
[profile lw-dev-vault]
credential_process = /Users/<you>/.local/bin/kv aws lw-dev
region = eu-central-1
```

`aws:lw-prod:read` adds the ReadOnlyAccess session policy to the prod role.

The `Command` of a `kv aws` request is the tool that asked, not `kv aws <profile>`: kv walks its process ancestry up to the shell or assistant that started the command and sends the outermost tool, with the nearest one after it, e.g. `kubectl get pods -n langwatch  (through: aws eks get-token --cluster-name dev)`. Jev judges that command, and the human sees it in the details and, without a reason, in the notification body.

Credentials a card got are handed to it again while they are valid for more than 15 minutes: no new decision, no Jev call, no STS call, not counted toward the rate limit, one audit line with decider `reuse`. kubectl runs `aws eks get-token` on every call and terraform once per provider, each running `credential_process`; the card holds the first credentials for their whole session, so the same ones again release nothing new. A profile with "every use asks" is never reused, nor is a caller outside a card. Editing the profile, or a restart of the master, ends the reuse.

## Audit log

Every line of `audit.jsonl` carries `prev`, the SHA-256 of the line before it as written. A changed or removed line breaks the chain at the next line. Lines from before the chain have no `prev`; the first chained line names the last of them.

A chain alone does not show a log cut at its end, so each master also sends its lines to its peers as it writes them (`VaultAuditSync`): it asks the peer where its mirror stands (`GET /v1/vault/audit/mirror?machine=`), and posts the lines after that (`POST /v1/vault/audit/mirror`), again every minute for what a peer missed while it was off. The peer adds them to `audit-mirror/<machine>.jsonl`. The route only adds: there is none that rewrites or deletes a mirror, and a line that does not follow the mirror's last one is kept and shows as a break. So the Mac holds a copy of the box's log that the box cannot change.

Approvals are also recorded where they were given: `device-approvals.jsonl` on the Mac, and on the phone under Machines > Vault key (kept in the app, shown there), each chained the same way, with the request, the answer, and what the device unlocked or minted.

`kv audit check` (`GET /v1/vault/audit/check`) reports, and exits 1 on any of them:

- a break in this machine's chain, in a mirror, or in the device record;
- lines a mirror here holds that the machine's own log no longer has ("MISSING box: 2 lines mirrored here are gone from its log"), with the first of them;
- on the Mac, an approval a log says was given "by mac" with no record of it on the Mac.

Run it on the Mac: that is where the box's mirror is. The same check is the "Check Now" button in the Owner Keys sheet. A peer that does not answer is named in a note and its mirror is checked only against itself.

## Bash hook

Kanban Code installs a `PreToolUse` hook on Bash (`~/.kanban-code/vault-hook.sh`) for Claude Code (`~/.claude/settings.json`) and for Codex (`~/.codex/hooks.json`, run as `vault-hook.sh --codex`). Codex runs a user hook only once its definition is trusted, so the installer also writes `[hooks.state."<hooks.json>:pre_tool_use:<n>:0"] trusted_hash` into `~/.codex/config.toml` with the hash Codex computes; Codex answers carry `permissionDecision: "allow"`, which Codex needs next to `updatedInput` and which does not skip its approvals or sandbox. Under Codex's `workspace-write` sandbox kv cannot reach the master on loopback, so commands run without the vault env; card sessions run Codex without the sandbox. rush sessions run `claude -p`, which loads the same Claude Code hook. In a project with a `.env.vault` manifest (searched from the session's directory up to the repository root; in a linked git worktree without its own, the same folder of the main checkout), `kv hook` rewrites the command to:

```
__kv_env="$(kv env /path/.env.vault --export --command-b64 <command>)" || exit $?
eval "$__kv_env"; unset __kv_env
<the original command>
```

so the shell loads the secrets first and `cd` and shell syntax behave as written. In this mode secrets that need a human are skipped (the command runs without them and kv says how to ask), Jev's allow is reused for 10 minutes per card and secret, and these releases do not count toward the rate limit. If the master cannot be reached, the command runs without the vault env.

## Where secrets live

Every `.env`, `.env.local` and `.env.*` under `~/Projects` on the Mac and the box holds plain config only. Its secrets are references in a gitignored file next to it:

| Plaintext file | References |
|------|---------|
| `.env`, `.env.local`, `.env.development`, `.env.portless` | `.env.vault`, environment `dev` (one per folder) |
| any other `.env.X` | `.env.X.vault`, environment `X` |
| `.env` that is a production file (`save-to-memory`, `pinacle`) | `.env.prod.vault`, environment `prod`; `.env.vault` there is for `dev` only |

The manifests are short: the project's own secrets come with the group, so a manifest lists the shared keys it uses, the variables that take another secret, and nothing else. A folder whose secrets are all its own keeps a manifest with only a comment, which is what makes the Bash hook load the group there.

Consumers:

- Claude Code and Codex Bash commands: the hook above.
- Interactive zsh outside Claude Code: `~/.zshrc` wraps `pnpm npm npx yarn bun make uv uvx node python python3 tsx deno` the same way (hook mode, in a subshell).
- Deploys that copy a `.env` to the host (`rchaves-platform`, `save-to-memory` `scripts/deploy.sh`): the script appends the secrets with `kv env <file> -- printenv` into a temporary copy and sends that.
- Anything else: `kv env .env.vault -- <cmd>`, or `kv env .env.X.vault -- <cmd>` for a named env file.

AWS on the Mac: `~/.aws/credentials` holds only the `[default]` canary; every profile in `~/.aws/config` (`lw-dev`, `lw-staging`, `lw-artifacts`, `lw-prod`, `lw-prod-read`, `lw-root-tf`, `sf-dev`, `sf-prod`, `sf-prod-read`) uses `credential_process = kv aws <profile>`, as on the box.

Plaintext that stays, and why:

- Production services on the box read their own env files at runtime: `/opt/rchaves-platform/.env`, `/opt/save-to-memory/.env`, `/opt/inbox_narrator/.env`, `/root/.openclaw/setup/hindsight-db/.env`, `gateway.auth.token` in `/root/.openclaw/openclaw.json`.
- Commented-out env lines and `.env.worktree-backup` copies are gone; their values are in the vault (canary tripwires such as `CANARY_LANGWATCH_API_KEY` stay as they are).
- LangWatch dev secrets its tooling writes into `.env` when missing (`LW_GATEWAY_INTERNAL_SECRET`, `LW_GATEWAY_JWT_SECRET`, `LW_VIRTUAL_KEY_PEPPER`, `LANGY_INTERNAL_SECRET`, `LWQL_*_PASSWORD`): local random values, kept in the file.
- Local DSNs with throwaway passwords, URLs, paths and ids.
- Tool credential stores read by the tools themselves: `~/.ssh`, `~/.config/gh`, `~/.git-credentials`, `~/.config/gcloud`, `~/.config/stripe`, Claude and Codex logins, local CA keys (`~/.portless`, `~/.minikube`, `~/.docker`).
- Keys inside code, fixtures and notebooks, and in `~/.claude/file-history`: content, not config. Transcripts, histories and logs are cleaned by the scrubber below.

## Pasted secrets

The card chat composer, the queued prompt editor, channel composers and the iPhone composer check a prompt before sending it (`SecretDetector` in KanbanCodeRemoteKit, a port of LangWatch's redaction rules). When it holds a credential they offer to save it: one editable name per secret, taken from `NAME=value` / `NAME: value` / `"NAME": "value"` or the vendor (`OPENAI_API_KEY`, `GITHUB_TOKEN`...), with `_2`, `_3` when the vault already has that name. Yes adds each as a judged secret and sends the prompt with `{{vault:NAME}}` in its place plus a line telling the agent to use `kv run NAME -- <cmd>`; No sends it unchanged. On the Mac, Return or y is Yes, Esc or n is No. Placeholders (`sk-xxxx...`, `<your-key>`, AWS's `...EXAMPLE`) never ask.

rush's own message boxes (a Session's box and the Prompt) get the same check from the `kanban-vault` rush plugin in `plugins/rush/kanban-vault`, a Go port of the same rules. It answers rush's `ui.intercept` with an ask, saves with `kv add NAME --tier judged` through the manifest's `exec`, and rewrites the message in place so paste chips stay chips. `make rush-plugins` (`Scripts/rush-plugins-install.sh`) builds it into rush's plugin folder and runs `rush plugin approve` at a terminal. rush runs installed plugins only on macOS, where it sandboxes them, so the script installs nothing on a Linux machine.

## Scrubber

A secret pasted into a chat, or printed by a command, stays in the transcript. The scrubber replaces it there with a `{{vault:NAME}}` reference. Each master runs it over its own files, once a day (04:30 unless changed) and on demand. It cleans local files only: what already reached a model provider, a remote log or a backup elsewhere is not touched, so a key that leaked still needs rotating.

Settings > Vault has the switch, the time, Dry Run, Run Now and the last result of every master. The schedule set there is sent to the peers (`PUT /v1/scrub/schedule`); each master keeps it in `~/.kanban-code/scrub/schedule.json`. From a shell:

```
kv scrub --dry-run     counts per folder and per secret name, nothing changes
kv scrub               a run now
kv scrub --status      schedule and the last run
kv scrub --at 03:00 | --on | --off
```

### What it reads

- Claude Code: `projects/`, `history.jsonl` and `paste-cache/` of `~/.claude` and of every rush account folder (`~/.config/rush/claude/*`; folders that link to the same place are read once).
- Codex: `~/.codex/sessions`, `archived_sessions`, `history.jsonl`.
- rush: `~/.config/rush/drafts.json`, `box-drafts`, and its cache folder.
- Kanban Code: `links.json` and its backups, `human-messages`, `logs`, `channels`, `chat-drafts`, `peers` (transcript copies of the other masters' cards), `context`, `commands`, `hook-events.jsonl`. Never `vault/`, `settings.json` or the device and sync files.
- OptMem: `~/.optmem/memory`, `WAKE.md`, `spool`, `audit`. Its log and tree are fixed-width records with no checksum, and a replacement keeps every record's width, so memo reads them as before.

Images, archives, databases and files that start with a zero byte are skipped. A file written in the last 10 minutes belongs to a session in progress and waits for the next run; Kanban's current `links.json` and log are always in that state, so they are cleaned once they rotate into a backup.

### What it finds

1. Values the vault holds, by fingerprint. `vault/scrub-index.json` has, for each value, its length, a keyed 32-bit fingerprint of its first eight bytes and a keyed HMAC of the whole (`ScrubIndex`), under a key derived from the vault key. A scan reads only this index, so it never handles a value of any tier. The master rebuilds the index when `vault.age` changes. Each value is indexed as stored and as JSON writes it (escaped once, twice, and with `\/`); a JSON value also by its long members, a URL by its credential parts. Values under 16 bytes, and ones that do not look minted (no digits, a word, a path, a host), are left out, so a vault entry holding `eu-central-1` does not rewrite the transcripts.
2. Keys in a vendor's format the vault does not hold: the `SecretDetector` rules the composers use for pasted keys, limited to the fixed formats (`sk-...`, `ghp_...`, `xoxb-...`, `AIza...` and the vendor list), with placeholders and low-entropy identifiers left out. Each is saved first as `scrubbed/found/<VENDOR_NAME>_<fingerprint>`, tier ask, tag `scrubbed`, then replaced. The name comes from the value, so two masters that find the same key save it under the same name. `kv ls --project scrubbed` lists them; rename the ones worth keeping (`kv mv`) and delete the rest (`kv rm`).

JWTs, bearer tokens, URL passwords, PEM keys and `password=` style assignments that are not in the vault are not replaced: without a human looking they match too much that is not a secret.

### How it replaces

In place, and every line keeps its byte length: the file keeps its size, its inode and the offset of every line, so the transcript copies on the other master, cached offsets and a process appending to the file are not disturbed. The modification time is put back.

- The value becomes `{{vault:NAME}}`. When that is longer than the value, it becomes `{{vault:#<start of the secret's fingerprint>}}`; `kv ls --json` shows each secret's `fingerprint`.
- The bytes left over become spaces: in `.json` and `.jsonl` files after the closing quote of the string the value was in (where JSON allows them), in other files right after the reference.
- A `.jsonl` line that parsed before must parse after, and a `.json` file likewise, or it is left alone. A value that starts right after a backslash is left alone.

### Safety

- A dry run changes nothing and reports counts per folder, per file and per secret name.
- The first real run on a machine first copies every file it is about to change, gzipped, into `~/.kanban-code/scrub-backups/<date>/` with a `manifest.json` of the original paths (`gunzip -c <file> > <path>` restores one). These copies hold the secrets: they are deleted after 7 days, and no sync entry covers that folder.
- Reports (`scrub/last-run.json`, `last-dry-run.json`) and the `[scrub]` log lines carry names, paths and counts, never a value.
- Files the last run left clean are skipped by size and time until the vault changes.

## Remote API

See the routes list in `Sources/KanbanCodeCore/Adapters/RemoteControl/RemoteVaultRoutes.swift`. Listings never carry values. Adding a new secret is allowed to any local caller; replacing a value, changing a tier or rules, or deleting asks Rogerio, except from Settings > Vault in the app. A peer master's token reaches only the replica, the card token check and the audit log mirror. The scrubber routes are in `RemoteScrubRoutes.swift`.
