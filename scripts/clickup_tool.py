#!/usr/bin/env python3
# name: ClickUp Tool
# description: CLI tool for interacting with ClickUp API (tasks, spaces, folders, lists).
import os
import sys
import json
import argparse
import urllib.request

def request(method, path, data=None):
    token = os.environ.get("CLICKUP_API_TOKEN")
    if not token:
        print("Error: CLICKUP_API_TOKEN environment variable is required.")
        sys.exit(1)

    url = f"https://api.clickup.com/api/v2{path}"
    headers = {
        "Authorization": token,
        "Content-Type": "application/json"
    }
    
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        print(f"Error: {e.code} {e.reason}")
        print(e.read().decode())
        sys.exit(1)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

def cmd_get_tasks(args):
    # Default to current user's tasks or specific list
    path = f"/list/{args.list_id}/task" if args.list_id else "/team/" + args.team_id + "/task"
    params = []
    if args.archived: params.append("archived=true")
    if params: path += "?" + "&".join(params)
    
    res = request("GET", path)
    print(json.dumps(res, indent=2))

def cmd_create_task(args):
    path = f"/list/{args.list_id}/task"
    data = {
        "name": args.name,
        "description": args.description,
        "status": args.status,
        "priority": args.priority
    }
    res = request("POST", path, data)
    print(json.dumps(res, indent=2))

def cmd_get_teams(args):
    res = request("GET", "/team")
    print(json.dumps(res, indent=2))

def cmd_get_spaces(args):
    res = request("GET", f"/team/{args.team_id}/space")
    print(json.dumps(res, indent=2))

def cmd_get_folders(args):
    res = request("GET", f"/space/{args.space_id}/folder")
    print(json.dumps(res, indent=2))

def cmd_get_lists(args):
    res = request("GET", f"/folder/{args.folder_id}/list")
    print(json.dumps(res, indent=2))

def main():
    parser = argparse.ArgumentParser(description="ClickUp CLI tool for Minimino")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Teams
    subparsers.add_parser("get_teams")

    # Spaces
    p_spaces = subparsers.add_parser("get_spaces")
    p_spaces.add_argument("team_id")

    # Folders
    p_folders = subparsers.add_parser("get_folders")
    p_folders.add_argument("space_id")

    # Lists
    p_lists = subparsers.add_parser("get_lists")
    p_lists.add_argument("folder_id")

    # Tasks
    p_tasks = subparsers.add_parser("get_tasks")
    p_tasks.add_argument("--list_id")
    p_tasks.add_argument("--team_id")
    p_tasks.add_argument("--archived", action="store_true")

    # Create Task
    p_create = subparsers.add_parser("create_task")
    p_create.add_argument("list_id")
    p_create.add_argument("name")
    p_create.add_argument("--description")
    p_create.add_argument("--status")
    p_create.add_argument("--priority", type=int)

    args = parser.parse_args()

    if args.command == "get_teams": cmd_get_teams(args)
    elif args.command == "get_spaces": cmd_get_spaces(args)
    elif args.command == "get_folders": cmd_get_folders(args)
    elif args.command == "get_lists": cmd_get_lists(args)
    elif args.command == "get_tasks": cmd_get_tasks(args)
    elif args.command == "create_task": cmd_create_task(args)

if __name__ == "__main__":
    main()
