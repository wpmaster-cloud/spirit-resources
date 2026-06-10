#!/usr/bin/env python3
# name: Notion Tool
# description: CLI tool for interacting with Notion API (search, pages, databases).
import os
import sys
import json
import argparse
from notion_client import Client

def get_client():
    token = os.environ.get("NOTION_TOKEN")
    if not token:
        print("Error: NOTION_TOKEN environment variable is required.")
        sys.exit(1)
    return Client(auth=token)

def cmd_search(args):
    notion = get_client()
    results = notion.search(query=args.query, filter=args.filter, sort=args.sort).get("results", [])
    print(json.dumps(results, indent=2))

def cmd_get_page(args):
    notion = get_client()
    page = notion.pages.retrieve(page_id=args.page_id)
    print(json.dumps(page, indent=2))

def cmd_get_blocks(args):
    notion = get_client()
    blocks = notion.blocks.children.list(block_id=args.block_id).get("results", [])
    print(json.dumps(blocks, indent=2))

def cmd_create_page(args):
    notion = get_client()
    parent = json.loads(args.parent)
    properties = json.loads(args.properties)
    children = json.loads(args.children) if args.children else None
    page = notion.pages.create(parent=parent, properties=properties, children=children)
    print(json.dumps(page, indent=2))

def cmd_update_page(args):
    notion = get_client()
    properties = json.loads(args.properties) if args.properties else None
    page = notion.pages.update(page_id=args.page_id, properties=properties, archived=args.archived)
    print(json.dumps(page, indent=2))

def cmd_query_database(args):
    notion = get_client()
    filter_obj = json.loads(args.filter) if args.filter else None
    sorts = json.loads(args.sorts) if args.sorts else None
    results = notion.databases.query(database_id=args.database_id, filter=filter_obj, sorts=sorts).get("results", [])
    print(json.dumps(results, indent=2))

def main():
    parser = argparse.ArgumentParser(description="Notion CLI tool for Minimino")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # Search
    p_search = subparsers.add_parser("search")
    p_search.add_argument("query")
    p_search.add_argument("--filter", type=json.loads)
    p_search.add_argument("--sort", type=json.loads)

    # Get Page
    p_get_page = subparsers.add_parser("get_page")
    p_get_page.add_argument("page_id")

    # Get Blocks
    p_get_blocks = subparsers.add_parser("get_blocks")
    p_get_blocks.add_argument("block_id")

    # Create Page
    p_create_page = subparsers.add_parser("create_page")
    p_create_page.add_argument("--parent", required=True, help='JSON string, e.g. \'{"page_id":"..."}\'')
    p_create_page.add_argument("--properties", required=True, help='JSON string of properties')
    p_create_page.add_argument("--children", help='JSON string of blocks')

    # Update Page
    p_update_page = subparsers.add_parser("update_page")
    p_update_page.add_argument("page_id")
    p_update_page.add_argument("--properties", help='JSON string of properties')
    p_update_page.add_argument("--archived", action="store_true")

    # Query Database
    p_query_db = subparsers.add_parser("query_database")
    p_query_db.add_argument("database_id")
    p_query_db.add_argument("--filter", help='JSON string filter')
    p_query_db.add_argument("--sorts", help='JSON string sorts')

    args = parser.parse_args()

    try:
        if args.command == "search": cmd_search(args)
        elif args.command == "get_page": cmd_get_page(args)
        elif args.command == "get_blocks": cmd_get_blocks(args)
        elif args.command == "create_page": cmd_create_page(args)
        elif args.command == "update_page": cmd_update_page(args)
        elif args.command == "query_database": cmd_query_database(args)
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
