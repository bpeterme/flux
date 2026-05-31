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
            directory pin?          ← flux pin dvc / flux pin git
         ┌──────────┴──────────┐
         │                     │
    pin → DVC             pin → Git
         │                     │
         └──────────┬──────────┘
                    │ (no pin)
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
- **Directory pinning** — force entire directory trees to Git or DVC, overriding automatic routing
- **Any Git remote** — works with GitHub, GitLab, Forgejo, or any self-hosted remote
- **Credentials in Keychain** — nothing secret ever touches a file on disk (macOS only)
- **`.dvcignore` stays in sync** — regenerated from `.gitignore` on every commit; never edit it manually
- **Automatic migration** — files that grow past or shrink below the threshold are re-routed in place
- **Orphan cleanup** — deleted or renamed DVC-tracked files are detected and cleaned up automatically

## Installation

```bash
brew tap bpeterme/flux
brew install bpeterme/flux/flux
pip install "dvc[s3]"
# or: uv tool install "dvc[s3]"
```

Prerequisites: macOS with Homebrew, a Cloudflare R2 bucket with an API token,
and a Git remote configured on each repo you want to manage.

## Configuration

### One-time per machine

```bash
flux config
```

Walks through three sections:

- **DVC remotes** — one or more Cloudflare R2 accounts (bucket + account ID + credentials).
  Add as many as you need (personal, work, client, …). If you have multiple remotes, one
  is marked as primary and used by default for new projects.
- **Routing** — global size cap and verbose flag.
- **Git accounts** — one or more hosting accounts (`ssh:github.com:yourname`,
  `https:gitlab.com:workaccount`, …). Used to propose git remote URLs during `flux add`.

Non-sensitive values are saved to `~/.config/flux/flux.env` as bash arrays.
Credentials go directly into macOS Keychain, keyed per bucket.

On subsequent runs `flux config` shows a live summary and opens sub-menus to add,
edit, or remove individual DVC remotes and git accounts.

`flux.env` format:

```bash
FLUX_DVC_REMOTES=(
  "mybucket:abc123accountid"
  "workbucket:def456accountid"
)
FLUX_PRIMARY_DVC_REMOTE=mybucket  # active remote; must match an entry in FLUX_DVC_REMOTES
FLUX_SIZE_CAP_MB=5
FLUX_VERBOSE=false
FLUX_GIT_ACCOUNTS=(
  "ssh:github.com:yourname"
  "https:gitlab.com:workaccount"
)
```

### One-time per repo

```bash
cd your-project
flux add
```

Initialises DVC, configures the R2 remote, installs the pre-commit hook, and sets
up the git remote.

- If you have multiple DVC remotes configured, `flux add` prompts you to pick one.
- The R2 folder name defaults to the current directory name (sanitized).
- If no `origin` remote exists, `flux add` proposes a URL from your configured git
  accounts (pre-filled with the repo name) and runs `git remote add origin` on
  confirmation. For GitHub repos, it can create the remote repo via `gh` if installed.

Config is split by sensitivity:

| Setting | Storage |
|---|---|
| DVC remotes (bucket, account ID) | `~/.config/flux/flux.env` |
| Git accounts | `~/.config/flux/flux.env` |
| DVC credentials (access key, secret) | macOS Keychain (per bucket) |
| R2 folder, DVC remote bucket, size cap, verbose | per-repo `git config` |

> [!WARNING]
> **Do not place flux-managed project directories on iCloud Drive, Dropbox Smart Sync, Google Drive Stream, or any on-demand cloud storage.** These services evict file contents to stubs when not recently accessed. The pre-commit hook reads each staged file to detect its content type and size; an evicted stub will be misclassified as a tiny text file and routed to Git instead of DVC.
>
> **Do not run continuous sync tools (Syncthing, rsync daemons, etc.) on a flux-managed project directory.** They can write into the working tree or DVC cache while a pre-commit hook or `dvc push` is running, risking corrupt pointer files or lost remote data.

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

### Adjusting the size cap

```bash
flux cap           # show current cap (global and per-project)
flux cap 10        # set per-project cap to 10 MB
flux cap --reset   # revert to global default
```

The global default is set during `flux config`. The per-project cap overrides it for a specific repo and is stored in the repo's local `.git/config` — never committed.

```bash
git config dvc-router.verbose true   # enable verbose hook output for debugging
```

### Pinning directories

Sometimes automatic routing isn't what you want for a particular directory — for
example, forcing a `data/` tree to always land in DVC regardless of file size, or
keeping a `config/` tree in Git even if a file grows large.

Run `flux pin` from inside the directory you want to pin:

```bash
cd data/
flux pin dvc          # force everything in data/ (and subdirectories) to DVC

cd ../config/
flux pin git          # force everything in config/ to Git

flux pin reset        # remove the pin for the current directory
flux pin reset --all  # clear all pins in this project

flux pin              # show usage and current pins for this repo
```

Pins are stored in the repo's local `.git/config` (never committed) and take
effect on the next `git commit`. Run `flux list` from inside the project to see
active pins alongside the project summary:

```
PATH          DVC REMOTE          GIT REMOTE          CAP
-----------   ------------------  ------------------  ---
. (current)   my-bucket/project   git@github.com:x/y  5 MB

  Pinned:
    ✦  data                     → DVC
    ·  config                   → Git
```

`flux dry-run` also shows which files are routed by a pin (`[pinned]` annotation
in the file-details view).

### Previewing routing

```bash
flux dry-run   # preview how staged files (or all tracked files) would be routed
```

Shows a routing summary (→ Git / → DVC / already in DVC) and an optional file-level
breakdown. No changes are made.

### GitHub Desktop

The pre-commit hook fires normally when you commit from GitHub Desktop. The hook
finds DVC automatically regardless of Homebrew install location.

The one limitation: `dvc push` and `dvc pull` are not Git commands, so GitHub
Desktop has no concept of them. Use `flux` or `flux pull` from a terminal
for those steps.

## Command reference

| Command | Description |
|---|---|
| `flux add` | Initialise flux in the current project |
| `flux list` | List flux-managed projects; shows pins when inside a single project |
| `flux clone <git-url>` | Clone a flux-managed repo and wire up DVC + credentials |
| `flux remove [git\|dvc]` | Remove all flux traces, or only git config, or only DVC |
| `flux pull` | Download the latest (`git pull` + `dvc pull`) |
| `flux` | Sync both ways (pull then push) |
| `flux dry-run` | Preview routing without making changes |
| `flux cap [N\|--reset]` | Show, set, or reset per-project size cap |
| `flux pin [dvc\|git\|reset]` | Pin current directory to DVC or Git; `reset` removes pin |
| `flux pin reset --all` | Clear all directory pins |
| `flux config` | Configure or update global settings |
| `flux doctor` | Run environment diagnostics |
| `flux version` | Show version |

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
flux clone <remote-url>   # clones, wires up DVC, and pulls large files
cd <repo>
```

`flux clone` reads the bucket and endpoint from the committed `.dvc/config`, looks up credentials in macOS Keychain, and prompts for them once if they are not found. After that, the repo is fully configured with no additional steps.

If you prefer to set up credentials globally first (so `flux clone` never prompts):

```bash
flux config   # stores credentials in macOS Keychain
flux clone <remote-url>
cd <repo>
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

## Companion Tools

### [claudebox](https://github.com/bpeterme/claudebox)

[claudebox](https://github.com/bpeterme/claudebox) (`cbox`) runs Claude Code inside an isolated container scoped to your current project directory. When claudebox is installed alongside flux, large-file sync runs automatically at session boundaries for flux-managed projects — no manual `flux pull`/`flux push` needed inside a claudebox session.

```bash
brew tap bpeterme/claudebox && brew install bpeterme/claudebox/claudebox
cbox           # start Claude Code in a container for the current project
```

### [claudedot](https://github.com/bpeterme/claudedot)

[claudedot](https://github.com/bpeterme/claudedot) (`cdot`) syncs your Claude configuration and per-project conversation history across machines via a private git remote. Keeps your Claude settings consistent everywhere you work.

```bash
brew tap bpeterme/claudedot && brew install bpeterme/claudedot/claudedot
cdot config    # connect to your sync remote
```
