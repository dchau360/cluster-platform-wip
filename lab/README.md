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
- `local.env.example` **assigns a value** to a variable named in
  `local.env.example`'s companion list `host-specific.vars`, or the two files
  disagree about which variables those are;
- a variable set in `local.env` is not declared in `local.env.example`;
- a value from `local.env` appears in a tracked file;
- a tracked file contains an IPv4 literal outside the provisioning segment
  and the RFC 5737 documentation ranges;
- a tracked file contains a MAC address that is not locally administered.

The job prints variable **names** only. It never prints a value, so the
log of a failing run is itself safe to read in public.

## Declaring a variable host-specific

Two files, and the gate requires them to agree.

`lab/host-specific.vars` is a tracked list of **names**, never values. It is
the authority:

```
LAB_HOST_SSH
LAB_WSL_USER
LAB_LAN_CIDR
LAB_LAN_PROBE_IP
```

`local.env.example` carries a matching inline tag, so a reader sees the rule
next to the variable:

```sh
LAB_HOST_SSH=          # host-specific
#LAB_WSL_USER=         # host-specific
```

For every name on the list, the gate applies two rules:

1. the example may not assign the variable a value;
2. its value from `local.env` is searched for in every tracked file with **no
   exemption of any kind** — not the short-value exemption, not the
   purely-numeric one, and not the "equals the shipped default" one.

### Why the list and not just the tag

The tag alone cannot be the authority, and the reason is worth keeping.

The mistake the gate exists to catch is someone typing a real value over the
commented declaration:

```sh
#LAB_WSL_USER=          # host-specific     becomes
LAB_WSL_USER=ubuntu
```

One edit, and the tag goes with it. A gate that inferred its own rules from
the tags would see one fewer tagged variable and report `ok` — it would stop
objecting at exactly the moment it was needed. This was a real hole in the
first version of this check, found by writing the test for it.

Reading the list instead, that same edit fails twice: the name is still
listed, so the missing tag is a finding and the assigned value is a finding.
Drift in the other direction — a tag with no list entry — is a finding too.
Removing protection therefore takes an edit to `host-specific.vars`, a file
that does nothing else and reviews in one line.

### Why rule 1 exists at all

The exact-match check has to let
through any value equal to the example's, or every shared default
(`PROV_CIDR`, `NODE_COUNT`) raises a finding. But the exemption is keyed on
the example, so writing a real host value *into* the example is what switches
the check off for that variable: the leak becomes the reason the gate goes
quiet. And the example is the file that lives in the repository, so it is the
file someone edits by mistake. Rule 1 removes the hole, and it needs no
secret, so it runs on fork pull requests too.

This is not hypothetical. `LAB_WSL_USER=ubuntu` shipped in the example on the
first commit, and both rules now fail it.

### Consequence: pick tagged values that are not common words

No exemptions means exactly that. A tagged variable set to a short common word
will match tracked files that have nothing to do with the lab —
`LAB_WSL_USER=ubuntu` matches `runs-on: ubuntu-latest` in the workflow.

The gate is right to be literal; a gate with a silent hole is worse than one
that is occasionally pedantic. So set a tagged variable in `local.env` only
when you actually need to override, and prefer a value specific enough to be
worth matching. `LAB_WSL_USER` is unset on the lab host for this reason: the
code's `${LAB_WSL_USER:-${USER:-$(id -un)}}` already gives the right answer
there, so there is nothing to override and nothing to match.

## Supplying local.env to CI

The exact-match check needs the real file. It is stored as the repository
secret `LAB_LOCAL_ENV`, written to `lab/local.env` at the start of the job,
and never echoed:

```sh
gh secret set LAB_LOCAL_ENV --repo dchau360/cluster-platform-wip < lab/local.env
```

**Each repository has its own `lab/local.env` and its own secret.** They are
not interchangeable. This one holds the networking and node-shape variables;
`cluster-images-wip` holds the `IMAGE_*` and `WAREWULF_*` ones. Seed one
repository's secret from the other repository's file and the "every variable
in `local.env` is declared in the example" check fails — which is the check
doing its job.

Fork pull requests get no secret. The pattern checks still run, so a
leaked address or a real MAC still fails the build from a fork.

The tradeoff is deliberate and worth stating: the values in that secret are
low-sensitivity, an address on a private network and a login name, and they
are masked in logs and withheld from forks. Holding them lets CI catch an
exact leak that no pattern can. If that tradeoff is ever unwanted, delete
the secret: the job keeps working and keeps failing on patterns.
