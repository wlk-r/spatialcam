#!/usr/bin/env bash
# run_colmap.sh — session folder -> posed COLMAP model, using ARKit poses as known.
# Triangulates structure against the poses (no pose re-solve), then bundle-adjusts to
# correct VIO drift. Requires `colmap` on PATH.
#
#   ./run_colmap.sh <session_dir> <out_dir> [exhaustive|sequential]
#
set -euo pipefail

SESSION="${1:?session dir}"
OUT="${2:?output dir}"
MATCHER="${3:-sequential}"   # sequential for a single continuous walk; exhaustive for loopy/unordered

DB="$OUT/database.db"
IMAGES="$OUT/images"
MANUAL="$OUT/sparse/manual"
TRI="$OUT/sparse/triangulated"
REFINED="$OUT/sparse/refined"

# 0) Sanity: prove the conversion math before touching real data.
python validate.py selftest

# 1) Copy images + write an inspection model (sequential IDs).
python export_colmap.py --session "$SESSION" --out "$OUT"

# 2) Features + matches. single_camera 0 => one camera per image (matches per-frame intrinsics).
# single_camera_per_image is required: with EXIF embedded (sidecar-v2 captures) all
# images share Make/Model/focal, so COLMAP would otherwise collapse them onto ONE
# shared camera and the per-image manual model would have duplicate CAMERA_IDs
# (point_triangulator aborts on load).
colmap feature_extractor \
  --database_path "$DB" --image_path "$IMAGES" \
  --ImageReader.camera_model PINHOLE --ImageReader.single_camera_per_image 1 \
  --SiftExtraction.estimate_affine_shape 1 --SiftExtraction.domain_size_pooling 1

if [ "$MATCHER" = "exhaustive" ]; then
  colmap exhaustive_matcher --database_path "$DB"
else
  colmap sequential_matcher --database_path "$DB" \
    --SequentialMatching.overlap 10 --SequentialMatching.quadratic_overlap 1
fi

# 3) Re-export with DB-aligned IMAGE_ID/CAMERA_ID (required by point_triangulator),
#    overwriting the DB's camera params with our ARKit intrinsics.
python export_colmap.py --session "$SESSION" --out "$OUT" --database "$DB"

# 4) Triangulate against the KNOWN poses (does not re-estimate poses).
mkdir -p "$TRI"
colmap point_triangulator \
  --database_path "$DB" --image_path "$IMAGES" \
  --input_path "$MANUAL" --output_path "$TRI"

# 5) Global bundle adjustment — corrects accumulated VIO drift.
mkdir -p "$REFINED"
colmap bundle_adjuster --input_path "$TRI" --output_path "$REFINED"

# 6) Empirical proof the flip/poses are right: cheirality + reprojection error.
python validate.py reproject "$TRI"

echo
echo "Done. Refined model: $REFINED"
echo "Next (existing pipeline): undistort if needed -> Brush -> splat-transform."
echo "PINHOLE is emitted directly (ARKit intrinsics are ~pinhole), so image_undistorter is usually unnecessary."
