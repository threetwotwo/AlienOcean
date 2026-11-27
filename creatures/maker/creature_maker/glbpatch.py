"""Add structured extras to a written GLB (pure Python): Blender's exporter only writes flat custom properties, and the engine wants
nested data (the swim settings). Rewrites the JSON chunk, keeps the binary chunk byte for byte."""
import json, struct


def read(path):
    b = open(path, 'rb').read(); assert b[:4] == b'glTF'
    n0 = struct.unpack('<I', b[12:16])[0]; js = json.loads(b[20:20 + n0].decode().rstrip(' \0')); rest = b[20 + n0:]
    return js, rest


def write(path, js, rest):
    j = json.dumps(js, separators=(',', ':')).encode(); j += b' ' * (-len(j) % 4)
    total = 12 + 8 + len(j) + len(rest)
    open(path, 'wb').write(b'glTF' + struct.pack('<II', 2, total) + struct.pack('<I', len(j)) + b'JSON' + j + rest)


def patch(path, scene_extras=None, node_extras=None, anim_extras=None):
    """scene_extras: dict merged into scenes[0].extras; node_extras: {node name: dict}; anim_extras: {animation name: dict}."""
    js, rest = read(path)
    if scene_extras:
        for s in js.get('scenes', []): s.setdefault('extras', {}).update(scene_extras)
    for n in js.get('nodes', []):
        if node_extras and n.get('name') in node_extras: n.setdefault('extras', {}).update(node_extras[n['name']])
    for a in js.get('animations', []):
        if anim_extras and a.get('name') in anim_extras: a.setdefault('extras', {}).update(anim_extras[a['name']])
    write(path, js, rest); return js
