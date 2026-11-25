#!/usr/bin/env bash
# The `breaking` target of the contracts. It refuses a change that is not additive against the
# previous released contracts (ADR 0032): buf compares the event schemas under the rules of
# buf.yaml (ADR 0038), and oasdiff compares each OpenAPI file. A release is a version tag
# `v<major>.<minor>.<patch>` (ADR 0060). buf and oasdiff are under the Apache-2.0 licence.
#
# Usage, from the root of the contracts: bash tools/breaking.sh [<revision>]
#
# Without an argument, the previous release is the highest version tag that HEAD contains. When
# the contracts' files are unchanged, HEAD is what is checked, so a tag on HEAD itself does not
# count: CI checks a pointer that names a release against the release before it. When they have
# changes, the working tree is what is checked, and a tag on HEAD counts too. With an argument,
# that revision is the previous release.
set -euo pipefail

buf=(go run github.com/bufbuild/buf/cmd/buf@v1.75.0)
oasdiff=(go run github.com/oasdiff/oasdiff@v1.37.0)

if [ $# -gt 0 ]; then
  base=$1
else
  # A shallow clone may lack the release, and would then pass without comparing anything.
  if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "This clone is shallow and may lack the previous release: fetch the whole history and its tags." >&2
    exit 2
  fi
  merged=(--merged HEAD --no-contains HEAD)
  if [ -n "$(git status --porcelain --untracked-files=all -- buf.yaml events openapi)" ]; then
    merged=(--merged HEAD)
  fi
  base=
  for tag in $(git tag --list 'v*' "${merged[@]}" --sort=-v:refname); do
    # A tag such as v1.2.0-rc1 is no release.
    if [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then base=$tag; break; fi
  done
  if [ -z "$base" ]; then
    echo "No released contracts precede this revision, so nothing can break."
    exit 0
  fi
fi
if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
  echo "Not a revision of the contracts: $base" >&2
  exit 2
fi
echo "Comparing with $base."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git archive "$base" | tar -x -C "$work"
status=0

# buf stops with "had no .proto files" against a release whose events/ holds no schema. Such a
# release has no event schema that could break, so the comparison is skipped.
if [ -n "$(find "$work/events" -name '*.proto')" ]; then
  echo "== buf breaking: the event schemas"
  "${buf[@]}" breaking --against "$work" || status=1
else
  echo "== buf breaking: $base has no event schema, so none can break"
fi

shopt -s nullglob
echo "== oasdiff: the OpenAPI files"
for released in "$work"/openapi/*/*.yaml; do
  spec=${released#"$work"/}
  if [ ! -f "$spec" ]; then
    echo "$spec is in $base and was removed, which breaks every client of it."
    status=1
  fi
done
# oasdiff reads each file and the files it refers to at the base with git show, and skips a file
# that the release does not hold. --flatten-allof compares the merged schema: without it, a
# change behind an allOf, such as a $ref with its own description, is only a warning.
# --flatten-params gives each operation the parameters of its path: oasdiff checks only an
# operation's own, and the shared operation declares its parameters on the path.
#
# oasdiff-levels.txt sets the level of some of oasdiff's checks. A contract changes by addition
# only, and no deprecation period allows a removal, so every removal that a neighbour can see is
# an error: of a parameter, a property, an operation or its operationId, which workload tokens and
# access files name, a status, a header or an enum value. oasdiff rates some of them as warnings
# or information, because they break no client that ignores them. A code is added to a
# contract's list as an additive change (ADR 0054), but oasdiff counts any value added to an
# enum of a response as an error. That check is lowered to a warning, which is refused below
# unless the value is the code of an error response.
specs=(openapi/*/*.yaml)
if [ ${#specs[@]} -gt 0 ]; then
  report=$("${oasdiff[@]}" breaking-files --base "$base" --fail-on ERR --flatten-allof --flatten-params \
    --severity-levels tools/oasdiff-levels.txt --format singleline --color never "${specs[@]}") || status=1
  printf '%s\n' "$report"
  code_added='the `code` response property for the response status `[45][0-9][0-9]` \[response-property-enum-value-added\]'
  while IFS= read -r line; do
    if [[ $line == *'[response-property-enum-value-added]'* && ! $line =~ $code_added ]]; then
      echo "Refused, because only a code may be added to an enum of a response: $line"
      status=1
    fi
  done <<<"$report"
fi

exit $status
