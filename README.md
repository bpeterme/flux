# flux — Git + DVC Auto-Router

Automatic file routing between any Git remote (GitLab, GitHub, etc.) and
Cloudflare R2 (via DVC) based on binary/text detection and file size —
no manual decisions, no extension lists to maintain.

**flux** gives you a single mental model and a set of simple aliases that
replace the split `git` / `dvc` command pair with one unified workflow.

## How it works

Every `git commit` triggers a pre-commit hook that inspects each staged file:

```
git add .  &&  git commit -m "..."
                    │
                    ▼
            pre-commit hook
                    │
        ┌───────────┴───────────┐
        │                       │
   binary file?         text but > 5 MB?
   (any size)                   │
        │                       │
        └──────────┬────────────┘
                   │
                   ▼
             dvc add → R2          everything else
          (pointer .dvc            stays in Git
          file stays in Git)       → GitLab / GitHub / etc.
```

Binary detection uses the same heuristic as Git itself (`grep -qI`): if a file
contains null bytes, it's binary. This catches `.mp4`, `.psd`, `.db`, `.zip`,
`.dmg`, and any future format automatically — no extension list to maintain.

The hook locates DVC automatically, checking all common Homebrew install
locations before falling back to PATH. No hardcoded paths, no per-machine
configuration needed.


## .gitignore and .dvcignore stay in sync automatically

At the end of every commit, the hook scans all `.gitignore` files in the repo
and regenerates a sibling `.dvcignore` next to each one. You never touch
`.dvcignore` manually.

**Mental model: anything in `.gitignore` is invisible to both Git and DVC.**
Nothing listed there will be pushed to any remote — Git or R2.

This includes entries DVC itself adds to `.gitignore` when it takes over a
binary file (e.g. `/clip.mp4` in `footage/.gitignore`) — those are immediately
mirrored to `footage/.dvcignore` in the same commit, so DVC directory scans
also skip them.


## One-time setup

### Prerequisites

- macOS with Homebrew.
- A Cloudflare R2 bucket with an API token.
- A Git remote configured on the repo (`git remote add origin ...`).

### 1. Install flux

```bash
brew tap bpeterme/flux
brew install bpeterme/flux/flux
pip install "dvc[s3]"
```

### 2. Configure flux (once per machine)

```bash
flux config
```

`flux config` prompts for your R2 bucket, account ID, access key, and secret key.
Non-sensitive values are saved to `~/.config/flux/flux.env`; credentials go
directly into macOS Keychain — nothing secret ever touches a file.

On subsequent runs `flux config` shows your current settings and lets you
update or remove them.

### 3. Add flux to each repo

```bash
cd your-project
flux add
```

`flux add` reads global config, initialises DVC, configures the R2 remote, and
installs the pre-commit hook. Run it once per repo.

## Managing config

```bash
flux config           # show current settings (or run initial setup if unconfigured)
```

Config is split by sensitivity:

| Setting | Storage |
|---|---|
| R2 bucket, account ID | `~/.config/flux/flux.env` |
| Access key ID, secret key | macOS Keychain |
| R2 folder, threshold, verbose | per-repo `git config` |

## Credentials and CI

For CI or headless environments, configure the DVC remote directly using
credentials from your CI secrets store:

```bash
dvc remote modify --local r2remote access_key_id     "$R2_ACCESS_KEY_ID"
dvc remote modify --local r2remote secret_access_key "$R2_SECRET_KEY"
```


## Daily workflow

```bash
git add .
git commit -m "your message"   # hook fires, routes files automatically
flux sync                       # git pull + dvc pull + git push + dvc push
flux pull                       # download the latest (git pull + dvc pull)
```

Or broken out manually:

```bash
git push   # sends Git content → GitLab / GitHub
dvc push   # sends large/binary files → Cloudflare R2
git pull   # fetches Git content from remote
dvc pull   # fetches large/binary files from R2
```

### Using GitHub Desktop

GitHub Desktop fires the pre-commit hook normally when you commit. The hook
finds DVC automatically regardless of which Homebrew install you have, so
commits work as expected from the GUI.

The one limitation: `dvc push` and `dvc pull` are not Git commands, so GitHub
Desktop has no concept of them. Use `flux sync` or `flux pull` from a terminal
for those steps.

Adjust settings without editing any files:

```bash
# Change the size threshold (default: 5 MB)
git config dvc-router.size-threshold-mb 10

# Enable verbose output from the hook (useful for debugging)
git config dvc-router.verbose true

# Disable verbose output
git config dvc-router.verbose false
```

These settings are stored in the repo's local `.git/config` so they apply
per-repo and are never committed.


## Works with any Git remote

The hook is completely Git-remote-agnostic. You can have:

- Some repos on GitLab, some on GitHub
- A self-hosted Forgejo or Gitea instance
- Any mix across machines

The only thing that's repo-specific is the DVC remote (R2), configured once
per repo in `.dvc/config`. The Git remote is whatever `git push` points to.


## Homebrew: system vs user-local

The hook checks these DVC locations in order:

| Location | When used |
|---|---|
| `/opt/homebrew/bin/` | System Homebrew, Apple Silicon |
| `/usr/local/bin/` | System Homebrew, Intel Mac |
| `~/.homebrew/bin/` | User-local Homebrew (common) |
| `~/homebrew/bin/` | User-local Homebrew (alternative) |
| `PATH` fallback | pip-installed, conda, or anything else |

No configuration needed — whichever install exists on your machine is used.


## File structure after first use

```
my-project/
├── .dvc/
│   ├── config          ← committed (R2 endpoint, bucket — no secrets)
│   └── config.local    ← git-ignored (contains your secret key)
├── .gitignore          ← you maintain this; source of truth for ignores
├── .dvcignore          ← auto-generated from .gitignore, never edit manually
├── src/                ← tracked by Git → GitLab / GitHub
├── configs/            ← tracked by Git → GitLab / GitHub
└── footage/
    ├── .gitignore      ← DVC adds /clip.mp4 here automatically
    ├── .dvcignore      ← auto-generated from footage/.gitignore
    ├── clip.mp4        ← git-ignored, stored in R2
    └── clip.mp4.dvc    ← tiny pointer file, tracked by Git
```


## Setting up on another machine

```bash
# 1. Install flux (if not already)
brew tap bpeterme/flux && brew install bpeterme/flux/flux
pip install "dvc[s3]"

# 2. Configure flux (stores credentials in macOS Keychain)
flux config

# 3. Clone and add flux to the repo
git clone <your-remote-url>
cd <repo>
flux add

# 4. Pull large files from R2
dvc pull
```


## Edge cases

### Handled automatically by the hook

**File grows past threshold (Git → DVC)**
If a file was previously committed to Git and then grows above the size
threshold (or becomes binary), the hook detects the transition, removes it
from the Git index cleanly, and hands it off to DVC. The old small version
remains in Git history — run `git filter-repo` if you need to scrub it
entirely (rare, and a one-off manual operation).

**File shrinks below threshold (DVC → Git)**
At the start of every commit the hook reads the full list of DVC-tracked
files directly from `git ls-files '*.dvc'` — the authoritative source,
independent of `.gitignore`. For each, it checks the current on-disk size
and binary status. If a file is now text and below the threshold (e.g. a
database that has been compacted, or a file that was regenerated smaller),
it is automatically migrated back to Git: `dvc remove` cleans up the pointer
and `.gitignore` entry, and the file is staged as a normal Git file in the
same commit.

Note: `dvc gc --cloud --all-branches` runs automatically after migration
to purge the now-unreferenced R2 data. The `--all-branches` flag ensures
data referenced by other branches is preserved.

**File deleted**
When a DVC-tracked file is deleted from disk, its `.dvc` pointer file would
otherwise remain in Git as a broken reference. The hook scans all tracked
`.dvc` pointers at the start of every commit, detects missing targets, and
stages the pointer for deletion automatically. The stale entry in `.gitignore`
is also cleaned up so it doesn't accumulate.

**File renamed**
Same mechanism as deletion — the old `.dvc` pointer's target is gone, so the
hook removes it. The file at its new name gets staged normally, routed fresh
by the hook, and a new `.dvc` pointer is created. One commit handles both
the cleanup and the re-routing.

---

### Documented — handle manually if needed

**Pre-existing large/binary files**
Files already committed to Git before `flux add` was run are never touched
by the hook. Run this one-time to migrate them:

```bash
# Find all Git-tracked files that would now be routed to DVC
git ls-files | while read -r f; do
  size=$(wc -c < "$f" | tr -d ' ')
  if ! grep -qI . "$f" 2>/dev/null || (( size > 5242880 )); then
    dvc add "$f"
    git rm --cached "$f"
    git add "${f}.dvc"
  fi
done
dvc push
git commit -m "migrate pre-existing large/binary files to DVC"
```

**Merge conflicts on DVC-tracked files**
If both machines modify the same DVC-tracked binary file, `git pull` may
produce a conflict in the `.dvc` pointer file (which is plain text). The
actual binary content in R2 is safe — both versions exist there. To resolve:

```bash
# Keep your local version
git checkout --ours footage/clip.mp4.dvc
git add footage/clip.mp4.dvc

# Or keep the remote version
git checkout --theirs footage/clip.mp4.dvc
dvc pull                            # fetch whichever version you kept
git add footage/clip.mp4.dvc
git commit -m "resolve DVC merge conflict"
```


**Hook not firing**
For a quick manual check:
```bash
ls -la .git/hooks/pre-commit   # must exist and be executable
chmod +x .git/hooks/pre-commit
```

**DVC not found by the hook**
Enable verbose mode to see which path is being resolved:
```bash
git config dvc-router.verbose true
```
If DVC is installed somewhere not in the candidate list, add its directory
to your shell's PATH before committing, or symlink it to `~/.homebrew/bin/`.

**DVC push/pull failing**
```bash
dvc remote list                                               # verify remote is configured
dvc remote modify --local r2remote secret_access_key <key>   # re-add secret if missing
```

**File ended up in Git that should be in DVC**
```bash
dvc add path/to/bigfile
git rm --cached path/to/bigfile
git add path/to/bigfile.dvc .gitignore
git commit -m "move bigfile to DVC"
dvc push
```

**Check what DVC is tracking**
```bash
dvc status       # local vs cache differences
dvc status -c    # local vs remote (R2) differences
```

**Clean up unreferenced R2 data**
This runs automatically after any DVC → Git migration. If it ever fails
or you need to run it manually (e.g. after manually removing a `.dvc` file):
```bash
dvc gc --cloud --all-branches   # preserves data referenced by any branch
dvc gc                          # also cleans local cache
```


## Running tests

flux has a bats-core test suite covering the core hook logic (routing, migration,
orphan cleanup, and `.dvcignore` sync). Tests use a mock DVC binary so no real
DVC installation or R2 credentials are needed.

```bash
# Install bats-core first
brew install bats-core        # macOS
sudo apt-get install bats     # Linux

# Run unit tests (hook logic — fast, no dependencies)
./tests/run.sh tests/unit.bats

# Run integration tests (CLI flow)
./tests/run.sh tests/integration.bats

# Run all tests
./tests/run.sh
```

Tests run automatically on every push to `dev` and `main`, and on pull requests
targeting `main`, via GitHub Actions (`test.yml`). The release workflow
(`release.yml`) runs tests as a gate before tagging and publishing.
