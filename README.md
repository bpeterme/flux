# flux — Git + DVC Auto-Router

Automatic file routing between any Git remote and Cloudflare R2 via DVC, based
on binary detection and file size. No manual decisions, no extension lists to
maintain — one `git commit` does everything.

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
contains null bytes it's binary. This catches `.mp4`, `.psd`, `.db`, `.zip`,
`.dmg`, and any future format automatically.

## Key features

- **Zero routing decisions** — binary files and large text files go to R2 automatically
- **Any Git remote** — works with GitHub, GitLab, Forgejo, or any self-hosted remote
- **Credentials in Keychain** — nothing secret ever touches a file on disk
- **`.dvcignore` stays in sync** — regenerated from `.gitignore` on every commit; never edit it manually
- **Automatic migration** — files that grow past or shrink below the threshold are re-routed in place
- **Orphan cleanup** — deleted or renamed DVC-tracked files are detected and cleaned up automatically

## Installation

```bash
brew tap bpeterme/flux
brew install bpeterme/flux/flux
pip install "dvc[s3]"
```

Prerequisites: macOS with Homebrew, a Cloudflare R2 bucket with an API token,
and a Git remote configured on each repo you want to manage.

## Configuration

### One-time per machine

```bash
flux config
```

Prompts for your R2 bucket, account ID, access key, and secret key. Non-sensitive
values are saved to `~/.config/flux/flux.env`; credentials go directly into macOS
Keychain. On subsequent runs `flux config` shows current settings and lets you
update or remove them.

### One-time per repo

```bash
cd your-project
flux add
```

Initialises DVC, configures the R2 remote, and installs the pre-commit hook.

Config is split by sensitivity:

| Setting | Storage |
|---|---|
| R2 bucket, account ID | `~/.config/flux/flux.env` |
| Access key ID, secret key | macOS Keychain |
| R2 folder, threshold, verbose | per-repo `git config` |

## Daily workflow

```bash
git add .
git commit -m "your message"   # hook fires, routes files automatically
flux                            # git pull + dvc pull + git push + dvc push
flux pull                       # download the latest (git pull + dvc pull)
```

Or broken out manually:

```bash
git push   # sends Git content → GitLab / GitHub
dvc push   # sends large/binary files → Cloudflare R2
git pull   # fetches Git content from remote
dvc pull   # fetches large/binary files from R2
```

### Adjusting settings

```bash
git config dvc-router.size-threshold-mb 10   # change size threshold (default: 5 MB)
git config dvc-router.verbose true            # verbose hook output for debugging
```

Settings are stored in the repo's local `.git/config` and never committed.

### GitHub Desktop

The pre-commit hook fires normally when you commit from GitHub Desktop. The hook
finds DVC automatically regardless of Homebrew install location.

The one limitation: `dvc push` and `dvc pull` are not Git commands, so GitHub
Desktop has no concept of them. Use `flux` or `flux pull` from a terminal
for those steps.

## Command reference

| Command | Description |
|---|---|
| `flux add` | Opt current project into sync |
| `flux remove` | Detach flux from current project |
| `flux pull` | Download the latest (`git pull` + `dvc pull`) |
| `flux` | Sync both ways (pull then push) |
| `flux config` | Configure or update global settings |
| `flux doctor` | Run environment diagnostics |
| `flux version` | Show version |
| `flux claudebox` | Check claudebox install status |
| `flux claudedot` | Check claudedot install status |

## Credentials and CI

For CI or headless environments, configure the DVC remote directly from your
CI secrets store:

```bash
dvc remote modify --local r2remote access_key_id     "$R2_ACCESS_KEY_ID"
dvc remote modify --local r2remote secret_access_key "$R2_SECRET_KEY"
```

## Setting up on another machine

```bash
brew tap bpeterme/flux && brew install bpeterme/flux/flux
pip install "dvc[s3]"
flux config          # stores credentials in macOS Keychain
git clone <remote-url> && cd <repo>
flux add
dvc pull             # fetch large files from R2
```

## File structure after first use

```
my-project/
├── .dvc/
│   ├── config          ← committed (R2 endpoint, bucket — no secrets)
│   └── config.local    ← git-ignored (contains your secret key)
├── .gitignore          ← you maintain this; source of truth for ignores
├── .dvcignore          ← auto-generated from .gitignore, never edit manually
├── src/                ← tracked by Git → GitLab / GitHub
└── footage/
    ├── .gitignore      ← DVC adds /clip.mp4 here automatically
    ├── .dvcignore      ← auto-generated from footage/.gitignore
    ├── clip.mp4        ← git-ignored, stored in R2
    └── clip.mp4.dvc    ← tiny pointer file, tracked by Git
```

## Edge cases

### Handled automatically by the hook

**File grows past threshold (Git → DVC)**
If a file was previously in Git and then grows above the threshold (or becomes
binary), the hook detects the transition, removes it from the Git index cleanly,
and hands it off to DVC. The old small version remains in Git history — run
`git filter-repo` to scrub it if needed.

**File shrinks below threshold (DVC → Git)**
At the start of every commit the hook reads the full list of DVC-tracked files
from `git ls-files '*.dvc'`. For each, it checks the current on-disk size and
binary status. If a file is now text and below the threshold it is automatically
migrated back to Git in the same commit. `dvc gc --cloud --all-branches` runs
automatically after migration to purge the now-unreferenced R2 data.

**File deleted**
The hook scans all tracked `.dvc` pointers at the start of every commit, detects
missing targets, and stages the pointer for deletion automatically. The stale
entry in `.gitignore` is also cleaned up.

**File renamed**
Same mechanism as deletion — the old pointer's target is gone so the hook removes
it. The file at its new name gets staged normally, routed fresh, and a new `.dvc`
pointer is created. One commit handles both the cleanup and the re-routing.

### Handle manually if needed

**Pre-existing large/binary files**
Files already committed to Git before `flux add` are never touched by the hook.
Migrate them manually:

```bash
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
Both versions exist safely in R2. To resolve the pointer conflict:

```bash
git checkout --ours footage/clip.mp4.dvc    # keep your local version
# or
git checkout --theirs footage/clip.mp4.dvc  # keep the remote version
dvc pull
git add footage/clip.mp4.dvc
git commit -m "resolve DVC merge conflict"
```

**Common troubleshooting**

```bash
# Hook not firing
ls -la .git/hooks/pre-commit   # must exist and be executable
chmod +x .git/hooks/pre-commit

# DVC not found by hook — enable verbose to see path resolution
git config dvc-router.verbose true

# DVC push/pull failing
dvc remote list                                               # verify remote
dvc remote modify --local r2remote secret_access_key <key>  # re-add secret if missing

# File ended up in Git that should be in DVC
dvc add path/to/bigfile
git rm --cached path/to/bigfile
git add path/to/bigfile.dvc .gitignore
git commit -m "move bigfile to DVC"
dvc push

# Check what DVC is tracking
dvc status      # local vs cache
dvc status -c   # local vs R2

# Clean up unreferenced R2 data (runs automatically after migration)
dvc gc --cloud --all-branches
dvc gc
```

## Running tests

flux has a bats-core test suite covering hook routing, migration, orphan cleanup,
and `.dvcignore` sync. Tests use a mock DVC binary — no real DVC or R2 credentials
needed.

```bash
brew install bats-core   # macOS
# sudo apt-get install bats   # Linux

./tests/run.sh tests/unit.bats         # hook logic — fast, no dependencies
./tests/run.sh tests/integration.bats  # CLI flow
./tests/run.sh                         # all tests
```

Tests run automatically on every push to `dev` and `main`, and on pull requests
targeting `main`, via GitHub Actions. The release workflow runs tests as a gate
before tagging.

## Companion tools

| Tool | Description | Install |
|---|---|---|
| [claudebox](https://github.com/bpeterme/claudebox) | Claude Code container runtime — runs Claude in an isolated container per project, with normal and sandboxed modes | `brew tap bpeterme/claudebox && brew install bpeterme/claudebox/claudebox` |
| [claudedot](https://github.com/bpeterme/claudedot) | Config and history sync — keeps your Claude configuration consistent across machines via git | `brew tap bpeterme/claudedot && brew install bpeterme/claudedot/claudedot` |

```bash
flux claudebox   # check claudebox install status
flux claudedot   # check claudedot install status
```
