#!/usr/bin/env python3
"""
migrate-sgw-config.py

Reads an ACTUAL Sync Gateway 2.1 legacy config file and translates it into
the artifacts a Sync Gateway 4.1.x deployment needs:
  - a bootstrap config file (node-level: cluster connection only)
  - one Admin REST API PUT payload per database (dynamic db config)
  - one Admin REST API PUT payload per user (including GUEST, if present)

This performs a REAL transformation of whatever the input file actually
contains - it does not assume or hardcode values, unlike the earlier
sgw-4.1-ol8.sh script, which only worked because I already knew what
was in this specific lab's config.

Handles the one thing that makes this config not-quite-JSON: the `sync`
property's backtick-delimited multi-line JS block. That gets extracted
before parsing and re-inserted afterward as a plain string.

Applies these translation rules automatically, with a printed warning for
each one it actually triggers on your specific input:
  - shared_bucket_access / enable_shared_bucket_access -> forced true,
    with a loud warning if the source had it false or unset (XATTR
    migration concern - see Appendix B.5 of the runbook)
  - num_index_replicas -> index.num_replicas (renamed)
  - allow_conflicts, enable_star_channel -> dropped (unsupported in 4.x,
    would prevent the database starting if left in)
  - use_views -> flagged, not auto-fixed (needs a human decision)
  - facebook / google auth provider blocks -> flagged, NOT translated
    (needs migration to OIDC/Custom Auth, a client-visible change)

Usage:
  # Just translate and write files for review (default, safest):
  python3 migrate-sgw-config.py --input /path/to/old/sync_gateway.json \\
      --new-cb-host <new-cluster-host> \\
      --new-cb-user <rbac-user-on-new-cluster> \\
      --new-cb-password <rbac-password> \\
      --output-dir ./migrated

  # Control which interfaces the new node's APIs bind to (defaults shown):
  python3 migrate-sgw-config.py --input ... --new-cb-host ... \\
      --new-cb-user ... --new-cb-password ... \\
      --admin-interface 127.0.0.1:4985 \\
      --public-interface :4984

  # Also apply the database + user config directly to a running SGW 4.1.x:
  python3 migrate-sgw-config.py --input ... --new-cb-host ... \\
      --new-cb-user ... --new-cb-password ... --apply \\
      --sgw-admin-url http://localhost:4985

NOTE on --apply: it creates the database and users via the Admin REST API,
but it does NOT place bootstrap.json at wherever this Sync Gateway install
actually reads its config from, or restart the service - that path varies
by RPM/init-script (see the 2.1 lesson: don't trust the documented default
without checking). Copy bootstrap.json there yourself and restart.
"""
import argparse
import json
import os
import re
import sys
import urllib.request
import urllib.error


REMOVED_KEYS_4X = ["allow_conflicts", "enable_star_channel"]
LEGACY_SOCIAL_AUTH_KEYS = ["facebook", "google"]


def extract_sync_functions(raw_text):
    """
    The `sync` property may be a backtick-delimited multi-line JS block -
    a Sync Gateway config extension, not valid JSON. Pull each occurrence
    out, replace it with a JSON string placeholder so the rest of the file
    parses normally, and return a map to restore the real content after.
    """
    pattern = re.compile(r'"sync"\s*:\s*`(.*?)`', re.DOTALL)
    functions = {}
    counter = [0]

    def replacer(match):
        counter[0] += 1
        key = f"__SYNC_FUNCTION_PLACEHOLDER_{counter[0]}__"
        functions[key] = match.group(1)
        return f'"sync": "{key}"'

    cleaned = pattern.sub(replacer, raw_text)
    return cleaned, functions


def load_legacy_config(path):
    with open(path, "r") as f:
        raw = f.read()

    # A copy taken from a shell script's heredoc rather than the deployed file
    # still has shell syntax in it: escaped backticks and ${VAR} placeholders.
    template_marks = sorted(set(re.findall(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", raw)))
    if "\\`" in raw or template_marks:
        print(f"ERROR: {path} looks like a template copied from a script, not a deployed config:", file=sys.stderr)
        if "\\`" in raw:
            print("  - it contains \\` (an escaped backtick) around the sync function", file=sys.stderr)
        if template_marks:
            print(f"  - it contains unfilled placeholders: {', '.join(template_marks)}", file=sys.stderr)
        print("Use the real file from the old Sync Gateway server instead (in the lab:", file=sys.stderr)
        print("/opt/sync_gateway/etc/sync_gateway.json), where these are already filled in.", file=sys.stderr)
        sys.exit(1)

    cleaned, sync_functions = extract_sync_functions(raw)
    try:
        data = json.loads(cleaned)
    except json.JSONDecodeError as e:
        print(f"ERROR: could not parse {path} as JSON, even after extracting sync-function blocks: {e}", file=sys.stderr)
        print("This config may use a structure this script doesn't expect - inspect it manually.", file=sys.stderr)
        sys.exit(1)

    def restore(obj):
        if isinstance(obj, dict):
            return {k: restore(v) for k, v in obj.items()}
        if isinstance(obj, list):
            return [restore(v) for v in obj]
        if isinstance(obj, str) and obj in sync_functions:
            return sync_functions[obj]
        return obj

    return restore(data)


def translate_database(db_name, db_config, warnings):
    """Translate one legacy database block into a 4.1.x database config payload."""
    translated = {"bucket": db_config.get("bucket", db_name)}

    sba = db_config.get("shared_bucket_access", db_config.get("enable_shared_bucket_access"))
    if sba is not True:
        warnings.append(
            f"[{db_name}] shared_bucket_access was {sba!r} in the source, not true. "
            f"4.x REQUIRES this to be true, which means Sync Gateway's metadata was stored "
            f"INLINE in document bodies on the source (not XATTRs). This is a genuine data "
            f"migration concern, not just a flag flip - validate against real data before "
            f"trusting this in production (see Appendix B.5 of the runbook)."
        )
    translated["enable_shared_bucket_access"] = True

    if "num_index_replicas" in db_config:
        translated["index"] = {"num_replicas": db_config["num_index_replicas"]}
        warnings.append(f"[{db_name}] num_index_replicas -> index.num_replicas (property renamed).")
    elif "index" in db_config:
        translated["index"] = db_config["index"]

    for passthrough_key in ("import_docs", "revs_limit"):
        if passthrough_key in db_config:
            translated[passthrough_key] = db_config[passthrough_key]

    if "sync" in db_config:
        translated["sync"] = db_config["sync"]

    for key in REMOVED_KEYS_4X:
        if key in db_config:
            warnings.append(
                f"[{db_name}] '{key}' was present (value: {db_config[key]!r}) and has been DROPPED - "
                f"this setting doesn't exist in 4.x and would prevent the database from starting."
            )

    if db_config.get("use_views"):
        warnings.append(f"[{db_name}] 'use_views' was set - Views are deprecated/unsupported on modern storage. Confirm GSI indexes exist instead; this was NOT auto-fixed.")

    for key in LEGACY_SOCIAL_AUTH_KEYS:
        if key in db_config:
            warnings.append(
                f"[{db_name}] '{key}' auth provider block found - only usable in legacy config "
                f"mode, NOT supported under Persistent Config. Migrate to OIDC or Custom "
                f"Authentication; this block was NOT translated and needs manual attention "
                f"(it's a client-visible change, coordinate with app teams)."
            )

    return translated, db_config.get("users", {})


def http_put(url, payload_dict):
    payload = json.dumps(payload_dict).encode()
    req = urllib.request.Request(url, data=payload, method="PUT", headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except urllib.error.URLError as e:
        return None, str(e)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True, help="Path to the legacy 2.1 sync_gateway.json")
    ap.add_argument("--new-cb-host", required=True, help="New Couchbase Server cluster hostname/IP")
    ap.add_argument("--new-cb-user", default=None, help="RBAC username for the NEW cluster (do not reuse the old one blindly)")
    ap.add_argument("--new-cb-password", default=None, help="RBAC password for the NEW cluster")
    ap.add_argument("--output-dir", default="./migrated", help="Where to write the translated config files")
    ap.add_argument("--admin-interface", default="127.0.0.1:4985", help="Bind address:port for the Admin API. Default is loopback-only (safe default - not reachable off-box). Set to 0.0.0.0:4985 to allow remote admin access, and make sure your security group scopes that port to trusted IPs only if you do.")
    ap.add_argument("--public-interface", default=":4984", help="Bind address:port for the Public API (what mobile/web clients connect to). Default ':4984' means all interfaces, matching Sync Gateway's own default - override only if you need to restrict it to a specific NIC/IP.")
    ap.add_argument("--apply", action="store_true", help="Also call a running SGW 4.1.x Admin REST API to create the database(s) and users")
    ap.add_argument("--sgw-admin-url", default="http://localhost:4985", help="SGW 4.1.x Admin API base URL, used only with --apply")
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    legacy = load_legacy_config(args.input)
    warnings = []

    databases = legacy.get("databases", {})
    if not databases:
        print("ERROR: no 'databases' block found in the input file - is this actually a Sync Gateway config?", file=sys.stderr)
        sys.exit(1)

    all_users = {}
    for db_name, db_config in databases.items():
        translated, users = translate_database(db_name, db_config, warnings)

        db_out_path = os.path.join(args.output_dir, f"db-config-{db_name}.json")
        with open(db_out_path, "w") as f:
            json.dump(translated, f, indent=2)
        print(f"Wrote {db_out_path}")

        if users:
            users_out_path = os.path.join(args.output_dir, f"users-{db_name}.json")
            with open(users_out_path, "w") as f:
                json.dump(users, f, indent=2)
            print(f"Wrote {users_out_path}")
            all_users[db_name] = users

    first_db = next(iter(databases.values()))
    if not args.new_cb_user or not args.new_cb_password:
        warnings.append(
            "No --new-cb-user/--new-cb-password given - bootstrap.json was filled in with the "
            "OLD config's credentials, which almost certainly do NOT exist on the new cluster. "
            "Edit the generated file before using it, or re-run with those flags set."
        )
    if not args.admin_interface.startswith("127.0.0.1") and not args.admin_interface.startswith("localhost"):
        warnings.append(
            f"admin_interface is set to '{args.admin_interface}', not loopback-only. This exposes "
            f"the Admin API (full database/user management, no read-only mode) beyond this machine. "
            f"Make sure the security group scopes this port to trusted IPs only, not 0.0.0.0/0."
        )
    bootstrap = {
        "bootstrap": {
            "server": f"couchbase://{args.new_cb_host}",
            "username": args.new_cb_user or first_db.get("username", "CHANGE_ME"),
            "password": args.new_cb_password or first_db.get("password", "CHANGE_ME"),
            "use_tls_server": False,
        },
        "logging": legacy.get("logging", {
            "console": {"log_level": "info", "log_keys": ["HTTP", "CRUD", "Cache", "Changes"]}
        }),
        "api": {
            "admin_interface": args.admin_interface,
            "public_interface": args.public_interface,
        },
    }
    bootstrap_path = os.path.join(args.output_dir, "bootstrap.json")
    with open(bootstrap_path, "w") as f:
        json.dump(bootstrap, f, indent=2)
    print(f"Wrote {bootstrap_path}")

    print()
    print("=== Migration warnings - review each before trusting the output ===")
    if warnings:
        for w in warnings:
            print(f"  - {w}")
    else:
        print("  (none - though absence of warnings isn't the same as a verified-correct result)")

    if args.apply:
        print()
        print(f"=== Applying database + user config to {args.sgw_admin_url} ===")
        for db_name in databases:
            with open(os.path.join(args.output_dir, f"db-config-{db_name}.json")) as f:
                payload = json.load(f)
            status, body = http_put(f"{args.sgw_admin_url}/{db_name}/", payload)
            print(f"  Database '{db_name}': HTTP {status}" + (f" - {body}" if status not in (200, 201) else ""))

        for db_name, users in all_users.items():
            for user, user_conf in users.items():
                status, body = http_put(f"{args.sgw_admin_url}/{db_name}/_user/{user}", user_conf)
                print(f"  User '{user}' in '{db_name}': HTTP {status}" + (f" - {body}" if status not in (200, 201) else ""))

        print()
        print("NOTE: this did NOT place bootstrap.json at wherever this specific Sync Gateway")
        print("install actually reads its config from, and did NOT restart the service - that")
        print("path varies by RPM/init-script. Copy it there and restart manually. See the 2.1")
        print("lesson before assuming the documented default path is correct for this install.")

    print()
    print(f"Done. Review the files in {args.output_dir}/ before relying on them.")


if __name__ == "__main__":
    main()
