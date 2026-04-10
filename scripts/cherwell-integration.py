#!/usr/bin/env python3
"""
cherwell-integration.py - Cherwell / ServiceNow ITSM integration for ForgeOps CI/CD.

Checks CHERWELL_URL and SERVICENOW_URL environment variables to determine the
ITSM backend. If neither is set, prints a skip message and exits cleanly.

Subcommands:
  create-cr   Create a change request
  update-cr   Update a change request status

Uses only argparse and urllib (stdlib). No third-party dependencies.
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error


def get_itsm_backend():
    """Determine which ITSM backend is configured via environment variables."""
    cherwell_url = os.environ.get("CHERWELL_URL", "").strip()
    servicenow_url = os.environ.get("SERVICENOW_URL", "").strip()

    if cherwell_url:
        return "cherwell", cherwell_url
    if servicenow_url:
        return "servicenow", servicenow_url
    return None, None


def itsm_request(url, method, path, headers, data=None):
    """Make an HTTP request to the ITSM API."""
    full_url = url.rstrip("/") + path
    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(full_url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp_body = resp.read().decode("utf-8")
            if resp_body:
                return json.loads(resp_body)
            return None
    except urllib.error.HTTPError as exc:
        err_body = exc.read().decode("utf-8", errors="replace")
        print("[FAIL] ITSM API error: HTTP {} - {}".format(exc.code, err_body), file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as exc:
        print("[FAIL] ITSM connection error: {}".format(exc.reason), file=sys.stderr)
        sys.exit(1)


def cherwell_authenticate(url, client_id, client_secret):
    """Authenticate with Cherwell and return an access token."""
    token_path = "/CherwellAPI/token"
    form_data = urllib.parse.urlencode({
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
    }).encode("utf-8")

    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "Accept": "application/json",
    }
    full_url = url.rstrip("/") + token_path
    req = urllib.request.Request(full_url, data=form_data, headers=headers, method="POST")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp_body = resp.read().decode("utf-8")
            token_data = json.loads(resp_body)
            return token_data.get("access_token", "")
    except urllib.error.HTTPError as exc:
        err_body = exc.read().decode("utf-8", errors="replace")
        print("[FAIL] Cherwell authentication failed: HTTP {} - {}".format(exc.code, err_body),
              file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as exc:
        print("[FAIL] Cherwell connection error: {}".format(exc.reason), file=sys.stderr)
        sys.exit(1)


import urllib.parse


def servicenow_headers(url):
    """Build ServiceNow auth headers from SERVICENOW_USER and SERVICENOW_PASSWORD env vars."""
    import base64
    user = os.environ.get("SERVICENOW_USER", "")
    password = os.environ.get("SERVICENOW_PASSWORD", "")
    if not user or not password:
        print("[FAIL] SERVICENOW_USER and SERVICENOW_PASSWORD must be set", file=sys.stderr)
        sys.exit(1)
    encoded = base64.b64encode("{}:{}".format(user, password).encode("utf-8")).decode("utf-8")
    return {
        "Authorization": "Basic {}".format(encoded),
        "Content-Type": "application/json",
        "Accept": "application/json",
    }


def cmd_create_cr(args):
    """Create a change request."""
    backend, env_url = get_itsm_backend()

    # Use --url if provided, otherwise fall back to env var
    url = args.url if args.url else env_url
    if not url:
        print("ITSM not configured - skipping")
        sys.exit(0)

    if backend == "cherwell" or (args.client_id and args.client_secret):
        # Cherwell flow
        if not args.client_id or not args.client_secret:
            print("[FAIL] --client-id and --client-secret are required for Cherwell", file=sys.stderr)
            sys.exit(1)

        access_token = cherwell_authenticate(url, args.client_id, args.client_secret)
        headers = {
            "Authorization": "Bearer {}".format(access_token),
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

        payload = {
            "busObId": "ChangeRequest",
            "fields": [
                {"name": "ShortDescription", "value": "Deploy {} {} to {}".format(
                    args.app, args.version, args.environment)},
                {"name": "Description", "value": "Automated change request for {} version {} "
                    "deployment to {} environment".format(args.app, args.version, args.environment)},
                {"name": "Type", "value": "Normal"},
                {"name": "Priority", "value": "3 - Moderate"},
                {"name": "RequestedBy", "value": args.approver or "CI/CD Pipeline"},
            ],
        }

        result = itsm_request(url, "POST", "/CherwellAPI/api/V1/savebusinessobject", headers, payload)
        if result and result.get("busObRecId"):
            cr_id = result["busObRecId"]
            print("[PASS] Created Cherwell CR: {}".format(cr_id))
            print(cr_id)
        else:
            print("[FAIL] Unexpected response from Cherwell", file=sys.stderr)
            sys.exit(1)

    elif backend == "servicenow":
        # ServiceNow flow
        headers = servicenow_headers(url)
        payload = {
            "short_description": "Deploy {} {} to {}".format(
                args.app, args.version, args.environment),
            "description": "Automated change request for {} version {} "
                "deployment to {} environment".format(args.app, args.version, args.environment),
            "type": "normal",
            "priority": "3",
            "assignment_group": args.approver or "Change Management",
            "category": "Software",
        }

        result = itsm_request(url, "POST", "/api/now/table/change_request", headers, payload)
        if result and result.get("result", {}).get("sys_id"):
            cr_id = result["result"]["number"]
            print("[PASS] Created ServiceNow CR: {}".format(cr_id))
            print(cr_id)
        else:
            print("[FAIL] Unexpected response from ServiceNow", file=sys.stderr)
            sys.exit(1)
    else:
        print("[FAIL] Could not determine ITSM backend type", file=sys.stderr)
        sys.exit(1)


def cmd_update_cr(args):
    """Update a change request status."""
    backend, env_url = get_itsm_backend()

    url = args.url if args.url else env_url
    if not url:
        print("ITSM not configured - skipping")
        sys.exit(0)

    if not args.cr_id:
        print("[FAIL] --cr-id is required", file=sys.stderr)
        sys.exit(1)

    if backend == "cherwell" or (args.client_id and args.client_secret):
        # Cherwell flow
        if not args.client_id or not args.client_secret:
            print("[FAIL] --client-id and --client-secret are required for Cherwell", file=sys.stderr)
            sys.exit(1)

        access_token = cherwell_authenticate(url, args.client_id, args.client_secret)
        headers = {
            "Authorization": "Bearer {}".format(access_token),
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

        payload = {
            "busObId": "ChangeRequest",
            "busObRecId": args.cr_id,
            "fields": [
                {"name": "Status", "value": args.status},
            ],
        }

        itsm_request(url, "POST", "/CherwellAPI/api/V1/savebusinessobject", headers, payload)
        print("[PASS] Updated Cherwell CR {} to status: {}".format(args.cr_id, args.status))

    elif backend == "servicenow":
        # ServiceNow flow
        headers = servicenow_headers(url)
        payload = {
            "state": args.status,
        }

        itsm_request(
            url, "PATCH",
            "/api/now/table/change_request/{}".format(args.cr_id),
            headers, payload,
        )
        print("[PASS] Updated ServiceNow CR {} to status: {}".format(args.cr_id, args.status))
    else:
        print("[FAIL] Could not determine ITSM backend type", file=sys.stderr)
        sys.exit(1)


def main():
    # Check env vars first for the no-config case
    backend, env_url = get_itsm_backend()

    parser = argparse.ArgumentParser(
        description="ForgeOps Cherwell/ServiceNow ITSM integration",
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # --- create-cr ---
    create_parser = subparsers.add_parser("create-cr", help="Create a change request")
    create_parser.add_argument("--url", default="", help="ITSM base URL (overrides env var)")
    create_parser.add_argument("--client-id", default="", help="Cherwell client ID")
    create_parser.add_argument("--client-secret", default="", help="Cherwell client secret")
    create_parser.add_argument("--app", required=True, help="Application name")
    create_parser.add_argument("--version", required=True, help="Application version")
    create_parser.add_argument("--environment", required=True, help="Target environment")
    create_parser.add_argument("--approver", default="", help="Approver name or group")

    # --- update-cr ---
    update_parser = subparsers.add_parser("update-cr", help="Update a change request")
    update_parser.add_argument("--url", default="", help="ITSM base URL (overrides env var)")
    update_parser.add_argument("--client-id", default="", help="Cherwell client ID")
    update_parser.add_argument("--client-secret", default="", help="Cherwell client secret")
    update_parser.add_argument("--cr-id", required=True, help="Change request ID")
    update_parser.add_argument("--status", required=True, help="New status value")

    args = parser.parse_args()

    if not args.command:
        # If no subcommand and no ITSM configured, just skip
        if not backend:
            print("ITSM not configured - skipping")
            sys.exit(0)
        parser.print_help()
        sys.exit(1)

    dispatch = {
        "create-cr": cmd_create_cr,
        "update-cr": cmd_update_cr,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()
