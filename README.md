# agent-commit

Two narrow commands for coding agents. `agent-commit` makes explicit local
commits, while `agent-github` publishes a clean local repository to one new
GitHub repository.

## Why

Coding agents are enthusiastic operators. Given unrestricted `git`, they tend
to reach for `git add -A` and sweep up whatever happens to be lying around:
half-finished experiments, stray notes, or that `.env` you would rather they
had not noticed. These commands provide smaller routes instead:

- `agent-commit` can commit only named files with a validated message.
- `agent-github` can create and initially push only one new repository.

They are guardrails for the ordinary path, not a complete sandbox against an
agent deliberately reaching for another network-capable tool.

## Installation

Both commands require Bash 3.2 or later and Git 2.x. `agent-github` also
requires the [GitHub CLI](https://cli.github.com/) to be installed and
authenticated.

```sh
git clone https://github.com/ohnotnow/agent-commit.git
cd agent-commit
cp agent-commit agent-github /usr/local/bin/   # or anywhere on your PATH
```

## agent-commit

`agent-commit` stages and commits an explicit list of files with a Conventional
Commits message. Other staged, dirty, or untracked paths are left alone.

### Preview and confirm

```console
$ agent-commit -m "fix(parser): handle empty input" src/parser.sh
agent-commit — preview only, nothing committed yet

message:
    fix(parser): handle empty input
files (1):
    modified  src/parser.sh
left untouched (1 dirty/untracked paths, NOT part of this commit):
    ?? notes.tmp

To make exactly this commit, run the same command again with:  --yes 4dd7f736
```

Then repeat the command with the token:

```sh
agent-commit -m "fix(parser): handle empty input" --yes 4dd7f736 src/parser.sh
```

The token digests the message, each named path, and its content. If a named file
or the message changes after the preview, confirmation is refused.

### Messages from a file

Inline `-m` becomes fiddly when a message contains multiple lines, backticks,
or shell variables. Borrowing curl's convention, `-m @path` reads the message
from a file:

```sh
agent-commit -m @/tmp/scratch/commit.txt src/parser.sh
```

The token binds the message text itself, so editing the message file between
preview and confirmation counts as drift.

### Commit rules

- Every file must be named. Directories, `.`, `-a`, `-A`, and `--all` are
  refused.
- The first message line must use `type(optional-scope): summary`, where the
  type is `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
  `ci`, `chore`, or `revert`.
- AI-attribution shapes such as `authored-by`, `anthropic`, `claude.ai`,
  `claude.com`, `claude code`, and `generated with` are refused anywhere in the
  message. A bare mention of `claude` is allowed.
- A staged rename must include both the old and new path.
- Paths may not be absolute, contain `..`, start with `-`, or contain a newline.
- A named file with no changes is refused instead of being silently skipped.

### SAFETY_MODE

`SAFETY_MODE` is an in-file constant near the top of `agent-commit`. Setting it
to `off` skips the preview/token step and commits immediately. It is not an
environment variable or command-line option, so changing it is a deliberate
human edit rather than something an agent can add to an invocation.

### Exit codes

- `0`: preview shown or commit made
- `1`: refusal or usage error
- `2`: token mismatch

## agent-github

`agent-github` exposes only the GitHub capabilities needed to publish a local
project for the first time. Its writes are creating and pushing one new
repository, and enabling private vulnerability reporting on a repository you
own. It cannot delete repositories or remotes, change an existing
repository's visibility, push tags, force-push, manage other GitHub
resources, or pass arbitrary arguments through to `gh`.

### List allowed owners

```console
$ agent-github owners
authenticated account:
    example-user
organisations:
    example-org
```

Only the authenticated login and organisation logins are printed. Profile
fields such as names and email addresses are not exposed.

### Check authentication

```console
$ agent-github auth-status
github.com
  ✓ Logged in to github.com account example-user (keyring)
  - Active account: true
  - Token: gho_************************************
```

`auth-status` passes through `gh auth status` so an agent that is denied raw
`gh` can still tell an authentication problem from a GitHub outage, or spot
that a broadly-scoped token is loaded before publishing anything. No arguments
or flags are forwarded, so gh's `--show-token` cannot be reached and tokens
stay masked. The exit code is gh's own: `0` healthy, `1` trouble.

### Check remotes

```console
$ agent-github check-remote
agent-github: 1 remote(s) found; publish refuses while any remote exists

    origin  https://github.com/example-user/old-project.git
        github repository example-user/old-project: HTTP 404, repository gone or inaccessible
        fix: git remote remove origin
```

`check-remote` lists every local remote and, for github.com URLs, asks GitHub
whether the repository still exists. A dangling remote (for example after a
published repository was later deleted on GitHub) is reported with the exact
`git remote remove` command to run. Removal stays a human action: a 404
cannot distinguish a deleted repository from lost access, so the command
diagnoses and removes nothing. Non-github remotes are listed but cannot be
checked. Exit codes: `0` no remotes (publish can proceed), `1` remotes exist
or the check failed.

### Enable private vulnerability reporting

```sh
agent-github enable-vuln-reporting --repo example-user/example-project
```

Enables GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/working-with-repository-security-advisories/configuring-private-vulnerability-reporting-for-a-repository)
on one repository owned by the authenticated account or one of its
organisations. The underlying call is idempotent, so enabling an
already-enabled repository succeeds. There is no preview/token step: the call
turns on a protection and exposes nothing. GitHub only supports the feature
on public repositories; on a private one, GitHub's own error is shown.

### Preview and publish

```sh
agent-github publish \
  --repo example-user/example-project \
  --public \
  --description "A short description of the project"
```

The command prints a preview containing:

- The authenticated account and exact `OWNER/REPOSITORY` target.
- Public or private visibility, with public visibility made prominent.
- The description, repository root, current branch, and HEAD commit.
- The number of commits and tracked files that will be published.
- The proposed creation of `origin` and push of the current branch.

It then prints an eight-character token. Repeat the identical command with that
token to publish:

```sh
agent-github publish \
  --repo example-user/example-project \
  --public \
  --description "A short description of the project" \
  --yes 89abcdef
```

The token is bound to the authenticated account, target, visibility,
description, repository root, branch, and HEAD commit.

### Publication rules

- The local repository must have at least one commit and be on a branch.
- The working tree must be completely clean, including untracked files.
- No Git remotes may already exist.
- The owner must be the authenticated account or one of its organisations.
- The target repository must not already exist or be accessible.
- Visibility must be explicitly `--public` or `--private`.
- Descriptions are required, single-line, and under 100 characters.

Confirmation is always mandatory. Unlike `agent-commit`, `agent-github` has no
`SAFETY_MODE` bypass because publishing, particularly to a public repository,
can expose history outside the local machine.

A network or Git failure can happen after repository creation but before the
push. The command then warns that the GitHub repository may have been created
and tells the user to inspect it before retrying.

### Exit codes

- `0`: owners listed, auth-status healthy, preview shown, repository
  published, or vulnerability reporting enabled
- `1`: refusal or operational error
- `2`: token mismatch (publish only)

`check-remote` reports state through its exit code instead: `0` no remotes
exist, `1` remotes exist or the check failed.

## Using the commands with a coding agent

Allow the two constrained commands and deny the broader write interfaces. For
example, with Claude Code:

```json
{
  "permissions": {
    "allow": [
      "Bash(agent-commit *)",
      "Bash(agent-github *)"
    ],
    "deny": [
      "Bash(gh *)",
      "Bash(git add *)",
      "Bash(git commit *)",
      "Bash(git push *)"
    ]
  }
}
```

## Running the tests

```sh
bash ac-test.sh
bash ag-test.sh
```

ShellCheck:

```sh
shellcheck -s bash agent-github ag-test.sh
```

## Contributing

Fork or clone the repository, make the smallest useful change, and run both
suites before opening a pull request. For bug fixes, a failing test that
demonstrates the problem is particularly welcome.

## Licence

MIT. See [LICENSE](LICENSE).
