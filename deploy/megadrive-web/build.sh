#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_dir="${1:-/tmp/drp-megadrive-build}"
core_commit="fa4dca561e08d5be9077419f7b255e1da213ed21"
image="emscripten/emsdk:3.1.54"

mkdir -p "$build_dir"
if [[ ! -d "$build_dir/Genesis-Plus-GX/.git" ]]; then
  git clone https://github.com/libretro/Genesis-Plus-GX.git "$build_dir/Genesis-Plus-GX"
fi
git -C "$build_dir/Genesis-Plus-GX" fetch --depth 1 origin "$core_commit"
git -C "$build_dir/Genesis-Plus-GX" config core.fileMode false
git -C "$build_dir/Genesis-Plus-GX" checkout --detach "$core_commit"
cp "$project_dir/md_frontend.c" "$build_dir/md_frontend.c"
archive="$build_dir/genesis_plus_gx_libretro_emscripten.a"
core_container_id=""
link_container_id=""

cleanup() {
  [[ -z "$core_container_id" ]] || docker rm -f "$core_container_id" >/dev/null 2>&1 || true
  [[ -z "$link_container_id" ]] || docker rm -f "$link_container_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ ! -s "$archive" ]]; then
  core_container_id="$(docker create \
    --platform linux/amd64 \
    -w /src/Genesis-Plus-GX \
    "$image" \
    bash -lc '
      set -e
      emmake make -f Makefile.libretro clean platform=emscripten HAVE_CHD=0
      emmake make -f Makefile.libretro -j6 platform=emscripten HAVE_CHD=0
      cp genesis_plus_gx_libretro_emscripten.bc /src/genesis_plus_gx_libretro_emscripten.a
    ')"
  docker cp "$build_dir/." "$core_container_id:/src"
  docker start -a "$core_container_id"
  docker cp "$core_container_id:/src/genesis_plus_gx_libretro_emscripten.a" "$archive"
  docker rm "$core_container_id" >/dev/null
  core_container_id=""
fi

link_container_id="$(docker create \
  --platform linux/amd64 \
  -w /src/Genesis-Plus-GX \
  "$image" \
  bash -lc '
    set -e
    emcc /src/md_frontend.c /src/genesis_plus_gx_libretro_emscripten.a \
      libretro/libretro-common/streams/file_stream.c \
      libretro/libretro-common/compat/fopen_utf8.c \
      libretro/libretro-common/compat/compat_snprintf.c \
      libretro/libretro-common/compat/compat_strl.c \
      libretro/libretro-common/compat/compat_strcasestr.c \
      libretro/libretro-common/compat/compat_posix_string.c \
      libretro/libretro-common/encodings/encoding_utf.c \
      libretro/libretro-common/file/file_path.c \
      libretro/libretro-common/file/retro_dirent.c \
      libretro/libretro-common/lists/string_list.c \
      libretro/libretro-common/lists/dir_list.c \
      libretro/libretro-common/memmap/memalign.c \
      libretro/libretro-common/string/stdstring.c \
      libretro/libretro-common/vfs/vfs_implementation.c \
      -I. \
      -Ilibretro \
      -Ilibretro/libretro-common/include \
      -O3 \
      -DNDEBUG \
      -s MODULARIZE=1 \
      -s EXPORT_NAME=DRPMegaDriveCore \
      -s ENVIRONMENT=web,node \
      -s ALLOW_MEMORY_GROWTH=1 \
      -s INITIAL_MEMORY=33554432 \
      -s MAXIMUM_MEMORY=268435456 \
      -s FILESYSTEM=1 \
      -s ASSERTIONS=0 \
      -s MIN_CHROME_VERSION=80 \
      -s MALLOC=emmalloc \
      -s EXPORTED_FUNCTIONS='"'"'["_malloc","_free","_md_bootstrap","_md_load","_md_run_frame","_md_reset","_md_unload","_md_set_input","_md_frame_pointer","_md_frame_width","_md_frame_height","_md_audio_pointer","_md_audio_frames","_md_fps","_md_sample_rate","_md_sram_pointer","_md_sram_size"]'"'"' \
      -s EXPORTED_RUNTIME_METHODS='"'"'["ccall"]'"'"' \
      -o /src/megadrive.js
  ')"
docker cp "$build_dir/." "$link_container_id:/src"
docker start -a "$link_container_id"
docker cp "$link_container_id:/src/megadrive.js" "$project_dir/megadrive.js"
docker cp "$link_container_id:/src/megadrive.wasm" "$project_dir/megadrive.wasm"
docker rm "$link_container_id" >/dev/null
link_container_id=""
perl -pi -e "s/_scriptDir \\|\\|= __filename;/if (!_scriptDir) _scriptDir = __filename;/" "$project_dir/megadrive.js"
sha256sum "$project_dir/megadrive.js" "$project_dir/megadrive.wasm"
