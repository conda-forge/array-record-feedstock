#!/bin/bash

set -xe

export PYTHON_VERSION=$(${PYTHON} -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
export PYTHON_MAJOR_VERSION=$(echo $PYTHON_VERSION | cut -d. -f1)
export PYTHON_MINOR_VERSION=$(echo $PYTHON_VERSION | cut -d. -f2)
export BAZEL_VERSION="7.2.1"
export OUTPUT_DIR="$(pwd)"
export SOURCE_DIR="."
. "./oss/runner_common.sh"

# Workaround for a timestamp issue: https://github.com/prefix-dev/rattler-build/issues/1865
touch -m -t 203510100101 $(find $BUILD_PREFIX/share/bazel/install -type f)

setup_env_vars_py "$PYTHON_MAJOR_VERSION" "$PYTHON_MINOR_VERSION"

function write_to_bazelrc() {
  echo "$1" >> .bazelrc
}

extra_bazel_build_args=()
bazel_build_targets="..."
if [[ "${target_platform}" == osx-* ]]; then
  # Bazel's builtin C++ toolchain autoconfiguration reaches for the std*.h
  # headers from the real Xcode SDK instead of the ones under
  # CONDA_BUILD_SYSROOT, which breaks the build. Point bazel at the
  # crosstool that bazel-toolchain generates from the active conda
  # compilers instead: https://github.com/conda-forge/bazel-toolchain-feedstock
  source gen-bazel-toolchain
  write_to_bazelrc "build --crosstool_top=//bazel_toolchain:toolchain"
  write_to_bazelrc "build --platforms=//bazel_toolchain:target_platform"
  write_to_bazelrc "build --host_platform=//bazel_toolchain:build_platform"
  write_to_bazelrc "build --extra_toolchains=//bazel_toolchain:cc_cf_toolchain"
  write_to_bazelrc "build --extra_toolchains=//bazel_toolchain:cc_cf_host_toolchain"
  write_to_bazelrc "build --action_env MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}"
  extra_bazel_build_args+=(--cpu="${TARGET_CPU}")
  # `bazel build ...` treats every package as a top-level target. That makes
  # Bazel build a standalone .so for every cc_library it touches, ours and
  # every transitive dependency's alike, and each one must resolve 100% of
  # its own symbols at build time. Linux tolerates unresolved symbols in a
  # .so until runtime; macOS does not. So these standalone libraries fail to
  # link whenever they need a symbol that actually lives in a sibling
  # library. array_record only ships one pybind extension,
  # python/array_record_module.so, which statically links in everything
  # else it needs. Build just that instead of the whole tree.
  bazel_build_targets="//python:array_record_module.so"
  # Also cover anything Bazel still builds as a *dependency* along the way
  # (e.g. of a cc_test), which the target list above doesn't control.
  write_to_bazelrc "build --dynamic_mode=off"
  # bazel-toolchain's generic toolchain config bakes -stdlib=libc++ into
  # every compile action, C/ASM included, where it's meaningless. Recent
  # Apple clang turns that "unused argument" warning into a hard error, e.g.
  # when compiling boringssl's .S files. Unresolved upstream:
  # https://github.com/conda-forge/bazel-toolchain-feedstock/issues/18
  write_to_bazelrc "build --copt=-Wno-unused-command-line-argument"
  write_to_bazelrc "build --host_copt=-Wno-unused-command-line-argument"
  if [[ "${target_platform}" == "osx-64" ]]; then
    # crc32c only adds -msse4.2 when Bazel's --cpu flag is "darwin", the
    # old built-in value for Intel macOS. bazel-toolchain instead sets
    # --cpu=darwin_x86_64, so that check never matches and crc32c_sse42.cc
    # compiles without -msse4.2 even though it needs it. Add the flag
    # ourselves; every real osx-64 Mac supports SSE4.2 anyway.
    write_to_bazelrc "build --copt=-msse4.2"
    write_to_bazelrc "build --host_copt=-msse4.2"
    # Same --cpu mismatch hits highwayhash's hh_sse41.cc/hh_avx2.cc: missing
    # -msse4.1/-mavx2 also means they get built with -DHH_DISABLE_TARGET_SPECIFIC,
    # which #ifdefs the actual SIMD code out entirely rather than just
    # compiling it wrong, so the fix needs to -U that macro too, not just
    # add the ISA flag back. Scoped to just these two files (via
    # --per_file_copt) instead of a blanket flag, since that would raise
    # the whole binary's minimum CPU requirement, not just these two files.
    write_to_bazelrc "build --per_file_copt=.*highwayhash/hh_sse41\.cc@-msse4.1,-UHH_DISABLE_TARGET_SPECIFIC"
    write_to_bazelrc "build --per_file_copt=.*highwayhash/hh_avx2\.cc@-mavx2,-UHH_DISABLE_TARGET_SPECIFIC"
    write_to_bazelrc "build --host_per_file_copt=.*highwayhash/hh_sse41\.cc@-msse4.1,-UHH_DISABLE_TARGET_SPECIFIC"
    write_to_bazelrc "build --host_per_file_copt=.*highwayhash/hh_avx2\.cc@-mavx2,-UHH_DISABLE_TARGET_SPECIFIC"
  fi
fi

write_to_bazelrc "build -c opt"
write_to_bazelrc "build --cxxopt=-std=c++17"
write_to_bazelrc "build --host_cxxopt=-std=c++17"
write_to_bazelrc "build --experimental_repo_remote_exec"
write_to_bazelrc "build --python_path=\"${PYTHON_BIN}\""
write_to_bazelrc "build --incompatible_default_to_explicit_init_py"
write_to_bazelrc "build --enable_platform_specific_config"
write_to_bazelrc "build --@rules_python//python/config_settings:python_version=${PYTHON_VERSION}"
write_to_bazelrc "test --@rules_python//python/config_settings:python_version=${PYTHON_VERSION}"
write_to_bazelrc "test --action_env PYTHON_VERSION=${PYTHON_VERSION}"
write_to_bazelrc "test --test_timeout=300"
write_to_bazelrc "test --python_path=\"${PYTHON_BIN}\""
write_to_bazelrc "common --check_direct_dependencies=error"
# Reduce noise during build.
write_to_bazelrc "build --cxxopt=-Wno-deprecated-declarations --host_cxxopt=-Wno-deprecated-declarations"
write_to_bazelrc "build --cxxopt=-Wno-parentheses --host_cxxopt=-Wno-parentheses"
write_to_bazelrc "build --cxxopt=-Wno-sign-compare --host_cxxopt=-Wno-sign-compare"

export USE_BAZEL_VERSION="${BAZEL_VERSION}"
bazel clean
bazel build ${bazel_build_targets} --action_env PYTHON_BIN_PATH="${PYTHON_BIN}" "${extra_bazel_build_args[@]}"

DEST="${OUTPUT_DIR}"'/all_dist'
mkdir -p "${DEST}/array_record"

TMPDIR="$(mktemp -d -t tmp.XXXXXXXXXX)"
cp setup.py "${TMPDIR}"
cp LICENSE "${TMPDIR}"
rsync -avm -L  --exclude="bazel-*/" . "${TMPDIR}/array_record"
# CPython requires extension modules to be named *.so on every platform,
# including macOS, where that's what bazel/pybind11 actually produces. Don't
# filter on ${SHLIB_EXT} here: conda sets it to .dylib on macOS (the
# platform's native library extension), which would never match and silently
# ship a wheel without the compiled extension.
rsync -avm -L  --include="*.so" --include="*_pb2.py" \
  --exclude="*.runfiles" --exclude="*_obj" --include="*/" --exclude="*" \
  bazel-bin/cpp "${TMPDIR}/array_record"
rsync -avm -L  --include="*.so" --include="*_pb2.py" \
  --exclude="*.runfiles" --exclude="*_obj" --include="*/" --exclude="*" \
  bazel-bin/python "${TMPDIR}/array_record"

previous_wd="$(pwd)"
cd "${TMPDIR}"
printf '%s : === Building wheel\n' "$(date)"
$PYTHON setup.py bdist_wheel --python-tag py3"${PYTHON_MINOR_VERSION}"

cp dist/*.whl "${DEST}"

printf '%s : === Listing wheel\n' "$(date)"
ls -lrt "${DEST}"/*.whl
cd "${previous_wd}"

printf '%s : === Output wheel file is in: %s\n' "$(date)" "${DEST}"

$PYTHON -m pip install "${DEST}"/array_record*.whl

# bazel creates a bunch of u-w directories in BUILD_PREFIX, breaking cleanup
chmod -R u+w "${BUILD_PREFIX}"/share/bazel
