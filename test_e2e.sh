#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

TESTCASE=""
function testcase() {
    clean_root
    echo -n "testcase $1: "
    TESTCASE="$1"
}

function fail() {
    echo "FAIL: " "$@"
    sleep 2
    pkill git-sync || true
    ps auxw | grep git-sync
    exit 1
}

function pass() {
    echo "PASS"
    TESTCASE=""
    git -C "$REPO" checkout -q master
}

function assert_link_exists() {
    if ! [[ -e "$1" ]]; then
        fail "$1 does not exist"
    fi
    if ! [[ -L "$1" ]]; then
        fail "$1 is not a symlink"
    fi
}

function assert_file_exists() {
    if ! [[ -f "$1" ]]; then
        fail "$1 does not exist"
    fi
}

function assert_file_eq() {
    if [[ $(cat "$1") == "$2" ]]; then
        return
    fi
    fail "file $1 does not contain '$2': $(cat $1)"
}

#########################
# main
#########################

# Build it
make container REGISTRY=e2e TAG=$(make -s version)

DIR=""
for i in $(seq 1 10); do
    DIR="/tmp/git-sync-test.$RANDOM"
    mkdir "$DIR" && break
done
if [[ -z "$DIR" ]]; then
    echo "Failed to make a temp dir"
    exit 1
fi
echo "test root is $DIR"

function GIT_SYNC() {
    #./bin/amd64/git-sync "$@"
    docker run \
        -i \
        -u $(id -u):$(id -g) \
        -v "$DIR":"$DIR" \
        e2e/git-sync-amd64:$(make -s version) \
        "$@"
}

REPO="$DIR/repo"
mkdir "$REPO"

ROOT="$DIR/root"
function clean_root() {
    rm -rf "$ROOT"
    mkdir "$ROOT"
}

# Init the temp repo.
TESTCASE=init
git -C "$REPO" init
touch "$REPO"/file
git -C "$REPO" add file
git -C "$REPO" commit -aqm "init file"

# Test HEAD one-time
testcase "head-once"
# First sync
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="$REPO" \
    --branch=master \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" \
    --one-time > "$DIR"/log."$TESTCASE" 2>&1
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

# Test default syncing
testcase "default-sync"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="$REPO" \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move backward
git -C "$REPO" reset -q --hard HEAD^
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pkill git-sync
wait
pass

# Test HEAD syncing
testcase "head-sync"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="$REPO" \
    --branch=master \
    --rev=HEAD \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move HEAD forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move HEAD backward
git -C "$REPO" reset -q --hard HEAD^
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pkill git-sync
wait
pass

# Test branch syncing
testcase "branch-sync"
BRANCH="$TESTCASE"--BRANCH
# First sync
git -C "$REPO" checkout -q -b "$BRANCH"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" checkout -q master
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="$REPO" \
    --branch="$BRANCH" \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add to the branch.
git -C "$REPO" checkout -q "$BRANCH"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" checkout -q master
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the branch backward
git -C "$REPO" checkout -q "$BRANCH"
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" checkout -q master
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pkill git-sync
wait
pass

# Test tag syncing
testcase "tag-sync"
TAG="$TESTCASE"--TAG
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 1" >/dev/null
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="$REPO" \
    --rev="$TAG" \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something and move the tag forward
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 2" >/dev/null
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the tag backward
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 3" >/dev/null
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something after the tag
echo "$TESTCASE 3" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 3"
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pkill git-sync
wait
pass

# Test cross-branch tag syncing
testcase "cross-branch-tag-sync"
BRANCH="$TESTCASE"--BRANCH
TAG="$TESTCASE"--TAG
# First sync
git -C "$REPO" checkout -q -b "$BRANCH"
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 1" >/dev/null
git -C "$REPO" checkout -q master
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="$REPO" \
    --rev="$TAG" \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move the tag forward
git -C "$REPO" checkout -q "$BRANCH"
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 1" >/dev/null
git -C "$REPO" checkout -q master
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 2"
# Move the tag backward
git -C "$REPO" checkout -q "$BRANCH"
git -C "$REPO" reset -q --hard HEAD^
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 1" >/dev/null
git -C "$REPO" checkout -q master
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Add something after the tag
git -C "$REPO" checkout -q "$BRANCH"
echo "$TESTCASE 3" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 3"
git -C "$REPO" checkout -q master
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Move the tag forward again
git -C "$REPO" checkout -q "$BRANCH"
git -C "$REPO" tag -af "$TAG" -m "$TESTCASE 3" >/dev/null
git -C "$REPO" checkout -q master
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 3"
# Wrap up
pkill git-sync
wait
pass

# Test rev syncing
testcase "rev-sync"
# First sync
echo "$TESTCASE 1" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 1"
REV=$(git -C "$REPO" rev-list -n1 HEAD)
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="$REPO" \
    --rev="$REV" \
    --root="$ROOT" \
    --dest="link" > "$DIR"/log."$TESTCASE" 2>&1 &
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Commit something new
echo "$TESTCASE 2" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE 2"
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Revert the last change
git -C "$REPO" reset -q --hard HEAD^
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE 1"
# Wrap up
pkill git-sync
wait
pass

# Test rev-sync one-time
testcase "rev-once"
# First sync
echo "$TESTCASE" > "$REPO"/file
git -C "$REPO" commit -qam "$TESTCASE"
REV=$(git -C "$REPO" rev-list -n1 HEAD)
GIT_SYNC \
    --logtostderr \
    --v=5 \
    --wait=0.1 \
    --repo="$REPO" \
    --rev="$REV" \
    --root="$ROOT" \
    --dest="link" \
    --one-time > "$DIR"/log."$TESTCASE" 2>&1
sleep 2
assert_link_exists "$ROOT"/link
assert_file_exists "$ROOT"/link/file
assert_file_eq "$ROOT"/link/file "$TESTCASE"
# Wrap up
pass

echo "cleaning up $DIR"
rm -rf "$DIR"
