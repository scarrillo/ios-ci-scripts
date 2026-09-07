# Release-decision foundation

`scripts/distribution/release-state.py` is an unwired Python standard-library module, not a workflow
or command-line entry point. It has no Git, filesystem, or network side effects.
Run its synthetic tests with `python3 -m unittest discover -s tests`.

Preparation validates normalized decimal version/build scalars for changed
projects. New projects retain valid initial values. Equal values request a bump
only for writable consumers; manual versions must increase both version and
build. Unchanged projects are skipped. Read-only contributors author their own
bumps. An adapter must distinguish a genuinely new project from missing or
invalid metadata and compare against the current base, not the historical fork.

Baseline selection accepts one release namespace and caller-supplied reachable,
peeled commit identities. It selects the highest reachable version, including a
tag at the selected merge for retry handling. Ambiguous highest-version aliases
fail closed. The caller must obtain reachability from Git, not contributor input.

`scripts/distribution/release-git.py` now provides read-only local Git integration: full commit IDs,
bounded literal metadata parsing from blobs, regular-file checks, historical
change attribution, current-base comparison, and peeled-tag ancestry checks.
Load both modules from the same trusted revision, never from PR-supplied code.
The parser is not a general YAML parser. Callers supply their own change scopes.
Synthetic local repositories test the adapter without network access.

Remote-head verification, API adapters, immutable-tag reconciliation,
workflow wiring, and hosted freshness verification remain follow-up work.
This module does not enforce branch protection, certify compilation, or alter
the existing tagging workflow and its legacy moving-tag behavior.
