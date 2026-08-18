# Flag-sharing reports

## The short version

Because each player has a unique flag, a shared flag is easy to spot. If someone
submits a flag that is not theirs but does belong to another account, the plugin
quietly records that as a flag-sharing incident and shows it to admins. The
person submitting just sees "Incorrect", the same as any wrong answer, so they
do not learn whether they guessed a real flag or not.

## How it works

When a submission does not match the submitter's own flag, the plugin does one
extra check before giving up. It walks through the other accounts and, for each
one, recomputes what that account's flag for this challenge would be. If the
submitted string matches any of them, it means the submitter typed in a flag
that was minted for a different account. That is the signature of flag sharing.

When that happens the plugin records an incident with:

- the challenge it happened on
- the account that submitted the flag
- the account the flag actually belongs to
- the flag value that was submitted
- a count and a last-seen time

If the same pair of submitter and owner trips the check again on the same
challenge, the existing record is updated: the count goes up and the timestamp
moves forward, rather than filling the table with duplicates. The event is also
written to the CTFd submissions log.

## What the submitter sees

Nothing unusual. The response is a plain "Incorrect". There is no hint that the
check happened, which avoids turning the report system into an oracle that tells
cheaters which strings are real flags.

## Where admins see it

The plugin adds a "Flag Reports" item to the CTFd admin menu that opens a page
at `/admin/instancer/reports`. It lists every incident with names resolved for
the submitter, the owner, and the challenge, along with the submitted value, the
number of times it happened, and when it was last seen, sorted with the most
recent first. Only admins can reach it.

## How to read a report

A single incident is not always proof of cheating. People paste things into the
wrong box, and in some setups teammates share one account legitimately. Treat
the report as a strong signal to look closer: repeated incidents between the
same two accounts, or a whole cluster of accounts submitting one account's
flags, is the pattern worth acting on. Use your own event rules to decide what
to do about it.

## A note on privacy and fairness

The mechanism only compares against flags it derives on the fly from the same
secret. It does not store a list of everyone's flags, and it does not expose one
player's flag to another. It simply answers one question when a wrong flag comes
in: did this happen to be somebody else's flag.
