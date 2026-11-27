"""Command line: python -m creature_maker <command> ...

  build RECORD.json OUT [--res 2048] [--no-form] [--debug]   record -> cage, UVs, maps, fins (numpy, no Blender)
  check OUT RECORD.json [--planted]                           cage + export checks -> OUT/checks.json
  board OUTROOT RECORD_DIR_OR_FILE... [--only a,b]           every record through build + cage checks -> board.json
  glb OUT                                                     OUT -> OUT/<species>.glb (runs Blender's Python: bpy)
"""
import sys, os, subprocess


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__); return 0
    cmd, args = argv[0], argv[1:]
    if cmd == 'build':
        from .build import build
        res = int(args[args.index('--res') + 1]) if '--res' in args else 2048
        build(args[0], args[1], res=res, dense_form='--no-form' not in args, debug='--debug' in args)
        return 0
    if cmd == 'check':
        import json
        from .checks import check
        R = check(args[0], args[1], '--planted' in args)
        print(json.dumps({k: v for k, v in R.items() if k.endswith('_pass') or k in ('OP3_folds_by_region', 'PLANTED_caught', 'OP1_topology')}, indent=1, default=str))
        return 0
    if cmd == 'board':
        from .board import run
        only = args[args.index('--only') + 1].split(',') if '--only' in args else ()
        srcs = [a for i, a in enumerate(args[1:], 1) if not a.startswith('--') and args[i - 1] != '--only']
        res = run(args[0], srcs, only)
        for n, v in sorted(res.items()): print(n, v)
        return 0
    if cmd == 'glb':
        script = os.path.join(os.path.dirname(__file__), 'blender', 'export_glb.py')
        return subprocess.call([sys.executable, script] + args)
    print(f'unknown command {cmd}\n{__doc__}'); return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
