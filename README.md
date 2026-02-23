# postgres-db

Custom Fly Postgres image for AI knowledge graph workloads. Based on [fly-apps/postgres-flex](https://github.com/fly-apps/postgres-flex) (pinned to commit `19b3e1311aca`) with additional extensions.

## Why a custom image?

The stock `flyio/postgres-flex` images don't include pgvector, Apache AGE, or pg_textsearch. This Dockerfile follows the same structure as the upstream Fly image, adding only the extensions we need.

## Extensions

| Extension | Purpose | Source |
|---|---|---|
| **TimescaleDB** | Time-series data | apt (upstream) |
| **PostGIS** | Geospatial | apt (upstream) |
| **pgvector** | Embedding similarity search | apt (pgdg) |
| **Apache AGE** | Graph database / Cypher queries | apt (pgdg) |
| **pg_textsearch** 0.5.1 | BM25 full-text search | Prebuilt binaries |
| **pg_trgm** | Fuzzy text matching | postgresql-contrib |
| **ltree** | Hierarchical label trees | postgresql-contrib |

## Enabling extensions

Connect to Postgres and run:

```sql
CREATE EXTENSION vector;
CREATE EXTENSION age;
CREATE EXTENSION pg_textsearch;
CREATE EXTENSION pg_trgm;
CREATE EXTENSION ltree;
```
