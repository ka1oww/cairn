"""Drive Cairn's migrations on a throwaway Postgres the way PostgREST does.

The point of this file is fidelity. Row-level security is a *runtime* property:
a policy that reads well can still abort every query the moment the planner runs
it, which is exactly what happened to the first version of this schema. Reading
the SQL cannot find that. Running it as a real, non-privileged user can.

So every statement a "user" issues here goes through the same three steps
PostgREST takes for an authenticated request:

    begin;
    set local role authenticated;                    -- NOT bypassrls
    select set_config('request.jwt.claims', '{"sub": "<uid>"}', true);
    <the statement>

`authenticated` is not the owner of these tables and does not have BYPASSRLS, so
policies are genuinely enforced, and `auth.uid()` resolves out of the claims GUC
exactly as Supabase's own definition does.

Connection comes from CAIRN_PG_{HOST,PORT,USER,PASSWORD,DB}; see README.md.
"""

import glob
import os

import pg8000.native as pg

HERE = os.path.dirname(os.path.abspath(__file__))
MIGRATIONS = os.path.join(os.path.dirname(HERE), "migrations")

HOST = os.environ.get("CAIRN_PG_HOST", "127.0.0.1")
PORT = int(os.environ.get("CAIRN_PG_PORT", "5432"))
USER = os.environ.get("CAIRN_PG_USER", "postgres")
PASSWORD = os.environ.get("CAIRN_PG_PASSWORD") or None
ADMIN_DB = os.environ.get("CAIRN_PG_DB", "postgres")


def connect(database=ADMIN_DB, user=USER, password=PASSWORD):
    return pg.Connection(user, password=password, host=HOST, port=PORT, database=database)


def ensure_api_roles(conn):
    """The three roles Supabase gives every project. Cluster-wide, so idempotent."""
    for role, extra in (("anon", ""), ("authenticated", ""), ("service_role", "bypassrls")):
        exists = conn.run("select 1 from pg_roles where rolname = :r", r=role)
        if not exists:
            conn.run(f"create role {role} nologin {extra}")


def recreate_db(name):
    """A fresh database with Supabase's environment emulated, ready for migrations."""
    adm = connect()
    ensure_api_roles(adm)
    adm.run(f"drop database if exists {name} with (force)")
    adm.run(f"create database {name}")
    adm.close()

    db = connect(name)
    db.run(open(os.path.join(HERE, "supabase_env.sql")).read())
    return db


def apply_migrations(conn, mig_dir=MIGRATIONS, label="apply"):
    """Apply every migration in filename order, one transaction each, as db push does."""
    files = sorted(glob.glob(os.path.join(mig_dir, "*.sql")))
    assert files, f"no migrations found in {mig_dir}"
    all_ok = True
    for path in files:
        try:
            conn.run("begin")
            conn.run(open(path).read())
            conn.run("commit")
            print(f"  {label}: {os.path.basename(path)}: OK")
        except Exception as exc:  # noqa: BLE001 -- we want the message, not the type
            conn.run("rollback")
            all_ok = False
            print(f"  {label}: {os.path.basename(path)}: FAIL -- {str(exc).splitlines()[0]}")
    return all_ok


class As:
    """One authenticated user, issuing statements the way PostgREST does."""

    def __init__(self, db, uid):
        self.db = db
        self.uid = uid

    def run(self, sql, **params):
        self.db.run("begin")
        try:
            self.db.run("set local role authenticated")
            self.db.run(
                "select set_config('request.jwt.claims', :claims, true)",
                claims='{"sub":"%s","role":"authenticated"}' % self.uid,
            )
            rows = self.db.run(sql, **params)
            self.db.run("commit")
            return rows
        except Exception:
            try:
                self.db.run("rollback")
            except Exception:  # noqa: BLE001
                pass
            raise

    def try_run(self, sql, **params):
        """('ok', rows) or ('err', message). Note that a refusal is usually NOT an
        error: RLS filters SELECT/UPDATE/DELETE to zero rows rather than raising,
        so a check that only looks for an exception can pass for the wrong reason."""
        try:
            return ("ok", self.run(sql, **params))
        except Exception as exc:  # noqa: BLE001
            return ("err", str(exc).splitlines()[0])


def make_user(conn, name, email=None):
    """Insert an auth.users row; handle_new_user should mirror it into profiles."""
    rows = conn.run(
        "insert into auth.users (email, raw_user_meta_data) "
        "values (:email, jsonb_build_object('full_name', :name::text)) returning id",
        email=email or f"{name.lower()}@example.test",
        name=name,
    )
    return str(rows[0][0])


_passed: list[str] = []
_failed: list[str] = []


def check(condition, message, detail=""):
    (_passed if condition else _failed).append(message)
    prefix = "  [PASS] " if condition else "  [FAIL] "
    print(prefix + message + (f"   {detail}" if detail else ""))
    return bool(condition)


def summary():
    print(f"\n  ---- {len(_passed)} passed, {len(_failed)} failed ----")
    for message in _failed:
        print("   FAILED: " + message)
    return not _failed
