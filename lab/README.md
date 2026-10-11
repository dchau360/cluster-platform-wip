# lab/

Host-specific configuration. One file is tracked, one is not.

| File | Tracked | Contents |
| --- | --- | --- |
| `local.env.example` | yes | every variable, named and documented. Host values blank, lab values at their defaults. |
| `local.env` | **no** | the real values, on the lab host only. |

```sh
cp lab/local.env.example lab/local.env
$EDITOR lab/local.env
```

## Why it is split this way

There is exactly one place a host-specific value may live. That is what
makes the CI leak gate meaningful: a value found anywhere else is a bug by
definition, not a judgement call.

The `host-values` job fails if:

- `local.env` is tracked;
- a value from `local.env` that differs from the shipped default appears in
  a tracked file;
- a tracked file contains an IPv4 literal outside the provisioning segment
  and the RFC 5737 documentation ranges;
- a tracked file contains a MAC address that is not locally administered.

The job prints variable **names** only. It never prints a value, so the
log of a failing run is itself safe to read in public.

## Supplying local.env to CI

The exact-match check needs the real file. It is stored as the repository
secret `LAB_LOCAL_ENV`, written to `lab/local.env` at the start of the job,
and never echoed:

```sh
gh secret set LAB_LOCAL_ENV --repo dchau360/cluster-platform-wip < lab/local.env
```

Fork pull requests get no secret. The pattern checks still run, so a
leaked address or a real MAC still fails the build from a fork.

The tradeoff is deliberate and worth stating: the values in that secret are
low-sensitivity, an address on a private network and a login name, and they
are masked in logs and withheld from forks. Holding them lets CI catch an
exact leak that no pattern can. If that tradeoff is ever unwanted, delete
the secret: the job keeps working and keeps failing on patterns.
