# Release preparation: scope and verification

The supported task is deliberately small: read valid versions, prepare a PR
bump when needed, and avoid overwriting concurrent work. This is not a release
orchestration framework.

Three helpers live in `scripts/distribution/`:

- `release_yaml.py`: structure-aware settings parsing.
- `release_version.py`: atomic scalar editing, behind the existing shell CLI.
- `release_prep.py`: version decisions, read-only Git operations, and the
  workflow-facing `inspect` / `remote-head` commands.

Install the pinned `requirements-release.txt` in a virtual environment.
Run `python3 -m unittest discover -s tests` locally when maintaining these scripts.
Tests use synthetic files and local bare remotes. No active CI workflow is added
to this example repository; workflow templates stay under `workflows/`.

## Preparation behavior

Unchanged projects are skipped. New projects retain valid initial values.
Equal version/build values request a bump for writable consumers; manual values
must increase both numbers. Read-only contributors supply their own bumps.
Compare numbers against the current base; attribute changes from the merge base.
The parser reads explicit project/target settings, not text in notes. It rejects
ambiguous YAML and does not resolve includes, templates, groups or xcconfig files.

## Optional workflow

`workflows/release-prep.yml` is a single-project example. Configure PROJECT_DIR
and SCRIPTS_ROOT on the trusted base branch. It loads helpers from that base
checkout (including the base-pinned submodule), validates forks without mutation,
and permits ordinary fast-forward preparation pushes only within the same repo.
All helpers and dependencies must come from that trusted revision, never the PR
checkout. Missing helpers fail without a head-copy fallback.

Remote-head checks are not a transaction across Git/GitHub; branch recreation or
administrative rewrites can race. Status remains bound to an exact SHA. Require
strict branch freshness; preparation does not certify compilation. Verify bot-push
CI, fork statuses and required-check behavior in a disposable hosted trial before
adopting this workflow as a merge gate. No hosted trial is claimed.

## Non-goals

No tag-baseline API, pre-merge tag checks, distribution recovery, queue management,
release ordering or GitHub Release publication. Add those only for a demonstrated
consumer need. The existing post-merge tag template and legacy moving-tag behavior
are separate and unchanged by this simplification.
