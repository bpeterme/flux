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

The hook locates DVC automatically, checking all common Homebrew and Linuxbrew
install locations before falling back to PATH. No hardcoded paths, no
per-machine configuration needed.


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

- Homebrew (macOS) or Linuxbrew (Linux) — system-wide or user-local, both
  detected automatically.
- A Git remote already configured (`git remote add origin ...`).
  Works with GitLab, GitHub, or any other Git host — mix freely across repos.
- A Cloudflare R2 bucket created in the Cloudflare dashboard with an API token.

### Install flux

**Via Homebrew (recommended):**
```bash
brew tap bpeterme/flux
brew install bpeterme/flux/flux
```

This installs `flux-setup` as a system-wide command.

**From source:**
```bash
git clone https://github.com/bpeterme/flux.git
```

### Run setup in your repo

```bash
flux-setup              # if installed via Homebrew
# or
./path/to/flux/setup.sh # if running from source
```

The script will:
1. Detect your Homebrew/Linuxbrew installation automatically
2. Install `dvc` via Homebrew and `dvc-s3` via pip (the S3/R2 plugin)
3. Read R2 credentials — from environment variables, platform secret store,
   or interactive prompt (see [Credentials](#credentials) below)
4. Auto-detect the R2 folder name from your Git remote URL, ask to confirm
5. Ask for your preferred size threshold (default: 5 MB)
6. Optionally enable verbose hook output
7. Optionally install flux shell aliases
8. Install the pre-commit hook
9. Update `.gitignore` with DVC-specific entries
10. Commit the initial DVC configuration to Git


## Credentials

flux resolves R2 credentials in this order on every `flux-setup` run:

| Priority | Source | Notes |
|---|---|---|
| 1 | `FLUX_R2_*` environment variables | Best for CI/automation — no prompts |
| 2 | Platform secret store | macOS Keychain or Linux secret service |
| 3 | Interactive prompt | Credentials saved to secret store if available |

**Environment variables** (set these to skip all prompts):
```bash
export FLUX_R2_BUCKET='your-bucket'
export FLUX_R2_ACCOUNT_ID='your-account-id'
export FLUX_R2_ACCESS_KEY_ID='your-key-id'
export FLUX_R2_SECRET_KEY='your-secret'
```

**Platform secret store** — enter credentials once, reused for all future repos:
- macOS: Keychain (via `security`)
- Linux desktop: GNOME Keyring / KWallet (via `secret-tool`)
- Headless Linux / CI: no persistent store — use env vars instead


## Daily workflow

### With flux aliases (recommended)

```bash
flux-commit -m "your message"   # stage all, commit — hook routes automatically
flux-push                        # git push + dvc push in one step
flux-pull                        # git pull + dvc pull in one step
flux-status                      # git status + dvc status combined
```

Or to stage, commit, and push in one shot:
```bash
flux-sync -m "your message"     # add + commit + git push + dvc push
```

### Without aliases (raw commands)

```bash
git add .
git commit -m "your message"   # hook fires, routes files automatically
git push                        # sends Git content → GitLab / GitHub
dvc push                        # sends large/binary files → Cloudflare R2
```

### Pulling on the other machine

```bash
flux-pull       # recommended: git pull + dvc pull in one step

# or manually:
git pull        # fetches Git content from remote
dvc pull        # fetches large/binary files from R2
```

### Using GitHub Desktop

GitHub Desktop fires the pre-commit hook normally when you commit. The hook
finds DVC automatically regardless of which Homebrew install you have, so
commits work as expected from the GUI.

The one limitation: `dvc push` and `dvc pull` are not Git commands, so GitHub
Desktop has no concept of them. You need a terminal for those two steps:

```bash
dvc push   # run after pushing via GitHub Desktop
dvc pull   # run after pulling via GitHub Desktop
```

Everything else — branching, diffs, commit history, git push/pull — can stay
in GitHub Desktop as normal.


## Flux aliases

The aliases unify the split `git` / `dvc` command pair into a single
consistent interface. Install them once per machine.

| Alias | What it does |
|---|---|
| `flux-commit` | `git add . && git commit` — hook routes files automatically |
| `flux-push` | `git push && dvc push` — both remotes in one step |
| `flux-pull` | `git pull && dvc pull` — both remotes in one step |
| `flux-sync` | `git add . && git commit && git push && dvc push` — full sync |
| `flux-status` | `git status && dvc status` — combined view |
| `flux-doctor` | diagnose the flux setup in the current repo |

### Installation

The setup script offers to install these for you. To install manually,
add the following to your `~/.zshrc` (or `~/.bash_profile` for bash):

```bash
# flux — unified Git + DVC workflow
# Functions (not aliases) so they check for a flux setup gracefully.
_flux_check() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "flux: not inside a Git repository."; return 1
  }
  if [[ ! -d "${root}/.dvc" ]]; then
    echo "flux: no flux setup in this repo."
    echo "      Run flux-setup from the repo root to initialise."
    return 1
  fi
}
flux-commit() { _flux_check || return 1; git add . && git commit "$@"; }
flux-push()   { _flux_check || return 1; git push && dvc push; }
flux-pull()   { _flux_check || return 1; git pull && dvc pull; }
flux-sync()   { _flux_check || return 1; git add . && git commit "$@" && git push && dvc push; }
flux-status() { _flux_check || return 1; git status && echo "--- DVC ---" && dvc status; }
```

Then reload your shell:
```bash
source ~/.zshrc   # or source ~/.bash_profile
```

`flux-doctor` is installed by `flux-setup` but is too long to paste here — run
`flux-setup` or copy it from the alias block in `setup.sh`.

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

The hook and setup script check these locations in order:

| Location | When used |
|---|---|
| `/opt/homebrew/bin/` | System Homebrew, Apple Silicon |
| `/usr/local/bin/` | System Homebrew, Intel Mac |
| `~/.homebrew/bin/` | User-local Homebrew (common) |
| `~/homebrew/bin/` | User-local Homebrew (alternative) |
| `~/.linuxbrew/bin/` | Linuxbrew |
| `PATH` fallback | pip-installed, conda, or anything else |

No configuration needed — whichever install exists on a given machine is used.


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

Install flux on the new machine first (if not already):
```bash
brew tap bpeterme/flux
brew install bpeterme/flux/flux
```

Then clone and run setup:
```bash
git clone <your-remote-url>
cd <repo>
flux-setup
```

If you already ran setup on the first machine, your R2 credentials are in that
machine's secret store but not yet on the new one. `flux-setup` will detect they
are missing and prompt once — then store them locally so all subsequent repos
on that machine are automatic.

If you're on headless Linux with no secret store, set the `FLUX_R2_*`
environment variables before running setup to skip the prompt entirely.

Then pull the large files:
```bash
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
Files already committed to Git before `flux-setup` was run are never touched
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
Run `flux-doctor` first — it checks hook installation and prints a clear
pass/fail for each item. For a quick manual check:
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

**Inspect or update stored credentials**

macOS (Keychain):
```bash
# View stored values
security find-generic-password -s "dvc-r2" -a "r2-bucket" -w
security find-generic-password -s "dvc-r2" -a "r2-account-id" -w
security find-generic-password -s "dvc-r2" -a "r2-access-key-id" -w

# Force re-entry on next setup run
security delete-generic-password -s "dvc-r2" -a "r2-bucket"
security delete-generic-password -s "dvc-r2" -a "r2-account-id"
security delete-generic-password -s "dvc-r2" -a "r2-access-key-id"
security delete-generic-password -s "dvc-r2" -a "r2-secret-key"
```

Linux (secret-tool):
```bash
# View stored values
secret-tool lookup service dvc-r2 account r2-bucket
secret-tool lookup service dvc-r2 account r2-access-key-id

# Force re-entry on next setup run
secret-tool clear service dvc-r2 account r2-bucket
secret-tool clear service dvc-r2 account r2-account-id
secret-tool clear service dvc-r2 account r2-access-key-id
secret-tool clear service dvc-r2 account r2-secret-key
```

CI / headless Linux (no secret store):
```bash
# Set environment variables — flux-setup reads these at highest priority
export FLUX_R2_BUCKET='your-bucket'
export FLUX_R2_ACCOUNT_ID='your-account-id'
export FLUX_R2_ACCESS_KEY_ID='your-key-id'
export FLUX_R2_SECRET_KEY='your-secret'
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
