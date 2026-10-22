# Release a node image

When to use it: the nodes need a new or changed image (a package, a new
image directory, a base bump), from a PR in `cluster-images-wip` to every
node running the new tag.

Inputs: push access to both repos, a lab session
([lab-session.md](lab-session.md)), and the Slurm cluster healthy before you
start (`make slurm-ready`).

## Steps

1. **Change the image repo, not the server.** In `cluster-images-wip`, edit
   `images/<name>/packages.txt` or the `Containerfile`, or add a new
   `images/<name>/`. Never `wwctl image shell` the live image: that copy
   traces to no commit.
2. **Run its gates:** `make lint` in `cluster-images-wip` (rc=0). For a
   local build check, `make build IMAGE=<name>`.
3. **Push, PR, wait for CI, merge.** Merging to `main` runs `images.yml`,
   which publishes `ghcr.io/<owner>/cluster-images-wip/<name>:sha-<12>` and
   moves `latest`.
4. **Read the tag** from the Actions run summary of the merge commit. It is
   `sha-` plus the first 12 characters of the merge commit. Note the tag the
   nodes run now (`sudo wwctl node list -a <node> | grep -i image`). That is
   your rollback tag.
5. **Canary one node:** `make rolling-update TAG=sha-<new> NODES=<node>`.
   The play drains, reboots onto the new image, waits for the node to report
   the tag to NetBox and slurmd to return, then resumes it. On failure it
   puts the old image back and stops.
6. **Check the canary** with the issue's own check (the package is there,
   the job runs), then `make slurm-ready`.
7. **Roll the rest:** `make rolling-update TAG=sha-<new>`, one node at a
   time.
8. **If anything is wrong after the rollout,** `make rollback TAG=sha-<previous>`.
   Then open a defect ([fix-a-cluster-defect.md](fix-a-cluster-defect.md)).
9. **Record the release** on the issue: the image PR, the tag, the previous
   tag, and the checks below.

## Done when

- [ ] Image PR merged and its CI green -> `git log -1 origin/main` in `cluster-images-wip`
- [ ] The tag exists in GHCR -> the `images.yml` run summary for the merge commit
- [ ] Every node reports the new tag -> `image_tag` on each device in NetBox, and `sudo wwctl node list -a <node> | grep -i image`
- [ ] Slurm healthy after the rollout -> `make slurm-ready` exits 0
- [ ] The change the issue asked for is visible on a node, output pasted
- [ ] The previous tag is written on the issue, so a rollback is one command
- [ ] `docs/operations.md` "Images" updated if the procedure changed

## Known traps

- `rolling-update` refuses `TAG=latest`. Always roll a pinned `sha-` tag.
- `lab/local.env` sets `WAREWULF_IMAGE_TAG`, the tag a fresh converge or
  rebuild imports. If it still says an older tag or `latest` after a release,
  check what a new node gets (`make drill-reprovision` on one node) before
  calling the release done.
- Never test an image by editing it on the head node. Anything worth keeping
  goes into `cluster-images-wip` and through CI.
