#!/usr/bin/env python3
"""
jira-integration.py - Jira integration for ForgeOps CI/CD pipelines.

Subcommands:
  create-ticket   Create a new Jira issue
  transition      Transition issues found in git commit range
  set-fix-version Set fix version on issues found in git commit range

Uses only argparse and urllib (stdlib). No third-party dependencies.
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.request
import urllib.error
import urllib.parse


TICKET_PATTERN = re.compile(r"[A-Z]+-\d+")


def jira_request(base_url, token, method, path, data=None):
    """Make an authenticated Jira REST API request."""
    url = base_url.rstrip("/") + path
    headers = {
        "Authorization": "Basic " + token,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp_body = resp.read().decode("utf-8")
            if resp_body:
                return json.loads(resp_body)
            return None
    except urllib.error.HTTPError as exc:
        err_body = exc.read().decode("utf-8", errors="replace")
        print("[FAIL] Jira API error: HTTP {} - {}".format(exc.code, err_body), file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as exc:
        print("[FAIL] Jira connection error: {}".format(exc.reason), file=sys.stderr)
        sys.exit(1)


def extract_tickets_from_commits(commit_range):
    """Extract Jira ticket IDs from git log messages in the given commit range."""
    try:
        result = subprocess.run(
            ["git", "log", "--oneline", commit_range],
            capture_output=True,
            text=True,
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        print("[FAIL] git log failed: {}".format(exc.stderr.strip()), file=sys.stderr)
        sys.exit(1)
    except FileNotFoundError:
        print("[FAIL] git not found in PATH", file=sys.stderr)
        sys.exit(1)

    tickets = set()
    for line in result.stdout.splitlines():
        tickets.update(TICKET_PATTERN.findall(line))

    return sorted(tickets)


def cmd_create_ticket(args):
    """Handle the create-ticket subcommand."""
    if not args.url or args.url.lower() == "none":
        print("Jira not configured - skipping")
        sys.exit(0)

    labels = []
    if args.labels:
        labels = [l.strip() for l in args.labels.split(",") if l.strip()]

    payload = {
        "fields": {
            "project": {"key": args.project},
            "issuetype": {"name": args.type},
            "summary": args.summary,
            "description": args.description or "",
            "priority": {"name": args.priority or "Medium"},
        }
    }
    if labels:
        payload["fields"]["labels"] = labels

    result = jira_request(args.url, args.token, "POST", "/rest/api/2/issue", payload)

    if result and "key" in result:
        print("[PASS] Created Jira ticket: {}".format(result["key"]))
        print(result["key"])
    else:
        print("[FAIL] Unexpected response from Jira", file=sys.stderr)
        sys.exit(1)


def cmd_transition(args):
    """Handle the transition subcommand."""
    if not args.url or args.url.lower() == "none":
        print("Jira not configured - skipping")
        sys.exit(0)

    tickets = extract_tickets_from_commits(args.commit_range)
    if not tickets:
        print("[INFO] No Jira tickets found in commit range: {}".format(args.commit_range))
        sys.exit(0)

    print("[INFO] Found tickets: {}".format(", ".join(tickets)))

    for ticket in tickets:
        # Get available transitions
        transitions_resp = jira_request(
            args.url, args.token, "GET",
            "/rest/api/2/issue/{}/transitions".format(ticket),
        )
        if not transitions_resp or "transitions" not in transitions_resp:
            print("[SKIP] Could not fetch transitions for {}".format(ticket))
            continue

        target_id = None
        for t in transitions_resp["transitions"]:
            if t["name"].lower() == args.status.lower():
                target_id = t["id"]
                break

        if not target_id:
            available = [t["name"] for t in transitions_resp["transitions"]]
            print("[SKIP] Transition '{}' not available for {} (available: {})".format(
                args.status, ticket, ", ".join(available)))
            continue

        payload = {"transition": {"id": target_id}}
        if args.comment:
            payload["update"] = {
                "comment": [{"add": {"body": args.comment}}]
            }

        jira_request(
            args.url, args.token, "POST",
            "/rest/api/2/issue/{}/transitions".format(ticket),
            payload,
        )
        print("[PASS] Transitioned {} to '{}'".format(ticket, args.status))


def cmd_set_fix_version(args):
    """Handle the set-fix-version subcommand."""
    if not args.url or args.url.lower() == "none":
        print("Jira not configured - skipping")
        sys.exit(0)

    tickets = extract_tickets_from_commits(args.commit_range)
    if not tickets:
        print("[INFO] No Jira tickets found in commit range: {}".format(args.commit_range))
        sys.exit(0)

    print("[INFO] Found tickets: {}".format(", ".join(tickets)))

    for ticket in tickets:
        payload = {
            "update": {
                "fixVersions": [{"add": {"name": args.version}}]
            }
        }
        jira_request(
            args.url, args.token, "PUT",
            "/rest/api/2/issue/{}".format(ticket),
            payload,
        )
        print("[PASS] Set fix version '{}' on {}".format(args.version, ticket))


def main():
    parser = argparse.ArgumentParser(
        description="ForgeOps Jira integration for CI/CD pipelines",
    )
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # --- create-ticket ---
    create_parser = subparsers.add_parser("create-ticket", help="Create a new Jira issue")
    create_parser.add_argument("--url", required=True, help="Jira base URL (or 'none' to skip)")
    create_parser.add_argument("--token", required=True, help="Jira API token (base64 user:token)")
    create_parser.add_argument("--project", required=True, help="Jira project key (e.g. FORGE)")
    create_parser.add_argument("--type", required=True, help="Issue type (e.g. Bug, Task, Story)")
    create_parser.add_argument("--summary", required=True, help="Issue summary / title")
    create_parser.add_argument("--description", default="", help="Issue description")
    create_parser.add_argument("--priority", default="Medium", help="Priority (default: Medium)")
    create_parser.add_argument("--labels", default="", help="Comma-separated labels")

    # --- transition ---
    transition_parser = subparsers.add_parser(
        "transition", help="Transition issues referenced in commits",
    )
    transition_parser.add_argument("--url", required=True, help="Jira base URL (or 'none' to skip)")
    transition_parser.add_argument("--token", required=True, help="Jira API token")
    transition_parser.add_argument("--commit-range", required=True, help="Git commit range (e.g. HEAD~5..HEAD)")
    transition_parser.add_argument("--status", required=True, help="Target transition name")
    transition_parser.add_argument("--comment", default="", help="Comment to add on transition")

    # --- set-fix-version ---
    fix_parser = subparsers.add_parser(
        "set-fix-version", help="Set fix version on issues referenced in commits",
    )
    fix_parser.add_argument("--url", required=True, help="Jira base URL (or 'none' to skip)")
    fix_parser.add_argument("--token", required=True, help="Jira API token")
    fix_parser.add_argument("--commit-range", required=True, help="Git commit range")
    fix_parser.add_argument("--version", required=True, help="Fix version name")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    dispatch = {
        "create-ticket": cmd_create_ticket,
        "transition": cmd_transition,
        "set-fix-version": cmd_set_fix_version,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()
