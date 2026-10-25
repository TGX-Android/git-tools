# git-tools

Bash scripts for repositories with many submodules, such as [Telegram X](https://github.com/TGX-Android/Telegram-X). Submodules are processed recursively and in parallel, with a progress line.

| Script | What it does |
|---|---|
| `git-clone` | Clones one commit of the repository and of each submodule. `--tgx` leaves out what the build of Telegram X doesn't use. |
| `git-checkout` | Moves the repository to a branch, tag or commit and every submodule to the commit pinned there, downloading only those commits. Without arguments, only moves submodules to the current commit. |
| `git-cp` | Copies a clone with its submodules and Git LFS objects into a new directory, downloading nothing but commits missing in it. Objects are cloned copy-on-write on APFS, btrfs and XFS. |

## Requirements

macOS 13 or newer, or Linux, with bash 5.2.21 or newer, git 2.49.0 or newer and Git LFS. Windows is not supported.

* macOS: `brew install bash git git-lfs`, the bash of the system is too old.
* Ubuntu 24.04: `sudo add-apt-repository ppa:git-core/ppa && sudo apt install git git-lfs`, the bash of the system is enough.

## Installation

```shell
git clone https://github.com/TGX-Android/git-tools ~/git-tools
# macOS
echo 'export PATH="$HOME/git-tools/bin:$PATH"' >> ~/.zprofile
# Ubuntu
echo 'export PATH="$HOME/git-tools/bin:$PATH"' >> ~/.profile
```

`git-clone` and `git-checkout` are called with a dash: `git clone` and `git checkout` stay the commands of git. `git cp` works both ways.

## Usage

```shell
# Minimal clone of Telegram X that builds the app
git-clone --tgx https://github.com/TGX-Android/Telegram-X tgx
# Switch to a local branch, a branch of origin, a tag or a commit, with submodules
git-checkout -C tgx ffmpeg-upgrade
# Update to the latest commit of a branch of origin, resetting the local branch to it
git-checkout -C tgx origin/main
# Move submodules to the current commit, e.g. after git rebase
git-checkout -C tgx
# CI: discard local changes and move the current branch to its upstream
git-checkout -f -C tgx
# Second working copy
git-cp tgx tgx-2
```

Each script lists its options with `-h`.

* Clones are shallow: `git fetch --deepen=100` shows more history.
* `git-checkout BRANCH` switches to the local branch as it is, like `git switch`, and fetches a branch that is only on origin. `git-checkout origin/BRANCH` fetches the branch and resets the local one to it.
* `git submodule update` downloads whole submodules and ignores what `--tgx` leaves out, `git-checkout` keeps the clone minimal.
* `git-checkout` removes working trees of submodules that the new commit no longer has, unless they have changes, like `git checkout --recurse-submodules`. Their repositories stay in `.git/modules` for commits that have them again.

## License

[Boost Software License 1.0](LICENSE).
