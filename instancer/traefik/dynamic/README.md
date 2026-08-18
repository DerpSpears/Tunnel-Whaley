# Traefik dynamic directory

Traefik watches this directory with its file provider. Two kinds of files live
here:

- `ctfd.yml` is committed. It is the static catch-all route that sends every
  request that is not an instance path to CTFd. It has the lowest priority so
  that the more specific per-instance routes always win.
- `*.yml` files named after an instance id are written at runtime by the
  instancer, one per live challenge instance, and removed when the instance is
  destroyed. These are runtime state and are ignored by git.

You should never edit the per-instance files by hand. If you need to change how
CTFd itself is routed, edit `ctfd.yml`.
