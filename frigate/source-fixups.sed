# Fixes to Frigate's build scripts (docker/main/build_nginx.sh, build_sqlite_vec.sh,
# build_pysqlite3.sh) for Debian 13 / riscv64. Applied to every version; if a line isn't there,
# the rule does nothing.

# Debian 13 keeps apt sources in deb822 format (/etc/apt/sources.list.d/debian.sources), but the
# scripts tell the formats apart by VERSION_ID == "12".
s|"$VERSION_ID" == "12"|-f /etc/apt/sources.list.d/debian.sources|

# GCC 14 turns these warnings into errors; the nginx modules were written for GCC 12.
s|-Wno-error=implicit-fallthrough"|-Wno-error=implicit-fallthrough -Wno-error=incompatible-pointer-types -Wno-error=int-conversion -Wno-error=implicit-function-declaration"|

# The kaltura/nginx-vod-module and kaltura/nginx-secure-token-module repos were removed from
# GitHub (Frigate dev switched to dio-az/nginx-vod-module). For older releases the same tags come
# from forks: vod 1.31 = commit 4bce0c8afa, secure-token 1.5 = 18aca97ebf (identical in several
# independent forks).
s|github.com/kaltura/nginx-vod-module/|github.com/SRGSSR/nginx-vod-module/|g
s|github.com/kaltura/nginx-secure-token-module/|github.com/dvershinin/nginx-secure-token-module/|g

# pysqlite3 before 0.5.4 doesn't build on Python 3.13 (removed internal APIs: _PyTime_t etc.).
s|PYSQLITE3_VERSION="0\.5\.[0-3]"|PYSQLITE3_VERSION="0.5.4"|
