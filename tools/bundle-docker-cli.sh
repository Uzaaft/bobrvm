#!/bin/bash
# Bundle pinned, checksum-verified Docker clients in a Bobrvm app.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 Bobrvm.app /path/to/bobrvm" >&2
    exit 2
fi

APP=$1
BOBRVM=$2
DOCKER_LAUNCHER=$(dirname "$BOBRVM")/bobrvm-docker-launcher
REPOSITORY_ROOT=$(cd "$(dirname "$0")/.." && pwd)
DOCKER_VERSION=29.7.2
COMPOSE_VERSION=5.4.0
BUILDX_VERSION=0.36.1
CREDENTIAL_VERSION=0.9.8

DOCKER_SHA256=b8683ed19d1f06048a496f9b8429e2c71d0b088d475b7487c054ea3666c02a3c
COMPOSE_SHA256=bc3d1fd4c01e3af9b481fc5ea153ea7c006c77eb39be78e9af3e2e8ebecc0d61
BUILDX_SHA256=214cdc36788602862dbc82b523d58648b4585c7b0ff95218b0817c44db5573d7
CREDENTIAL_SHA256=6fae515ffbc74f395af1b51c6f079ddb57895ed9e428e0bea3f6aff64e916b22

DOCKER_LICENSE_SHA256=2d81ea060825006fc8f3fe28aa5dc0ffeb80faf325b612c955229157b8c10dc0
COMPOSE_LICENSE_SHA256=58d1e17ffe5109a7ae296caafcadfdbe6a7d176f0bc4ab01e12a689b0499d8bd
BUILDX_LICENSE_SHA256=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
CREDENTIAL_LICENSE_SHA256=a6c2a5fdf40879f644bdb0da9042f245e7e263237d623264aafcf2470610ad8c

[ -d "$APP/Contents/MacOS" ] || { echo "invalid app bundle: $APP" >&2; exit 1; }
[ -x "$BOBRVM" ] || { echo "bobrvm CLI is not executable: $BOBRVM" >&2; exit 1; }
[ -x "$DOCKER_LAUNCHER" ] || {
    echo "Docker launcher is not executable: $DOCKER_LAUNCHER" >&2
    exit 1
}

WORK=$(mktemp -d /tmp/bobrvm-docker-tools.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

download() {
    local url=$1
    local output=$2
    curl --fail --location --proto '=https' --tlsv1.2 "$url" --output "$output"
}

verify() {
    local expected=$1
    local path=$2
    local actual
    actual=$(shasum -a 256 "$path" | cut -d ' ' -f 1)
    [ "$actual" = "$expected" ] || {
        echo "checksum mismatch for $path: expected $expected, got $actual" >&2
        exit 1
    }
}

download \
    "https://download.docker.com/mac/static/stable/aarch64/docker-$DOCKER_VERSION.tgz" \
    "$WORK/docker.tgz"
download \
    "https://github.com/docker/compose/releases/download/v$COMPOSE_VERSION/"\
"docker-compose-darwin-aarch64" \
    "$WORK/docker-compose"
download \
    "https://github.com/docker/buildx/releases/download/v$BUILDX_VERSION/"\
"buildx-v$BUILDX_VERSION.darwin-arm64" \
    "$WORK/docker-buildx"
download \
    "https://github.com/docker/docker-credential-helpers/releases/download/"\
"v$CREDENTIAL_VERSION/docker-credential-osxkeychain-v$CREDENTIAL_VERSION.darwin-arm64" \
    "$WORK/docker-credential-osxkeychain"

verify "$DOCKER_SHA256" "$WORK/docker.tgz"
verify "$COMPOSE_SHA256" "$WORK/docker-compose"
verify "$BUILDX_SHA256" "$WORK/docker-buildx"
verify "$CREDENTIAL_SHA256" "$WORK/docker-credential-osxkeychain"
tar -xzf "$WORK/docker.tgz" -C "$WORK"

download "https://raw.githubusercontent.com/docker/cli/v$DOCKER_VERSION/LICENSE" \
    "$WORK/LICENSE.docker-cli"
download "https://raw.githubusercontent.com/docker/compose/v$COMPOSE_VERSION/LICENSE" \
    "$WORK/LICENSE.docker-compose"
download "https://raw.githubusercontent.com/docker/buildx/v$BUILDX_VERSION/LICENSE" \
    "$WORK/LICENSE.docker-buildx"
download \
    "https://raw.githubusercontent.com/docker/docker-credential-helpers/"\
"v$CREDENTIAL_VERSION/LICENSE" \
    "$WORK/LICENSE.docker-credential-helpers"

verify "$DOCKER_LICENSE_SHA256" "$WORK/LICENSE.docker-cli"
verify "$COMPOSE_LICENSE_SHA256" "$WORK/LICENSE.docker-compose"
verify "$BUILDX_LICENSE_SHA256" "$WORK/LICENSE.docker-buildx"
verify "$CREDENTIAL_LICENSE_SHA256" "$WORK/LICENSE.docker-credential-helpers"

BIN="$APP/Contents/MacOS/bin"
XBIN="$APP/Contents/MacOS/xbin"
LICENSES="$APP/Contents/Resources/licenses"
mkdir -p "$BIN" "$XBIN" "$LICENSES"
cp "$BOBRVM" "$BIN/bobrvm"
cp "$DOCKER_LAUNCHER" "$XBIN/docker-launcher"
cp "$WORK/docker/docker" "$XBIN/docker-cli"
cp "$WORK/docker-compose" "$XBIN/docker-compose-cli"
cp "$WORK/docker-buildx" "$XBIN/docker-buildx-cli"
cp "$WORK/docker-credential-osxkeychain" "$XBIN/docker-credential-osxkeychain"
cp "$WORK"/LICENSE.* "$LICENSES/"
chmod 755 "$BIN/bobrvm" "$XBIN"/*
ln -sfn docker-launcher "$XBIN/docker"
ln -sfn docker-buildx-cli "$XBIN/docker-buildx"
ln -sfn docker-launcher "$XBIN/docker-compose"

# The bundle changes after Xcode signs it. Sign nested executables first so
# the outer seal records their final signatures, and preserve the VZ/HVF
# entitlements on both native bobrvm entry points.
codesign --force --sign - --options runtime "$XBIN/docker-cli"
codesign --force --sign - --options runtime "$XBIN/docker-launcher"
codesign --force --sign - --options runtime "$XBIN/docker-compose-cli"
codesign --force --sign - --options runtime "$XBIN/docker-buildx-cli"
codesign --force --sign - --options runtime "$XBIN/docker-credential-osxkeychain"
codesign --force --sign - --options runtime \
    --entitlements "$REPOSITORY_ROOT/cli.entitlements" "$BIN/bobrvm"
codesign --force --sign - --options runtime \
    --entitlements "$REPOSITORY_ROOT/macos/Bobrvm.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
