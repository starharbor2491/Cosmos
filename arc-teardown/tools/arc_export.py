#!/usr/bin/env python3
"""Export Arc's sidebar (spaces, favorites, pinned/unpinned tabs, folders, splits) to a neutral JSON tree.

Reads ~/Library/Application Support/Arc/StorableSidebar.json (format documented in
../data-and-sync.md) and writes a self-contained file that does not depend on Arc.

    python3 arc_export.py                     # writes arc-export.json in the current folder
    python3 arc_export.py -o ~/Desktop/arc.json
    python3 arc_export.py --summary           # print counts only

Output shape:
    {
      "exportedAt": "2026-10-25T20:00:00Z",
      "favorites": [Node],
      "spaces": [{"id", "title", "icon", "profile", "pinned": [Node], "unpinned": [Node]}]
    }
    Node = {"type": "tab", "id", "title", "url", "createdAt", "lastActiveAt"}
         | {"type": "folder", "id", "title", "createdAt", "children": [Node]}
         | {"type": "split", "id", "orientation", "children": [Node]}
         | {"type": "easel" | "unknown", "id", "title", ...}
Dates are ISO-8601 UTC.
"""
import argparse
import datetime as dt
import json
import os
import sys

ARC_DIR = os.path.expanduser('~/Library/Application Support/Arc')
APPLE_EPOCH = dt.datetime(2001, 1, 1, tzinfo=dt.timezone.utc)


def iso(seconds):
    if not isinstance(seconds, (int, float)):
        return None
    return (APPLE_EPOCH + dt.timedelta(seconds=seconds)).strftime('%Y-%m-%dT%H:%M:%SZ')


def pairs(flat):
    """Swift encodes [UUID: Value] dictionaries as [key, value, key, value, ...]."""
    return {flat[i]: flat[i + 1] for i in range(0, len(flat) - 1, 2) if isinstance(flat[i + 1], dict)}


def enum_case(value):
    """Swift enums with payloads encode as {"caseName": payload}; return (case, payload)."""
    if isinstance(value, dict) and len(value) == 1:
        (k, v), = value.items()
        return k, v
    return None, value


def convert(item_id, items, seen):
    item = items.get(item_id)
    if item is None or item_id in seen:
        return None
    seen.add(item_id)
    case, payload = enum_case(item.get('data') or {})
    children = [n for n in (convert(c, items, seen) for c in item.get('childrenIds') or []) if n]
    base = {'id': item_id, 'createdAt': iso(item.get('createdAt'))}
    if case == 'tab':
        return {**base, 'type': 'tab',
                'title': item.get('title') or payload.get('savedTitle'),
                'url': payload.get('savedURL'),
                'lastActiveAt': iso(payload.get('timeLastActiveAt'))}
    if case == 'list':
        return {**base, 'type': 'folder', 'title': item.get('title'), 'children': children}
    if case == 'splitView':
        return {**base, 'type': 'split', 'orientation': payload.get('layoutOrientation'), 'children': children}
    if case == 'easel':
        return {**base, 'type': 'easel', 'title': item.get('title'), 'easelID': (payload or {}).get('easelID')}
    return {**base, 'type': case or 'unknown', 'title': item.get('title'), 'children': children}


def export(sidebar):
    container = next(c for c in sidebar['sidebar']['containers'] if 'items' in c)
    items = pairs(container['items'])
    seen = set()

    def roots_children(root_id):
        root = items.get(root_id) or {}
        return [n for n in (convert(c, items, seen) for c in root.get('childrenIds') or []) if n]

    favorites = []
    for item_id, item in items.items():
        case, payload = enum_case(item.get('data') or {})
        if case == 'itemContainer' and 'topApps' in (payload.get('containerType') or {}):
            favorites += roots_children(item_id)

    spaces = []
    for space_id, space in pairs(container.get('spaces') or []).items():
        ids = space.get('containerIDs') or []
        sections = {ids[i]: ids[i + 1] for i in range(0, len(ids) - 1, 2) if isinstance(ids[i], str)}
        profile_case, profile_payload = enum_case(space.get('profile') or {})
        spaces.append({
            'id': space_id,
            'title': space.get('title'),
            'icon': ((space.get('customInfo') or {}).get('iconType') or {}).get('icon'),
            'profile': 'default' if profile_case == 'default' else profile_payload,
            'pinned': roots_children(sections.get('pinned')),
            'unpinned': roots_children(sections.get('unpinned')),
        })

    return {'exportedAt': dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
            'source': 'Arc StorableSidebar.json', 'favorites': favorites, 'spaces': spaces}


def count(nodes):
    n = {'tabs': 0, 'folders': 0, 'splits': 0, 'other': 0}
    for node in nodes:
        key = {'tab': 'tabs', 'folder': 'folders', 'split': 'splits'}.get(node['type'], 'other')
        n[key] += 1
        for k, v in count(node.get('children') or []).items():
            n[k] += v
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('-i', '--input', default=os.path.join(ARC_DIR, 'StorableSidebar.json'))
    ap.add_argument('-o', '--output', default='arc-export.json')
    ap.add_argument('--summary', action='store_true', help='print counts only; write nothing')
    args = ap.parse_args()

    with open(args.input) as f:
        result = export(json.load(f))
    print(f"favorites: {count(result['favorites'])}")
    for i, s in enumerate(result['spaces'], 1):
        print(f"space {i}: pinned {count(s['pinned'])}, unpinned {count(s['unpinned'])}")
    if not args.summary:
        with open(args.output, 'w') as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
        print(f'wrote {args.output}')


if __name__ == '__main__':
    sys.exit(main())
