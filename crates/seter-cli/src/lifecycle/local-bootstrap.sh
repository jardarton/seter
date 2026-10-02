set -eu

target=$1
branch=$2
mode=$3

fail() {
    printf 'seter local import: %s\n' "$1" >&2
    exit 20
}

if test "$mode" = check; then
    test ! -L "$target" && test -d "$target/.git" && test ! -L "$target/.git" \
        || fail "checkout is missing or unsupported; use seter import with a Git bundle"
    test "$(git -C "$target" config --local --get seter.localImport || true)" = true \
        || fail "checkout was not imported by Seter; refusing to alter it"
    git -C "$target" rev-parse --verify HEAD >/dev/null \
        || fail "local import has no checked-out commit"
    printf 'Local repository is already initialized at %s\n' "$target"
    exit 0
fi

test "$mode" = import || fail "unknown operation"
test ! -e "$target" && test ! -L "$target" \
    || fail "checkout path already exists; refusing to overwrite working data"

stage=$(mktemp -d "${target%/*}/.seter-import-XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
trap 'exit 130' HUP INT TERM
cat > "$stage/source.bundle"
# Verify prerequisites in an empty repository: only self-contained bundles
# can bootstrap a new checkout. No host Git config or hooks are transferred.
git init --quiet "$stage/verify"
git -C "$stage/verify" bundle verify "$stage/source.bundle"
if test -n "$branch"; then
    git clone --branch "$branch" -- "$stage/source.bundle" "$stage/checkout"
else
    git clone -- "$stage/source.bundle" "$stage/checkout"
fi
git -C "$stage/checkout" rev-parse --verify HEAD >/dev/null \
    || fail "bundle does not provide a checked-out commit; select a branch explicitly"

# Preserve all bundled branches before removing the temporary origin.
git -C "$stage/checkout" for-each-ref --format='%(refname:strip=3) %(objectname)' refs/remotes/origin \
    | while read -r name commit; do
        test "$name" != HEAD || continue
        if ! git -C "$stage/checkout" show-ref --verify --quiet "refs/heads/$name"; then
            git -C "$stage/checkout" branch -- "$name" "$commit"
        fi
    done
git -C "$stage/checkout" remote remove origin
git -C "$stage/checkout" config --local seter.localImport true
mv -T --no-clobber -- "$stage/checkout" "$target"
test ! -d "$stage/checkout" || fail "checkout appeared during import; retained existing working data"
printf 'Imported local repository at %s\n' "$target"
