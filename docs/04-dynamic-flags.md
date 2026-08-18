# Per-user dynamic flags

## What they are

Every player gets a different flag for the same challenge. There is no single
correct string to leak. If one player passes their flag to another, it will not
score for the second player, and the attempt is recorded. See
`05-flag-sharing-reports.md`.

## How the flag is derived

The flag is computed, not stored. When the plugin needs a player's flag for a
challenge, it takes an HMAC over the string `challenge_id:account_id` using the
server secret as the key, then takes the first 24 hex characters of the digest
and wraps them in the challenge's flag prefix:

```
digest = HMAC_SHA256(SECRET_KEY, "<challenge_id>:<account_id>")
flag   = "<prefix>{" + digest[:24] + "}"
```

Because the input is the pair of challenge and account, the same player always
gets the same flag for the same challenge, and two different players get
different flags. Nothing is written to the database, so there is no flag table
to leak or keep in sync.

## How submissions are checked

When a player submits a flag, the plugin recomputes that player's expected flag
and compares it in constant time. If it matches, the solve is accepted and the
plugin asks the instancer to stop that player's container right away, so a
solved instance does not keep running until its time to live expires.

## How the flag reaches the challenge

When the instancer starts a container, it injects the player's flag as the FLAG
environment variable. The two sample challenges simply read FLAG and print it on
success. Your own challenges do the same, so a challenge image never contains a
real flag baked in.

## Rotating the secret

Because every flag is derived from `SECRET_KEY`, changing that value invalidates
every flag that has already been issued. That is a useful emergency lever if you
believe the secret leaked, but it also means you should keep `SECRET_KEY` stable
for the duration of an event.

## Why this stops flag sharing from working

There is no shared answer. A flag is only valid for the one account it was
derived for. Handing it to someone else does not help them, and the plugin
notices when a submitted string matches another account's derived flag.
