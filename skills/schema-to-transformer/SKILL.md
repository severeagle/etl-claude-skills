---
name: schema-to-transformer
description: Generate the pipeline transformer.py (rename columns, derive WKT geometry columns, single-file or batch Prefect flow) next to a pipeline's extractor.py and pandera schema(s).py, adding the missing *TransformedSchema when needed. Use when the user asks to create, add, or generate a transformer / transform flow for an ETL pipeline, or invokes /schema-to-transformer <path/to/pipeline/folder>.
---

# schema-to-transformer

Write `transformer.py` for a pipeline folder that already has a working `extractor.py`
and a `schema.py` / `schemas.py` holding the extract schema. The transformer reads the
latest extract from `EXTRACT_BUCKET`, renames columns to English snake_case, turns the
geometry into WKT columns, and writes a parquet to `TRANSFORM_BUCKET` validated by the
`*TransformedSchema`.

Argument: `$ARGUMENTS` is the pipeline folder (or any file inside it). If missing, ask
for it.

You may open:

- every file in the pipeline folder (`extractor.py`, `schema.py`/`schemas.py`,
  `loader.py`, an existing `transformer.py`)
- `lib/common/tasks/extractors.py` — only to read the default arguments of the
  extractor task the pipeline calls (e.g. `projection_srid` of `extract_wfs_layer`)
- `lib/common/validations/geom.py` — only to confirm helper names
- the `transformer.py` and `schema(s).py` of **one** sibling pipeline of the same
  entity (e.g. `.../espoo/units/` when writing `.../helsinki/units/`), to copy its
  derived-column choices

Do **not** read dbt models, migrations, the legacy `pipelines/etl/geo/cities/**`
pipelines, or unrelated pipelines.

This skill is meant to run unattended (`claude -p`). Once the prerequisites in Step 1
hold, write the first draft **without asking**, even when a choice is uncertain: pick
the default given below, and list the choice as a question in the Step 7 report. Stop
before writing only for the hard failures named in Step 1.

## Step 1 – prerequisites (stop and report if any fails)

In the pipeline folder confirm:

1. `extractor.py` exists and calls `load_dataframe_to_storage(...)`.
2. Exactly one of `schema.py` / `schemas.py` exists. Remember which; every import in
   the generated file uses that module name (`from .schema import ...` or
   `from .schemas import ...`).
3. The schema module defines `EXTRACT_BUCKET`, `TRANSFORM_BUCKET`, `BUCKET_ROOT`, and
   exactly one `pa.DataFrameSchema` whose name contains `Extract`. Several
   `*Extract*Schema` candidates → stop and ask which one.
4. If the extract schema has non-English or non-snake_case column names, a
   `dict[str, str]` rename mapping must exist (normally `COLUMN_TRANSLATIONS`; older
   files use `RENAME_DICT`). Missing → stop and report: run
   `/schema-column-translations <schema file>` first. If every extract column is
   already English snake_case, no mapping is needed and Step 5 skips the rename.

Also warn (but do not stop) when `BUCKET_ROOT` is identical to the `BUCKET_ROOT` of
another pipeline (`grep -rn "BUCKET_ROOT = \"<value>\"" pipelines/`). A shared root
makes `get_latest_bucket_folder` pick the newest run of *any* of those pipelines.

## Step 2 – read facts from extractor.py

| Fact | How to determine it | Used for |
|------|---------------------|----------|
| **Source CRS** | `projection_srid=` argument of the extractor call; if absent, the default of that task in `lib/common/tasks/extractors.py` (`extract_wfs_layer` → 4326). Non-WFS extractors: look for `to_crs`/`set_crs`/`crs=`; if none, default to 4326 and flag it. | which `to_crs` calls are needed |
| **Single vs batch** | One `load_dataframe_to_storage` call, not inside a loop → **single-file**. A loop / several calls / chunked paths → **batch**. | which flow template |
| **File extension** | the `path=` argument (`.gpkg`, `.parquet`, ...) | the `# replace X -> parquet` comment |

## Step 3 – derive constants from the path

From `pipelines/etl/<domain>/<entity>/.../<country>/...`:

| Item | Rule |
|------|------|
| Local SRID (`*_etrs89`) | `finland` → `3067`, `denmark` → `25832`, other → `3067` + flag |
| Task name | `transform_<entity>` in snake_case (`transform_detail_plan_units`); batch flows use `transform_batch` |
| Schema names | `<ExtractSchemaName>` as found; transformed = same stem with `Extract`/`Extracted` replaced by `Transformed` (`FooExtractSchema` → `FooTransformedSchema`) |

## Step 4 – geometry shape: decided by the DATA, never by examples

**The geometry type of every pipeline is unique to its source.** A sibling pipeline
(Espoo units → Polygon) says nothing about this pipeline (Helsinki units → all
MultiPolygon). Points, LineStrings, MultiLineStrings, Polygons and MultiPolygons are
all legitimate outcomes. Never force the data into the shape an example happened to
use, and **never downgrade a Multi\* geometry to its single-part variant** (no
"largest part", no explode). Promote the other way instead: if any row is a
MultiPolygon the whole column becomes MultiPolygon.

### 4a – inspect the latest raw extract

Look at the actual geometries. Project code lives in `/app` inside the `etl-cli`
container; `lib` must be on the path and stdin must be attached (`-i`):

```bash
docker exec -i -w /app -e PYTHONPATH=/app:/app/lib etl-cli python - <<'EOF' 2>&1 | grep -v -i warn
from common.storage import EtlStorage
s = EtlStorage()
runs = sorted(s.list_blob(container="<EXTRACT_BUCKET>", folder="<BUCKET_ROOT>", dirs_in_path=True), reverse=True)
files = s.list_blob(container="<EXTRACT_BUCKET>", folder=runs[0])
print(files)
gdf = s.download_dataframe(container="<EXTRACT_BUCKET>", path=files[0], get_metadata=False)
print("crs:", gdf.crs, "| rows:", len(gdf))
print("geom types:", gdf.geom_type.value_counts().to_dict())
print("invalid:", int((~gdf.is_valid).sum()), "| null:", int(gdf.geometry.isna().sum()))
EOF
```

Record `crs` (this overrides the Step 2 guess if they differ) and the geometry-type
distribution. Confirm the listed file really belongs to this pipeline (compare with
the `path=` in extractor.py) — a shared `BUCKET_ROOT` can surface another pipeline's
file. If no extract exists yet, fall back to the extract schema / extractor hints,
pick the most permissive shape (Multi\*), and flag it prominently.

### 4b – map the distribution to a shape

| Observed geometry types | Shape | WKT columns added | Cleaning in the task |
|-------------------------|-------|-------------------|----------------------|
| only `Point` | point | `coords_wgs84`, `coords_etrs89` | none |
| `MultiPoint` present | multipoint | `multipoint_wgs84`, `multipoint_etrs89` | none |
| only `LineString` | line | `line_wgs84`, `line_etrs89` | none |
| `MultiLineString` present | multiline | `multiline_wgs84`, `multiline_etrs89` | none |
| only `Polygon` (stray other types ≤ ~0.1 % allowed) | polygon | `polygon_wgs84`, `polygon_etrs89`, `polygon_area` | `fix_invalid_polygons(gdf, target_geom_type="Polygon")`, then `gdf.loc[~(gdf.geometry.geom_type == "Polygon"), "geometry"] = None` |
| any `MultiPolygon` (all, or mixed with `Polygon`) | multipolygon | `multipolygon_wgs84`, `multipolygon_etrs89`, `polygon_area` | `fix_invalid_polygons(gdf, target_geom_type="MultiPolygon")`, then `gdf = gdf.set_geometry(ensure_multipolygon(gdf.geometry))` |
| mixed dimensions (points and polygons in one layer) | stop and ask | | |

Helpers come from `common.validations.geom` (`fix_invalid_polygons`,
`ensure_multipolygon`). For area shapes also add `polygon_area` = `.area` of the
local-SRID geometry. Add centroid columns `coords_wgs84` / `coords_etrs89` (centroid
of the local-SRID geometry) **only** if a sibling `*TransformedSchema` of the same
entity already has them, so the entity stays queryable the same way across cities.

**WKT rounding precision depends on the CRS, always:**

| Column suffix | CRS | `to_wkt(rounding_precision=...)` | Why |
|---------------|-----|----------------------------------|-----|
| `*_wgs84` | EPSG:4326, degrees | **12** | one degree is ~111 km; 10 decimals is only ~0.01 mm at the equator but precision loss compounds on reprojection, so keep 12 |
| `*_etrs89` | metric local SRID | **10** | metres; 10 decimals is far below survey accuracy |

Never use 10 for a `*_wgs84` column and never use 12 for a `*_etrs89` column,
regardless of what an older example pipeline does. Reproject explicitly for both
outputs: `<shape>_wgs84 = gdf.geometry.to_crs(4326)`,
`<shape>_etrs89 = gdf.geometry.to_crs(<local srid>)`. Never assume the source CRS;
`to_crs` to the CRS the data is already in is harmless.

State the chosen shape and the observed distribution in the report.

## Step 5 – add the TransformedSchema if missing

If the schema module has no `*TransformedSchema`, append one **at the end of the
schema module** with the Edit tool. Add
`from common.validations.geom import is_geom_type_wkt, is_valid_wkt` to the imports
(only the names used). One `pa.Column` per WKT column from Step 4b; the
`geom_type` check must match the chosen shape exactly (`"Point"`, `"LineString"`,
`"MultiLineString"`, `"Polygon"`, `"MultiPolygon"`, ...). Example for the
multipolygon shape:

```python
<Name>TransformedSchema = (
    <Name>ExtractSchema.rename_columns(COLUMN_TRANSLATIONS)
    .remove_columns(["geometry"])
    .add_columns(
        {
            "multipolygon_wgs84": pa.Column(
                str,
                checks=[is_valid_wkt(), is_geom_type_wkt(geom_type="MultiPolygon")],
                nullable=True,
            ),
            "multipolygon_etrs89": pa.Column(
                str,
                checks=[is_valid_wkt(), is_geom_type_wkt(geom_type="MultiPolygon")],
                nullable=True,
            ),
            "polygon_area": pa.Column(float, nullable=True),
        }
    )
)
```

Omit `.rename_columns` when there is no mapping. Omit `polygon_area` for point and
line shapes. Use `nullable=False` only when the extract schema's `geometry` column is
`nullable=False`. Never edit the extract schema or the mapping.

If a `*TransformedSchema` already exists, use it as is and do not touch the schema
module; if its derived columns disagree with Step 4, follow the existing schema and
mention the mismatch in the report.

## Step 6 – write transformer.py

Use the Write tool now. Do not ask for permission first.

### Single-file template (shown for the multipolygon shape)

```python
from typing import cast

import geopandas as gpd
from common.flows.logged import logged_flow
from common.tasks.storage import (
    get_latest_bucket_folder,
    import_dataframe_from_storage,
    list_blob_folder,
    load_dataframe_to_storage,
)
from common.validations.geom import ensure_multipolygon, fix_invalid_polygons
from prefect import get_run_logger, task

from .<schema module> import (
    BUCKET_ROOT,
    COLUMN_TRANSLATIONS,
    EXTRACT_BUCKET,
    TRANSFORM_BUCKET,
    <Name>ExtractSchema,
    <Name>TransformedSchema,
)


@task
def transform_<entity>(gdf: gpd.GeoDataFrame):
    gdf = gdf.rename(columns=COLUMN_TRANSLATIONS)
    gdf = fix_invalid_polygons(gdf, target_geom_type="MultiPolygon")
    gdf = gdf.set_geometry(ensure_multipolygon(gdf.geometry))
    multipolygon_wgs84 = gdf.geometry.to_crs(4326)
    multipolygon_etrs89 = gdf.geometry.to_crs(<local srid>)
    gdf["multipolygon_wgs84"] = multipolygon_wgs84.to_wkt(rounding_precision=12)  # type: ignore[shapely]
    gdf["multipolygon_etrs89"] = multipolygon_etrs89.to_wkt(rounding_precision=10)  # type: ignore[shapely]
    gdf["polygon_area"] = multipolygon_etrs89.area
    return gdf.drop(columns=["geometry"])


@logged_flow
async def transform():
    bucket_folder = get_latest_bucket_folder(
        container=EXTRACT_BUCKET, folder=BUCKET_ROOT
    )
    storage_path = list_blob_folder(EXTRACT_BUCKET, bucket_folder)[0]
    try:
        gdf = import_dataframe_from_storage.submit(  # type: ignore
            container=EXTRACT_BUCKET,
            path=storage_path,
            schema=<Name>ExtractSchema,
        )
        export_name = f"{storage_path.split('.')[0]}.parquet"  # replace <ext> -> parquet
        load_dataframe_to_storage(
            transform_<entity>(cast(gpd.GeoDataFrame, gdf)),
            container=TRANSFORM_BUCKET,
            path=export_name,
            schema=<Name>TransformedSchema,
        )
    except Exception as e:
        get_run_logger().error(f"Failed With exception {e}")
        raise
```

Adjustments per Step 4b shape:

- **polygon** → `fix_invalid_polygons(gdf, target_geom_type="Polygon")`, then
  `gdf.loc[~(gdf.geometry.geom_type == "Polygon"), "geometry"] = None` instead of the
  `set_geometry(ensure_multipolygon(...))` line; columns `polygon_wgs84`,
  `polygon_etrs89`, `polygon_area`; drop the `ensure_multipolygon` import.
- **point / multipoint / line / multiline** → no `fix_invalid_polygons`, no
  `ensure_multipolygon`, no `polygon_area`; only the two `<shape>_wgs84` /
  `<shape>_etrs89` columns.
- **centroid columns** (only when a sibling has them) → `coords_etrs89 =
  <shape>_etrs89.centroid` written with `rounding_precision=10`,
  `coords_wgs84 = coords_etrs89.to_crs(4326)` written with `rounding_precision=12`.
- **rounding precision** is fixed by the CRS (Step 4b): `*_wgs84` → 12,
  `*_etrs89` → 10. Check every `to_wkt` call before finishing.
- **no mapping** → drop the `rename` line and the `COLUMN_TRANSLATIONS` import.
- The `except` block must always end with `raise`. Never swallow the exception.

### Batch template (several extract files)

Keep the same imports plus `import pandas as pd`, `from common.utils import alist`,
`from prefect import flow`, `from prefect.futures import PrefectFuture`,
`from prefect.task_runners import TaskRunner, ThreadPoolTaskRunner`. The task takes a
storage path, imports and validates inside the task, and the flow fans out:

```python
@task(tags=["heavy_load"], cache_result_in_memory=False, persist_result=False)
def transform_batch(path: str) -> pd.DataFrame:
    gdf = cast(
        gpd.GeoDataFrame,
        import_dataframe_from_storage(
            container=EXTRACT_BUCKET, path=path, schema=<Name>ExtractSchema
        ),
    )
    ...same body as the single-file task...
    return pd.DataFrame(gdf).drop(columns=["geometry"])


@logged_flow(
    task_runner=cast(TaskRunner[PrefectFuture], ThreadPoolTaskRunner(max_workers=20)),  # type: ignore
    log_prints=True,
)
async def transform():
    bucket_folder = get_latest_bucket_folder(
        container=EXTRACT_BUCKET, folder=BUCKET_ROOT
    )
    extract_files = list_blob_folder(EXTRACT_BUCKET, bucket_folder)
    try:
        async for batch_file in alist(extract_files):
            transform_job = transform_batch.submit(batch_file)  # type: ignore
            export_name = f"{batch_file.split('.')[0]}.parquet"  # replace <ext> -> parquet
            load_dataframe_to_storage.submit(  # type: ignore
                df=transform_job,  # type: ignore
                container=TRANSFORM_BUCKET,
                path=export_name,
                schema=<Name>TransformedSchema,
            ).result()
    except Exception as e:
        get_run_logger().error(f"Failed With exception {e}")
        raise
```

### Things the transformer must NOT do

- No business derivations (ratios, parsed ids, date parsing, lookups). Silver is a
  1:1 copy of the source plus geometry columns. If a legacy pipeline derived extra
  fields, list them as a question in the report instead of adding them.
- No column filtering beyond dropping `geometry`. The `TransformedSchema` decides.
- No docstrings, no logging inside the task, no `if __name__ == "__main__"`.
- Never name the task after another entity (a copy-pasted `transform_municipalities`
  in a units pipeline is wrong).
- Never reshape geometries to match an example pipeline (Step 4). Examples show the
  file layout and flow wiring, not the geometry type.

## Step 7 – existing transformer.py

If `transformer.py` already exists: identical to what you would write → leave it and
say so. Differs only within the template (names, precision, ignore comments,
missing `raise`) → overwrite and list the differences. Contains logic outside the
template → do not overwrite; report the extra code and ask.

## Step 8 – verify the import and report

Run one cheap check (project code lives in `/app` inside the `etl-cli` container and
`lib` must be on the path):

```bash
docker exec -w /app -e PYTHONPATH=/app:/app/lib etl-cli python -c "import pipelines.<dotted.path>.transformer"
```

Do not run the flow itself. Then reply with:

- the written transformer.py path and whether the schema module was extended with a
  `*TransformedSchema`
- source CRS, local SRID, single-file vs batch, the observed geometry-type
  distribution and the shape chosen from it, and whether centroid columns were
  copied from a sibling
- the import-check result
- open questions, each with the default you applied (no extract to inspect, mixed
  geometry types, shared `BUCKET_ROOT`, legacy derivations left out, ...)
