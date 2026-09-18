---
name: schema-column-translations
description: Add or normalize a strictly typed `dict[str, str]` column-translation mapping in a pipeline's pandera schemas.py, translating source-language extract column names into English snake_case. Use when the user asks to translate, rename, or standardize the columns of an ETL extract schema, or invokes /schema-column-translations <path/to/schemas.py>.
---

# schema-column-translations

Every pipeline's extract schema carries column names exactly as the source delivers
them (Finnish, Danish, WFS/XML field codes, ...). The transformed schema must expose
English snake_case names instead. The bridge between the two is a single
module-level dictionary in `schemas.py`, strictly typed as `dict[str, str]`, that maps
every surviving source column name to its English snake_case target name.

This skill writes or normalizes that one dictionary. It does not touch the schema
class definitions, `transform.py`, `const.py`, `loader.py`, or anything else.

Once the schemas.py path is known and the extract schema is unambiguous, this task
is fully mechanical: write the dict directly into schemas.py with the Edit tool.
Do not ask the user for confirmation before editing — invoking this skill is the
user's authorization to make the change. Only stop and ask when a step below
explicitly says to stop and ask (e.g. an ambiguous extract schema).

Argument: `$ARGUMENTS` is the path to the schemas.py file. If missing, ask for it.

You may open:

- the schemas.py given as argument
- a sibling `const.py` in the same pipeline directory, only to check for a
  pre-existing column-mapping dict to reuse as ground truth
- other `schemas.py` / `const.py` files repo-wide, only via grep, to look up how a
  given source column name has already been translated elsewhere (for consistency)

Do **not** read the extractor, transform.py, loader, flow, dbt models, or migrations.
The one exception: before renaming an existing mapping variable (Step 3), grep the
repo for `import` statements referencing its current name, since that tells you
whether it is safe to rename.

## Step 1 – find the extract schema and its column list

Identify the schema representing raw, unrenamed source data — the variable/class
whose name contains `Extract` (e.g. `FooExtractedSchema`, `class ExtractSchema`).
If none is obviously the extract schema, stop and ask which one.

List its column names in declaration order:

- `pa.DataFrameSchema(columns={...})` → the dict keys, in order.
- `pa.DataFrameModel` class → the annotated field names, in order (skip `Config`).

## Step 2 – find or create the mapping dict

Search schemas.py for a dict already passed into `.rename_columns(...)` on the
extract schema. Also check the sibling `const.py` for a `dict[str, str]`-shaped
constant (commonly named `cols_<pipeline>`) used the same way. Handle whichever
applies:

- **Dict already lives in schemas.py.** This is the one to normalize. Keep every
  existing key/value pair verbatim — never re-translate an entry that is already
  there, even if you would have chosen differently. Only add entries for extract
  columns that are missing from it.
- **Dict lives only in const.py.** Copy its contents into schemas.py as the starting
  point (verbatim, same reasoning as above), and note in the report that a
  duplicate still exists in const.py and should eventually import from schemas.py
  instead — do not edit const.py yourself.
- **No dict exists anywhere.** Start from an empty mapping; every entry will be new
  (Step 4).

Figure out which extract columns must appear as keys: every column in the extract
schema, **except**:

- ones you have concrete evidence are dropped before the transformed schema is
  produced (e.g. explicitly passed to a later `.remove_columns([...])` in the same
  file), and
- geometry columns — a column named `geometry`, or typed `GeoSeries` /
  `pa.Column("geometry")`. Geometry is handled by the pipeline's own geo step
  (coordinate/polygon derivation), not by column translation, so it can be skipped
  entirely rather than given an identity entry.

When in doubt about anything else, include the column — an identity mapping
(`"gml_id": "gml_id"`) is always safe; a silently missing column is not.

## Step 3 – name the variable

If a mapping dict already exists (in schemas.py or const.py), keep its existing name.
Before renaming anything, grep the whole repo for `import` of that name — if any file
outside schemas.py imports it, you must keep the name unchanged. Only when creating a
brand-new dict, name it `COLUMN_TRANSLATIONS`.

## Step 4 – translate the missing entries

For every extract column that doesn't yet have an entry:

1. **Reuse established vocabulary first.** Grep the repo for the same key (case
   insensitive; also try it with a common source prefix stripped, e.g. `c_`, `i_`,
   `id_`) inside any `dict[str, str]`-shaped literal in `schemas.py`/`const.py` files.
   If the same source field is already translated elsewhere, reuse that exact target
   name — column naming must stay consistent across pipelines that share a source
   registry (e.g. the Finnish building registry fields reused by every city buildings
   pipeline).
2. **Otherwise translate the meaning, not the letters.** Translate the source-language
   term into the accurate English domain term, then convert to snake_case. Do not
   transliterate (`postinumero` → `postal_code`, never `postinumero` verbatim).
3. **Identifiers that are already English/technical stay identity.** Things like
   `gml_id`, `fid`, `objectid`, `id`, `uuid` map to themselves unless the file gives
   concrete evidence they're renamed downstream. Geometry columns are the one
   exception: per Step 2, omit them from the dict entirely rather than mapping them
   to themselves.
4. **snake_case rules:** lowercase; single underscores between words; no leading,
   trailing, or doubled underscores; trailing digits attach directly to the word
   (`OSOITENUMERO2` → `address_no2`), they are not spelled out.
5. **If a term is a cryptic abbreviation or acronym you cannot confidently resolve**
   even using the schema's checks/comments for context, do not silently guess. Still
   provide your best-effort snake_case translation so the pipeline keeps working, but
   list it under "needs review" in the report.

Never alter an entry carried over from Step 2.

## Step 5 – write the dict

Use the Edit tool to write this directly into schemas.py now. Do not ask for
permission first and do not stop before Step 6 to check in with the user.

```python
COLUMN_TRANSLATIONS: dict[str, str] = {
    "sourceColumnA": "target_column_a",
    "sourceColumnB": "target_column_b",
}
```

Rules:

- Order entries exactly as the extract schema declares its columns. Never alphabetize
  or regroup.
- Annotate as `dict[str, str]` using the builtin generic — never
  `from typing import Dict` / `Dict[str, str]`. The only exception: if the dict
  already carries `Final[dict[str, str]]` in this specific file, preserve `Final`;
  do not introduce `Final` into files that don't already use it for this purpose.
- Placement: after the module docstring, imports, and any bucket/path constants
  (`EXTRACT_BUCKET`, `TRANSFORM_BUCKET`, `BUCKET_ROOT`, ...), and before the first
  schema definition. In a `pa.DataFrameModel`-style file with no such constants,
  place it after imports and before `class ExtractSchema`.
- If the file already chains `.rename_columns(COLUMN_TRANSLATIONS)` (or whatever the
  existing name is), leave that call untouched — only the dict's contents/typing
  change. If no such chain exists yet (the file uses separate `ExtractSchema` /
  `Transform*Schema` classes instead), do not fabricate one; the dict is written for
  the caller to wire in, and you say so in the report.
- No comments, docstrings, or grouping headers inside the dict beyond what Step 2
  already carried over.

## Step 6 – report

The file is already written from Step 5. Do not execute anything (no Python, no
tests, no formatter) — "do not run" refers to scripts, not the edit itself. Reply
with:

- the schemas.py path and the variable name (kept or newly created)
- how many columns are mapped, and how many were newly added vs. carried over
- any entries reused from elsewhere in the repo (source file + column)
- any "needs review" entries with their best-guess translation
- whether a stale duplicate remains in a sibling const.py
- whether the mapping is already wired via `.rename_columns(...)` or still needs to
  be wired in by hand
