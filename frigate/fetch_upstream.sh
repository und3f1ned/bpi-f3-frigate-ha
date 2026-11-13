#!/usr/bin/env bash
# Extracts /opt/frigate (Frigate code and the built web UI, both architecture-independent)
# from the official arm64 image ghcr.io/blakeblackshear/frigate:<version>, downloading only
# the top layers rather than the whole image (~2 GB).
#   fetch_upstream.sh 0.18.2 .cache/frigate-upstream-0.18.2
set -euo pipefail
ver=$1 out=$2 repo=blakeblackshear/frigate
[ -f "$out/.done" ] && exit 0

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
tok=$(curl -4 -fsSL "https://ghcr.io/token?scope=repository:$repo:pull" | json 'd["token"]')
auth=(-H "Authorization: Bearer $tok")
dig=$(curl -4 -fsSL "${auth[@]}" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' \
        "https://ghcr.io/v2/$repo/manifests/$ver" \
      | json 'next(m["digest"] for m in d["manifests"] if m["platform"]["os"]=="linux" and m["platform"]["architecture"]=="arm64")')
# layers from top to bottom: "digest mediaType"
mapfile -t layers < <(curl -4 -fsSL "${auth[@]}" \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
        "https://ghcr.io/v2/$repo/manifests/$dig" \
      | json '"\n".join(l["digest"] + " " + l["mediaType"] for l in reversed(d["layers"]))')

rm -rf "$out"; mkdir -p "$out"
for entry in "${layers[@]:0:4}"; do
  d=${entry%% *} mt=${entry#* }
  case "$mt" in *zstd*) z=--zstd ;; *gzip*) z=-z ;; *) z= ;; esac
  # curl doesn't pass the Authorization header to the CDN when redirected to another host
  curl -4 -fsSL "${auth[@]}" "https://ghcr.io/v2/$repo/blobs/$d" \
    | tar -x $z -C "$out" --wildcards 'opt/frigate/*' 2>/dev/null || true
  if [ -f "$out/opt/frigate/frigate/__main__.py" ] && [ -f "$out/opt/frigate/web/index.html" ]; then
    touch "$out/.done"
    echo "    /opt/frigate from layer ${d:7:12}: $(du -sh "$out/opt/frigate" | cut -f1)"
    exit 0
  fi
done
echo "/opt/frigate not found in the top layers of $repo:$ver (arm64)" >&2
exit 1
