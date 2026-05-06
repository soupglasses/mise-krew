#!/usr/bin/env bash
# Integration tests for mise-krew. Runs against the linked plugin.

if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    GREEN=''; RED=''; NC=''
else
    GREEN=$'\e[0;32m'
    RED=$'\e[0;31m'
    NC=$'\e[0m'
fi

PASSED=0
FAILED=0

check() {
    local name="$1"
    local cmd="$2"
    local out
    if out=$(eval "$cmd"); then
        printf "%s✓%s %s\n" "$GREEN" "$NC" "$name"
        PASSED=$((PASSED + 1))
    else
        printf "%s✗%s %s\n" "$RED" "$NC" "$name"
        if [ -n "$out" ]; then
            printf "%s\n" "$out" | sed 's/^/    /'
        fi
        FAILED=$((FAILED + 1))
    fi
}

echo "mise-krew integration tests"

# Per-tool cleanup: removes installed binaries and the plugin's per-tool
# version index. Never touches `registry/` (the shared krew-index clone) so
# repeated local runs don't pay a full re-clone.
clean_tool() {
    local tool="$1"
    mise uninstall "krew:$tool" --all >/dev/null 2>&1 || true
    rm -f "cache/$tool.json"
}

clean_tool tree
clean_tool browse-pvc

check "plugin is linked"                          "mise plugin list | grep -q krew"
check "list remote versions for tree"             "mise ls-remote krew:tree | grep -q 'v0.4'"
check "install krew:tree@latest"                  "mise install krew:tree@latest"

TREE_INSTALL=$(mise where krew:tree@latest)
check "tree binary is executable"                 "test -x '${TREE_INSTALL}/kubectl-tree'"
check "tree binary runs"                          "mise exec krew:tree@latest -- kubectl-tree --version"

check "install krew:browse-pvc@latest"            "mise install krew:browse-pvc@latest"

BPVC_INSTALL=$(mise where krew:browse-pvc@latest)
check "hyphenated plugin renamed to underscores"  "test -f '${BPVC_INSTALL}/kubectl-browse_pvc'"
check "original hyphen-named binary removed"      "test ! -f '${BPVC_INSTALL}/kubectl-browse-pvc'"

# Regression coverage:
#   #6: oidc-login, get-all, deprecations, df-pv, access-matrix, cilium-policy-gen
#   #7: rook-ceph
for t in oidc-login get-all deprecations df-pv access-matrix cilium-policy-gen rook-ceph; do
    clean_tool "$t"
    check "install krew:$t@latest" "mise install krew:$t@latest"
done

if [ $FAILED -eq 0 ]; then
    printf "%s%d passed%s\n" "$GREEN" "$PASSED" "$NC"
    exit 0
else
    printf "%s%d passed, %d failed%s\n" "$RED" "$PASSED" "$FAILED" "$NC"
    exit 1
fi
