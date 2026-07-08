# agent-commit

A commit command for coding agents that makes the careful path the only path: explicit files, a Conventional Commits message, and a preview/confirm two-step that refuses to commit if anything changed in between.

## Why

Coding agents are enthusiastic committers. Left alone with `git`, they reach for `git add -A` and sweep up whatever happens to be lying around in the working tree: half-finished experiments, stray notes, that `.env` you'd rather they hadn't noticed. The usual fix is to deny `git add` and `git commit` outright, but then the agent can't commit at all and you end up doing it by hand.

agent-commit is the middle path. You deny the raw git commands and allow this one instead. The agent gets to commit, but only by naming every file, writing a proper message, and reading back a preview of exactly what is about to happen.

## What it does

A bare run commits nothing. It prints the plan: the full commit message, each named file and whether it's new, modified or deleted, and any dirty or untracked paths that are NOT part of the commit. It also prints a confirm token, which is a digest of the message plus each file's path and content. Re-running the same command with `--yes TOKEN` makes the commit, and only if nothing drifted since the preview. If a file changed, or the message changed, the token no longer matches and it refuses.

Only the named files are committed, even if other paths happen to be staged. It never pushes, pulls, or touches anything else.

## Requirements

bash 3.2 or later and git 2.x. Nothing else, so it works on a stock macOS bash as well as Linux.

## Installation

```sh
git clone https://github.com/ohnotnow/agent-commit.git
cd agent-commit
cp agent-commit /usr/local/bin/   # or anywhere on your PATH
```

## Usage

Preview first:

```
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

Then confirm:

```
$ agent-commit -m "fix(parser): handle empty input" --yes 4dd7f736 src/parser.sh
```

Multi-line messages work as you'd expect, and the preview shows the whole message, body and all.

### Messages from a file

Inline `-m` gets fiddly as soon as the message outgrows one line: quoting, backticks, `$variables` the shell wants to expand. Borrowing curl's convention, `-m @path` reads the message from a file instead:

```
$ agent-commit -m @/tmp/scratch/commit.txt src/parser.sh
```

The confirm token digests the message text itself, so editing the file between preview and confirm counts as drift and is refused, the same as any other change. There's no ambiguity with literal messages: a valid message can never start with `@`, because its first line has to start with a Conventional Commits type.

### The rules

- Explicit files only. Directories, `.`, `-a`, `-A` and `--all` are refused. Name each file.
- The first line of the message must follow the Conventional Commits spec: `type(optional-scope): summary`, where type is one of feat, fix, docs, style, refactor, perf, test, build, ci, chore or revert.
- No AI attribution. A message containing `authored-by`, `anthropic`, `claude.ai`, `claude.com`, `claude code` or `generated with` (case-insensitive, anywhere in the message) is refused. Agents are told by their system prompts to append these as footers; this tool exists so they can't. A bare mention of `claude` on its own is allowed.
- Renames must be committed whole. If git has a rename staged, both the old and the new path must be named, otherwise it refuses. Naming one side would silently leave the old path alive in HEAD.
- Paths may not be absolute, contain `..`, start with `-`, or contain a newline.
- A named file with no changes is refused rather than quietly skipped.

### Exit codes

- `0` preview shown or commit made
- `1` refusal or usage error
- `2` token mismatch, meaning something drifted since the preview or the token is wrong

## Using it with a coding agent

With Claude Code, deny the raw git write commands and allow this instead:

```json
{
  "permissions": {
    "allow": ["Bash(agent-commit *)"],
    "deny": ["Bash(git add *)", "Bash(git commit *)", "Bash(git push *)"]
  }
}
```

The two-step is deliberate friction. The agent has to run the preview, see the plan, and repeat the command with the token, so "commit everything and hope" stops being an available move.

## SAFETY_MODE

There's a `SAFETY_MODE` constant at the top of the script. Setting it to `off` skips the preview/token two-step so a bare run commits immediately. It's an in-file constant rather than an environment variable or flag on purpose: switching it off should be a loud, human act, not something an agent can flip inline on the command it runs.

## Running the tests

```sh
bash ac-test.sh
```

The suite builds a throwaway git repo under `mktemp` and removes it on exit; it never touches the repository you run it from. It covers previews, refusals, drift detection, renames, multi-line messages and SAFETY_MODE.

## Contributing

It's a single bash script, so the barrier is low: fork, clone, make your change, and run `bash ac-test.sh` before opening a pull request. If you're fixing a bug, a failing test case that proves it is worth more than the fix itself.

## Licence

MIT. See [LICENSE](LICENSE).
