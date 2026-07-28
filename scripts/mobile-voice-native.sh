#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="1.13.4"
release_url="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${version}"
cache_root="${BUZZ_VOICE_NATIVE_CACHE:-${HOME}/Library/Caches/buzz-mobile-voice/sherpa-onnx-v${version}}"
generated_root="${repo_root}/mobile/.generated/voice"

android_archive="sherpa-onnx-v${version}-android.tar.bz2"
android_sha256="7983fc3de23f6e64148f2fb05fa94a2efaa8c0516cc1573383dc5c7d4d2a43b0"
ios_archive="sherpa-onnx-v${version}-ios.tar.bz2"
ios_sha256="596f33bff80046a52144745745fe54d55e8b23659d92209f5ab7d94c1259fe6d"

usage() {
  echo "usage: $0 fetch|build-ios|build-ios-current|build-android|build-all" >&2
  exit 2
}

verify_sha256() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "checksum mismatch for $path: expected $expected, got $actual" >&2
    return 1
  fi
}

fetch_archive() {
  local archive="$1"
  local expected="$2"
  mkdir -p "$cache_root"
  if [[ -f "${cache_root}/${archive}" ]] &&
    ! verify_sha256 "${cache_root}/${archive}" "$expected"; then
    rm "${cache_root:?}/${archive}"
  fi
  if [[ ! -f "${cache_root}/${archive}" ]]; then
    curl --fail --location --retry 3 \
      --output "${cache_root}/${archive}.part" \
      "${release_url}/${archive}"
    verify_sha256 "${cache_root}/${archive}.part" "$expected"
    mv "${cache_root}/${archive}.part" "${cache_root}/${archive}"
  fi
}

extract_archive() {
  local archive="$1"
  local expected="$2"
  local destination="$3"
  fetch_archive "$archive" "$expected"
  if [[ -f "${destination}/.complete" ]]; then
    return
  fi
  local staging="${destination}.install-$$"
  rm -rf "$staging"
  mkdir -p "$staging"
  tar xjf "${cache_root}/${archive}" -C "$staging"
  touch "${staging}/.complete"
  rm -rf "$destination"
  mv "$staging" "$destination"
}

fetch_native() {
  extract_archive "$android_archive" "$android_sha256" "${cache_root}/android"
  extract_archive "$ios_archive" "$ios_sha256" "${cache_root}/ios"
}

ios_lib_dir() {
  local sdk="$1"
  local arch="$2"
  local sherpa_slice
  local ort_slice
  if [[ "$sdk" == "iphoneos" ]]; then
    sherpa_slice="ios-arm64"
    ort_slice="ios-arm64"
  else
    sherpa_slice="ios-arm64_x86_64-simulator"
    ort_slice="ios-arm64_x86_64-simulator"
  fi
  local destination="${generated_root}/ios/native/${sdk}-${arch}"
  mkdir -p "$destination"
  local sherpa_binary="${cache_root}/ios/build-ios/sherpa-onnx.xcframework/${sherpa_slice}/libsherpa-onnx.a"
  if [[ "$sdk" == "iphoneos" ]]; then
    cp "$sherpa_binary" "${destination}/libsherpa-onnx.a"
  else
    lipo "$sherpa_binary" -thin "$arch" -output "${destination}/libsherpa-onnx.a"
  fi
  local ort_binary="${cache_root}/ios/build-ios/ios-onnxruntime/1.27.0/onnxruntime.xcframework/${ort_slice}/onnxruntime.framework/onnxruntime"
  lipo "$ort_binary" -thin "$arch" -output "${destination}/libonnxruntime.a"
  printf '%s\n' "$destination"
}

build_ios_target() {
  local target="$1"
  local sdk="$2"
  local arch="$3"
  local lib_dir
  lib_dir="$(ios_lib_dir "$sdk" "$arch")"
  IPHONEOS_DEPLOYMENT_TARGET=16.0 SHERPA_ONNX_LIB_DIR="$lib_dir" \
    cargo build --release -p buzz-voice-mobile --target "$target"
  local destination="${generated_root}/ios/${sdk}-${arch}"
  mkdir -p "$destination"
  rm -f "$destination/libbuzz_voice_mobile.a"
  cp "${repo_root}/target/${target}/release/libbuzz_voice_mobile.a" "$destination/"
}

build_ios() {
  fetch_native
  build_ios_target "aarch64-apple-ios" "iphoneos" "arm64"
  build_ios_target "aarch64-apple-ios-sim" "iphonesimulator" "arm64"
  build_ios_target "x86_64-apple-ios" "iphonesimulator" "x86_64"
}

build_ios_current() {
  fetch_native
  local platform="${PLATFORM_NAME:-${SDK_NAME%%[0-9]*}}"
  local arch="${CURRENT_ARCH:-}"
  if [[ -z "$arch" || "$arch" == "undefined_arch" ]]; then
    if [[ " ${ARCHS:-} " == *" arm64 "* ]]; then
      arch="arm64"
    elif [[ " ${ARCHS:-} " == *" x86_64 "* ]]; then
      arch="x86_64"
    fi
  fi
  case "${platform}:${arch}" in
    iphoneos:arm64)
      build_ios_target "aarch64-apple-ios" "iphoneos" "arm64"
      ;;
    iphonesimulator:arm64)
      build_ios_target "aarch64-apple-ios-sim" "iphonesimulator" "arm64"
      ;;
    iphonesimulator:x86_64)
      build_ios_target "x86_64-apple-ios" "iphonesimulator" "x86_64"
      ;;
    *)
      echo "unsupported iOS platform/architecture: ${platform:-unset}/${arch:-unset}" >&2
      exit 1
      ;;
  esac
}

android_target() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-android" ;;
    x86_64) echo "x86_64-linux-android" ;;
    *) return 1 ;;
  esac
}

build_android_abi() {
  local abi="$1"
  local target
  target="$(android_target "$abi")"
  local ndk_root="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  if [[ -z "$ndk_root" ]]; then
    echo "ANDROID_NDK_HOME must point at an Android NDK" >&2
    exit 1
  fi
  local host_os
  case "$(uname -s)" in
    Darwin) host_os="darwin" ;;
    Linux) host_os="linux" ;;
    MINGW* | MSYS* | CYGWIN*) host_os="windows" ;;
    *)
      echo "Unsupported Android NDK host OS: $(uname -s)" >&2
      exit 1
      ;;
  esac
  local host_arch
  case "$(uname -m)" in
    arm64 | aarch64) host_arch="arm64" ;;
    x86_64 | amd64) host_arch="x86_64" ;;
    *)
      echo "Unsupported Android NDK host architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
  local api="${BUZZ_ANDROID_MIN_API:-24}"
  local clang_target
  if [[ "$abi" == "arm64-v8a" ]]; then
    clang_target="aarch64-linux-android${api}"
  else
    clang_target="x86_64-linux-android${api}"
  fi
  local prebuilt_root="${ndk_root}/toolchains/llvm/prebuilt"
  local toolchain="${prebuilt_root}/${host_os}-${host_arch}"
  local linker="${toolchain}/bin/${clang_target}-clang"
  if [[ ! -x "$linker" ]]; then
    local candidate
    for candidate in "${prebuilt_root}/${host_os}-"*; do
      if [[ -x "${candidate}/bin/${clang_target}-clang" ]]; then
        toolchain="$candidate"
        linker="${candidate}/bin/${clang_target}-clang"
        break
      fi
    done
  fi
  if [[ ! -x "$linker" ]]; then
    echo "Android linker not found: $linker" >&2
    exit 1
  fi
  local source_libs="${cache_root}/android/jniLibs/${abi}"
  local target_env
  target_env="$(printf '%s' "$target" | tr '[:lower:]-' '[:upper:]_')"
  local linker_var="CARGO_TARGET_${target_env}_LINKER"
  local rustflags_var="CARGO_TARGET_${target_env}_RUSTFLAGS"
  if ! rustup target list --installed | grep -Fxq "$target"; then
    rustup target add "$target"
  fi
  env \
    SHERPA_ONNX_LIB_DIR="$source_libs" \
    "$linker_var=$linker" \
    "$rustflags_var=-L native=${source_libs}" \
    cargo rustc --release -p buzz-voice-mobile --no-default-features \
      --features shared --target "$target" --lib -- --crate-type cdylib

  local destination="${generated_root}/android/jniLibs/${abi}"
  mkdir -p "$destination"
  local shared_library="${repo_root}/target/${target}/release/libbuzz_voice_mobile.so"
  if [[ ! -f "$shared_library" ]]; then
    echo "Android cdylib was not produced for $target" >&2
    exit 1
  fi
  cp "$shared_library" "${destination}/libbuzz_voice_mobile.so"
  cp "${source_libs}/libsherpa-onnx-c-api.so" "$destination/"
  cp "${source_libs}/libonnxruntime.so" "$destination/"
}

build_android() {
  fetch_native
  build_android_abi "arm64-v8a"
  build_android_abi "x86_64"
}

case "${1:-}" in
  fetch) fetch_native ;;
  build-ios) build_ios ;;
  build-ios-current) build_ios_current ;;
  build-android) build_android ;;
  build-all)
    build_ios
    build_android
    ;;
  *) usage ;;
esac
