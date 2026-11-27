"""Ship a built creature to the engine (engine contract, agreed with the Godot thread 27 Nov): fish.glb, fish_LOD1.glb and
fish_LOD2.glb go to engine/godot/assets/creatures/<species>/ (gitignored) and are listed in the repo's assets.lock.json with md5,
size, the project-files store they are kept in and the tool that built them, so any checkout can fetch exactly these bytes."""
import hashlib, json, os, shutil

STORE = 'project files assets/creatures/'
FILES = ('fish.glb', 'fish_LOD1.glb', 'fish_LOD2.glb')


def repo_root(p):
    p = os.path.abspath(p)
    while p != os.path.dirname(p):
        if os.path.exists(os.path.join(p, 'assets.lock.json')): return p
        p = os.path.dirname(p)
    raise FileNotFoundError('assets.lock.json not found above ' + p)


def ship(out, dest, lock=None):
    os.makedirs(dest, exist_ok=True); root = repo_root(dest); lock = lock or os.path.join(root, 'assets.lock.json')
    L = json.load(open(lock)); sp = os.path.basename(os.path.normpath(dest)); rows = []
    for f in FILES:
        src = os.path.join(out, f)
        if not os.path.exists(src): raise FileNotFoundError(src)
        dst = os.path.join(dest, f); shutil.copyfile(src, dst)
        rel = os.path.relpath(dst, root).replace(os.sep, '/')
        row = dict(path=rel, md5=hashlib.md5(open(dst, 'rb').read()).hexdigest(), bytes=os.path.getsize(dst),
                   store=STORE + sp + '/', built_by='creatures/maker: python -m creature_maker glb')
        L['files'] = [r for r in L['files'] if r['path'] != rel] + [row]; rows.append(row)
    json.dump(L, open(lock, 'w'), indent=1); open(lock, 'a').write('\n')
    return rows
