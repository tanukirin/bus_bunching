from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pyarrow as pa
import pyarrow.parquet as pq

INTEGER_COLUMNS = {"seed", "rank", "n", "worker", "workers"}


def ensure_dir(path: str | Path) -> Path:
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    return p


def write_json(path: str | Path, payload: dict[str, Any]) -> None:
    with Path(path).open("w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2, allow_nan=True)
        f.write("\n")


def append_jsonl(path: str | Path, payload: dict[str, Any]) -> None:
    with Path(path).open("a", encoding="utf-8") as f:
        f.write(json.dumps(payload, ensure_ascii=False, allow_nan=True) + "\n")


def write_parquet(path: str | Path, rows: list[dict[str, Any]]) -> None:
    table = pa.Table.from_pylist(rows) if rows else pa.table({})
    pq.write_table(table, path)


class ParquetRowWriter:
    def __init__(self, path: str | Path):
        self.path = Path(path)
        self.writer: pq.ParquetWriter | None = None
        self.rows_written = 0

    def write_rows(self, rows: list[dict[str, Any]]) -> None:
        if not rows:
            return
        table = pa.Table.from_pylist([normalize_row_types(row) for row in rows])
        if self.writer is None:
            self.writer = pq.ParquetWriter(self.path, table.schema)
        else:
            table = table.cast(self.writer.schema)
        self.writer.write_table(table)
        self.rows_written += table.num_rows

    def close(self) -> None:
        if self.writer is not None:
            self.writer.close()
            self.writer = None
        elif not self.path.exists():
            pq.write_table(pa.table({}), self.path)

    def __enter__(self) -> "ParquetRowWriter":
        return self

    def __exit__(self, exc_type: object, exc: object, tb: object) -> None:
        self.close()


def normalize_row_types(row: dict[str, Any]) -> dict[str, Any]:
    normalized: dict[str, Any] = {}
    for key, value in row.items():
        if isinstance(value, bool):
            normalized[key] = value
        elif isinstance(value, int) and key not in INTEGER_COLUMNS:
            normalized[key] = float(value)
        else:
            normalized[key] = value
    return normalized


def read_parquet(path: str | Path) -> pa.Table:
    return pq.read_table(path)
