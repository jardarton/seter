set -eu

url=$1
target=$2
branch=$3
placeholder=$4
marker=${target%/*}/.seter-bootstrap-${target##*/}

fail() {
    printf 'seter init: %s\n' "$1" >&2
    exit 20
}

configure_credential() {
    if test -n "$placeholder"; then
        git -C "$target" config --local "http.$url.extraHeader" "Authorization: $placeholder"
    fi
}

ensure_marker() {
    if test -L "$marker" || { test -e "$marker" && ! test -d "$marker"; }; then
        fail "bootstrap marker $marker is not a directory; refusing to overwrite it"
    fi
    if test -d "$marker" && test -n "$(find "$marker" -mindepth 1 -maxdepth 1 -print -quit)"; then
        fail "bootstrap marker $marker contains unrelated content; refusing to overwrite it"
    fi
    if ! test -d "$marker"; then
        mkdir -- "$marker"
    fi
}

clone_repository() {
    ensure_marker
    set -- clone --origin origin
    if test -n "$branch"; then
        set -- "$@" --branch "$branch"
    fi
    set -- "$@" -- "$url" "$target"
    if test -n "$placeholder"; then
        git -c "http.$url.extraHeader=Authorization: $placeholder" "$@"
    else
        git "$@"
    fi
    rmdir -- "$marker"
    configure_credential
}

if test -L "$target"; then
    fail "checkout path $target is a symbolic link; refusing to overwrite it"
fi

if ! test -e "$target"; then
    clone_repository
    printf 'Initialized repository at %s\n' "$target"
    exit 0
fi

if ! test -d "$target"; then
    fail "checkout path $target is not a directory; refusing to overwrite it"
fi

if test -L "$target/.git"; then
    fail "checkout path $target has a symbolic-link .git directory; refusing to alter it"
fi

if ! test -e "$target/.git"; then
    if test -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)"; then
        fail "checkout path $target contains unrelated content; move it aside or choose a different checkout name"
    fi
    clone_repository
    printf 'Initialized repository at %s\n' "$target"
    exit 0
fi

if ! test -d "$target/.git"; then
    fail "checkout path $target has an unsupported .git file; refusing to alter it"
fi

actual_url=$(git -C "$target" remote get-url origin 2>/dev/null || true)
if test "$actual_url" != "$url"; then
    fail "checkout path $target has origin $actual_url, expected $url; refusing to alter it"
fi

recover_empty_worktree=false
if git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
    if test -d "$marker"; then
        if test -z "$(git -C "$target" status --porcelain)"; then
            rmdir -- "$marker"
            configure_credential
            printf 'Workspace repository is already initialized at %s\n' "$target"
            exit 0
        fi
        if test -z "$(find "$target" -mindepth 1 -maxdepth 1 ! -name .git -print -quit)"; then
            # Seter left its marker and no working files exist, so it is safe
            # to reconstruct the index and working tree from the fetched HEAD.
            recover_empty_worktree=true
        else
            fail "checkout path $target is a partial repository with working data; refusing to overwrite it"
        fi
    else
        configure_credential
        printf 'Workspace repository is already initialized at %s\n' "$target"
        exit 0
    fi
fi

# A repository with no checked-out commit is recoverable only while no working
# data exists. Never fetch, checkout, clean, reset, or otherwise mutate a
# partial bootstrap that contains anything except Seter's clone metadata.
if test -n "$(find "$target" -mindepth 1 -maxdepth 1 ! -name .git -print -quit)"; then
    fail "checkout path $target is a partial repository with working data; refusing to overwrite it"
fi

ensure_marker
configure_credential
git -C "$target" fetch origin
if test -n "$branch"; then
    git -C "$target" show-ref --verify --quiet "refs/remotes/origin/$branch" \
        || fail "configured branch $branch does not exist on the approved repository"
    if git -C "$target" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$target" checkout "$branch"
    else
        git -C "$target" checkout --track -b "$branch" "origin/$branch"
    fi
else
    git -C "$target" remote set-head origin --auto >/dev/null
    default_ref=$(git -C "$target" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) \
        || fail "approved repository does not advertise a default branch"
    default_branch=${default_ref#refs/remotes/origin/}
    if git -C "$target" show-ref --verify --quiet "refs/heads/$default_branch"; then
        git -C "$target" checkout "$default_branch"
    else
        git -C "$target" checkout --track -b "$default_branch" "$default_ref"
    fi
fi

if test "$recover_empty_worktree" = true; then
    git -C "$target" read-tree HEAD
    git -C "$target" checkout-index --all
fi

rmdir -- "$marker"
printf 'Recovered and initialized repository at %s\n' "$target"
