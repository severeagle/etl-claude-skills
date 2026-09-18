---
name: schema-to-loader
description: Generate the pipeline loader.py next to a pipeline's pandera schemas.py, wiring the TransformedSchema to its existing SQLAlchemy model via generic_load. Use after /schema-to-model, when the user asks to create, add, or generate a loader for an ETL pipeline, or invokes /schema-to-loader <path/to/schemas.py>.
---

# schema-to-loader

Write `pipelines/etl/<domain>/<entity>/<country>/loader.py` for a pipeline whose
`schemas.py` already has a matching SQLAlchemy model in `db/src/models/etl/`.

Argument: `$ARGUMENTS` is the path to the schemas.py file. If missing, ask for it.

You may open only these files:

- the schemas.py given as argument
- `db/src/models/etl/__init__.py`
- model files under `db/src/models/etl/` (to locate the model class)
- the target `loader.py` if it already exists

Do **not** read the extractor, transformer, flow, dbt models, migrations, or any
other pipeline's loader.

## The output is fixed. There is no room for creativity.

The generated file is **exactly** this, with only the four placeholders substituted:

```python
from common.flows.loaders import generic_load
from models.etl import <ModelClass>

from .schemas import BUCKET_ROOT, TRANSFORM_BUCKET, <TransformedSchema>


@generic_load(
    bucket_root=BUCKET_ROOT,
    container=TRANSFORM_BUCKET,
    schema=<TransformedSchema>,
    skip_existing=True,
)
def load():
    return <ModelClass>
```

Absolutely no additional code. This means:

- no docstrings, no comments, no type hints, no logging, no `__all__`
- no extra imports, no extra constants, no helper functions
- no extra keyword arguments to `generic_load`, and none removed. Exactly
  `bucket_root`, `container`, `schema`, `skip_existing=True`, in that order
- no body in `load()` other than the single `return <ModelClass>`
- no renaming of `load`, `BUCKET_ROOT`, or `TRANSFORM_BUCKET`
- no reformatting beyond the one permitted wrap below

The **only** permitted deviation: if the `from .schemas import ...` line exceeds
88 characters, wrap it in Black style:

```python
from .schemas import (
    BUCKET_ROOT,
    TRANSFORM_BUCKET,
    <TransformedSchema>,
)
```

If you feel the pipeline needs anything more than this, you are wrong for the
purposes of this skill. Write the fixed file and mention the concern in the report.

## Step 1 – read the schema file

Open the schemas.py and confirm all three of these exist. If any is missing, **stop
and report** which one; do not invent it and do not write loader.py.

| Placeholder           | Rule                                                                 |
|-----------------------|----------------------------------------------------------------------|
| `BUCKET_ROOT`         | module-level constant with exactly this name                         |
| `TRANSFORM_BUCKET`    | module-level constant with exactly this name                         |
| `<TransformedSchema>` | the `pa.DataFrameSchema` variable whose name ends in `TransformedSchema` |

If there are several `*TransformedSchema` variables, stop and ask which one.

Also note the schema's final column names (apply `rename_columns`, `remove_columns`,
`add_columns` in order). You will need them in Step 2.

## Step 2 – locate the SQLAlchemy model (fail if it does not exist)

The model **must already exist**. This skill never creates or edits a model. Work
through these lookups in order and take the first hit:

1. **Path-derived name.** From `pipelines/etl/<domain>/<entity>/<country>/schemas.py`
   build `PascalCase(entity) + PascalCase(country) + "ETL"` and look for
   `class <Name>(Base)` in `db/src/models/etl/<entity>.py`.
   Example: `building_polygons/denmark` → `BuildingPolygonsDenmarkETL` in
   `db/src/models/etl/building_polygons.py`.
2. **Table name.** Search `db/src/models/etl/*.py` for a class whose
   `__tablename__ == "<entity>_<country>"`. Naming drifts (e.g. `MunicipalityDenmarkETL`
   for `municipalities/denmark`), but the table name is stable.
3. **Column match.** If both fail, look for a class in `db/src/models/etl/` for the same
   country whose `mapped_column` attribute names equal the schema's final column set
   from Step 1. Accept only an exact set match. A single candidate is a hit; several
   candidates means stop and ask.

Then verify the class is imported in `db/src/models/etl/__init__.py` and listed in its
`__all__`. If the class is not found by any lookup, or is found but not registered in
`__init__.py`, **stop and report**:

> No SQLAlchemy model found for `<entity>_<country>`. Run
> `/schema-to-model <path>` first.

Do not write loader.py in that case. Do not create the model yourself.

## Step 3 – handle an existing loader.py

If `loader.py` already exists in the pipeline folder, read it and compare it with the
fixed output from Step 4:

- **Identical** → leave the file untouched and say so in the report.
- **Differs only within the template** (argument order, missing `skip_existing=True`,
  import wrapping, whitespace, a stale model or schema name) → overwrite it with the
  fixed output and list each difference in the report as maintenance applied.
- **Contains anything outside the template** (extra logic, extra arguments, extra
  imports, a different decorator) → do **not** overwrite. Report exactly what extra
  code is present and ask whether it should be dropped. Someone may have added it on
  purpose.

## Step 4 – write the file

Target path: the directory containing the schemas.py, file name `loader.py`.
Substitute the placeholders into the fixed template above. Nothing else.

## Step 5 – report

Do not run anything (no Python, no tests, no formatter). Reply with:

- the written (or unchanged) loader.py path
- the model class and which lookup found it (path name / table name / column match)
- the `TransformedSchema` used
- whether an existing loader.py was untouched, updated (and how), or left alone
  because it had extra code
