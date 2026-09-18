---
name: schema-to-model
description: Generate a SQLAlchemy ORM model in db/src/models/etl/ from a pipeline's pandera schemas.py. Use when the user asks to create, add, or generate a SQLAlchemy/Alembic model for an ETL pipeline, or invokes /schema-to-model <path/to/schemas.py>.
---

# schema-to-model

Turn `pipelines/etl/<domain>/<entity>/<country>/schemas.py` into a SQLAlchemy model
class in `db/src/models/etl/` and register it in the package `__init__.py`.

The schema file is the single source of truth. Do **not** read the pipeline's
extractor, transformer, loader, dbt models, or migrations. The only other files you
may open are the target model file (if it already exists) and
`db/src/models/etl/__init__.py`.

Once the schema and column mapping are resolved, this task is fully mechanical:
write the model file and update `__init__.py` directly with the Edit/Write tools.
Do not ask the user for confirmation before writing — invoking this skill is the
user's authorization to make the change. Only stop and ask when a step below
explicitly says to stop and ask (e.g. ambiguous schema, ambiguous SRID).

Always produce a complete model class, even when something is unresolved (an
unclear dtype, an ambiguous SRID pick a best guess and flag it, an unclear primary
key, etc.) — never block Step 5 waiting for an answer. Every model must have a
primary key: if no column clearly qualifies as a natural key, add a surrogate
auto-incremented `id` column instead of leaving the model without one (see Step 4).
Note unresolved points in the Step 7 report as clarifying questions and revise the
file after the user answers, instead of withholding the first draft.

Argument: `$ARGUMENTS` is the path to the schemas.py file. If missing, ask for it.

## Step 1 – pick the schema

Read the schemas.py. Use the schema whose variable name ends in `TransformedSchema`;
that is the shape that lands in the database. If there is exactly one
`pa.DataFrameSchema`, use that. If there are several and none is `*TransformedSchema`,
stop and ask which one.

## Step 2 – resolve the final column set

Pandera schemas are often built by chaining methods on a base schema. Apply them in
order to obtain the final column list:

- `.rename_columns(MAPPING)` – rename keys via the referenced dict.
- `.remove_columns([...])` – drop those columns.
- `.add_columns({...})` – add those columns.
- `.update_columns({...})` – override attributes of existing columns.

Column order in the model = order of the resulting dict.

## Step 3 – derive names from the path (path always wins)

From `pipelines/etl/<domain>/<entity>/<country>/schemas.py`:

| Item            | Rule                                    | Example                              |
|-----------------|-----------------------------------------|--------------------------------------|
| Class name      | `PascalCase(entity) + PascalCase(country) + "ETL"` | `BuildingPolygonsDenmarkETL` |
| `__tablename__` | `"<entity>_<country>"`                  | `"building_polygons_denmark"`        |
| Target file     | `db/src/models/etl/<entity>.py`         | `db/src/models/etl/building_polygons.py` |

If the target file already exists, **append** the new class to it and reuse its
imports. Do not create a second file and do not rename existing classes.

## Step 4 – map each column

### Nullability

`Mapped[Optional[X]]` + `nullable=True` when the pandera column has `nullable=True`
**or** `required=False`. Otherwise `Mapped[X]` + `nullable=False`.

### Scalar types

| pandera dtype                    | Python type | `mapped_column` type          |
|----------------------------------|-------------|-------------------------------|
| `str`, `"str"`, `"string"`       | `str`       | `sa.String`                   |
| `"Int64"`, `int`, `"int64"`      | `int`       | `sa.BigInteger`               |
| `float`, `"float64"`, `"Float64"`| `float`     | `sa.Float`                    |
| `bool`, `"boolean"`              | `bool`      | `sa.Boolean`                  |
| `"datetime64[ns, UTC]"` or any `datetime64` | `datetime` | `sa.DateTime(timezone=True)` |
| `date`                           | `date`      | `sa.Date`                     |
| no dtype given (`pa.Column(nullable=True)`) | infer from the column name and description; if unclear, use `str` / `sa.String` and add a `# TODO: confirm dtype` comment |

Always pass the type explicitly as the first positional argument of
`mapped_column`, even where SQLAlchemy could infer it.

### Geometry columns

The transformed schema stores geometries as WKT strings. Detect them by name:

| Name pattern     | Geometry type | `spatial_index` |
|------------------|---------------|-----------------|
| `coords_*`       | `"POINT"`     | `False`         |
| `polygon_*`      | `"POLYGON"`   | `True`          |
| `multipolygon_*` | `"MULTIPOLYGON"` | `True`       |
| `line_*`         | `"LINESTRING"`| `False`         |

SRID from the suffix:

| Suffix    | SRID by country                                  |
|-----------|--------------------------------------------------|
| `_wgs84`  | `4326` for every country                         |
| `_etrs89` | `finland` → `3067`, `denmark` → `25832`, other → ask |

Python type: `Point`, `Polygon`, `MultiPolygon`, `LineString` from `shapely`.

```python
polygon_wgs84: Mapped[Polygon] = mapped_column(
    gsa.Geometry("POLYGON", srid=4326, spatial_index=True), nullable=False
)
```

### Primary key

Choose the column that has `unique=True` **and** is not nullable. If several qualify,
prefer the one whose name ends in `_id`. Mark it
`mapped_column(<type>, primary_key=True, unique=True)`.

If no column in the schema clearly qualifies as a unique, non-nullable key, do not
stop and do not leave the model without a primary key — add a surrogate
auto-incremented `id` column instead:

```python
id: Mapped[int] = mapped_column(sa.BigInteger, primary_key=True, autoincrement=True)
```

Place it first in the class, ahead of every other column. Note in the Step 7 report
that a surrogate key was added because no unique column could be determined from
the schema.

## Step 5 – write the class

Use the Edit/Write tool to write this directly into the target file now. Do not
ask for permission first and do not pause before Step 6.

Style rules (mandatory):

- `import sqlalchemy as sa` and refer to every type as `sa.X`. Never
  `from sqlalchemy import Integer, ...`.
- `import geoalchemy2 as gsa` only when there is a geometry column.
- `from sqlalchemy.orm import Mapped, mapped_column`. Only `mapped_column`; never `Column`.
- `from .base import Base` and inherit from `Base`.
- Do **not** add `__table_args__`, `created_at` or `updated_at`; `Base` already sets
  the `etl` schema and both timestamps.
- Import `Optional` from `typing` and `date`/`datetime` from `datetime` only if used.
- Group columns with a blank line between: primary key, identifiers, plain
  attributes, timestamps, geometry, derived measures. Keep the schema's order within
  a group.
- No docstrings or comments beyond `# TODO: confirm dtype` where required.

Template:

```python
from datetime import datetime
from typing import Optional

import geoalchemy2 as gsa
import sqlalchemy as sa
from shapely import Point, Polygon
from sqlalchemy.orm import Mapped, mapped_column

from .base import Base


class PlotsDenmarkETL(Base):

    __tablename__ = "plots_denmark"

    plot_id: Mapped[str] = mapped_column(sa.String, primary_key=True, unique=True)

    gml_id: Mapped[str] = mapped_column(sa.String, nullable=False)
    property_id: Mapped[int] = mapped_column(sa.BigInteger, nullable=False)

    cadastral_number: Mapped[Optional[str]] = mapped_column(sa.String, nullable=True)
    registered_area_m2: Mapped[Optional[int]] = mapped_column(sa.BigInteger, nullable=True)
    is_common_lot: Mapped[Optional[bool]] = mapped_column(sa.Boolean, nullable=True)

    registered_from: Mapped[Optional[datetime]] = mapped_column(
        sa.DateTime(timezone=True), nullable=True
    )

    coords_wgs84: Mapped[Point] = mapped_column(
        gsa.Geometry("POINT", srid=4326, spatial_index=False), nullable=False
    )
    polygon_etrs89: Mapped[Polygon] = mapped_column(
        gsa.Geometry("POLYGON", srid=25832, spatial_index=True), nullable=False
    )

    polygon_area: Mapped[float] = mapped_column(sa.Float, nullable=False)
```

Worked mapping of a single column:

```python
# schema
"senesteSagLokalId": pa.Column("Int64", checks=pa.Check.gt(0), nullable=True)
# after rename_columns → "latest_case_id"
# model
latest_case_id: Mapped[Optional[int]] = mapped_column(sa.BigInteger, nullable=True)
```

## Step 6 – register in `__init__.py`

Use the Edit tool now, without asking for confirmation, on
`db/src/models/etl/__init__.py`:

1. Add `from .<entity> import <ClassName>` in alphabetical order by module. If the
   module is already imported, add the class to that import line (alphabetical inside
   the parentheses).
2. Add `"<ClassName>"` to `__all__` in alphabetical order.

If the class is already present in both places, leave the file untouched.

## Step 7 – report

The files are already written from Steps 5-6. Do not execute anything (no Python,
no tests, no formatter) — "do not run" refers to scripts, not the edits
themselves. Reply with the target file path, the class name, the primary key
column (or that a surrogate `id` was added because none could be determined), and
any `# TODO: confirm dtype` columns or SRID lookups as clarifying questions you
could not resolve — offer to revise the draft once the user answers. Do not create
an Alembic migration; that is a separate step.
