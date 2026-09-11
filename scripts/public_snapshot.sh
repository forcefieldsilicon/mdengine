#!/bin/bash
# public_snapshot.sh <version> — build the public release snapshot: ONE squash commit on top of public/main
# holding HEAD's tree MINUS the hosted service (open-core split, arvand 2026-09-09: the app, CLI and MCP
# server are published; the billing endpoint, launcher, OAuth and pricing code under hosted/ are not).
# License: BUSL-1.1 from the first release after 0.7.0 (arvand 2026-09-10; 0.7.0 and earlier stay MIT) — LICENSE,
# README, mcpb/manifest*.json carry it; docs/internal/LICENSE-DECISION.md has the why.
# Leaves branch public-main + tag v<version> locally; release_publish.sh (arvand) pushes them.
set -euo pipefail
V=${1:?usage: public_snapshot.sh <version>}
cd "$(dirname "$0")/.."
# hosted/ moved to the private repo ~/MDEngine-service on 2026-09-11 (GJOB-178); nothing of it is in this tree any more.
# docs/ other than the manual = internal working notes (unit economics, store strategy, drafts) — found by a
# peer session on the first 0.7.0 snapshot, 2026-09-09. New internal notes go in docs/internal/.
EXCLUDE=(docs/internal docs/app-store-readiness.md docs/ios-tracker-spec.md docs/privacy-policy-draft.md)
git fetch public -q
[ -z "$(git ls-remote public "refs/tags/v$V")" ] || { echo "v$V is already on the public remote — bump the version instead" >&2; exit 1; }
TMPIDX=$(mktemp)
export GIT_INDEX_FILE=$TMPIDX
git read-tree HEAD
for p in "${EXCLUDE[@]}"; do git rm -r -q --cached "$p" 2>/dev/null || true; done
TREE=$(git write-tree)
unset GIT_INDEX_FILE; rm -f "$TMPIDX"
for p in "${EXCLUDE[@]}"; do
  git ls-tree -r --name-only "$TREE" | grep -q "^$p" && { echo "exclusion failed for $p" >&2; exit 1; }
done
SNAP=$(git commit-tree "$TREE" -p public/main -m "MDEngine $V

Public snapshot of the development tree at $(git rev-parse --short HEAD) without the hosted service
(hosted/ is the operator's own code and is not part of the BUSL-1.1 release). Notes: CHANGELOG.md.")
git branch -f public-main "$SNAP"
git tag -f -a "v$V" "$SNAP" -m "MDEngine $V" >/dev/null
echo "snapshot $SNAP  tree $TREE  -> branch public-main, tag v$V (local)"
echo "files: $(git ls-tree -r --name-only "$SNAP" | wc -l | tr -d ' ')  hosted/ present: $(git ls-tree -r --name-only "$SNAP" | grep -c '^hosted/' || true)"
git diff --stat public/main "$SNAP" | tail -1
