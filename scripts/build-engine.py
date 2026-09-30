#!/usr/bin/env python3
"""Build the pinned upstream Makefile's engine sources, replacing its X11 backend."""
import concurrent.futures
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
source = root / 'vendor/doomgeneric/doomgeneric'
objects = root / 'build/engine'
objects.mkdir(parents=True, exist_ok=True)
clang = subprocess.check_output(['xcrun', '--find', 'clang'], text=True).strip()
makefile = (source / 'Makefile').read_text()
names = re.search(r'^SRC_DOOM\s*=\s*(.+)$', makefile, re.M).group(1).split()
files = [source / name.replace('.o', '.c') for name in names if name != 'doomgeneric_xlib.o']
files.extend([root / 'Sources/EngineBridge.c', root / 'Sources/NativeSound.c'])
# Upstream's dispatcher only needs this SDL header for an unused legacy include.
# Generate a native dispatcher copy; keep the pinned vendor checkout unchanged.
native_dispatcher = objects / 'i_sound.c'
native_dispatcher.write_text((source / 'i_sound.c').read_text().replace('#include <SDL_mixer.h>', '// Native AudioQueue backend; no SDL dependency.'))
native_status = objects / 'st_stuff.c'
native_status.write_text((source / 'st_stuff.c').read_text() + '\n#include "StatusFace.inc"\n')
files = [native_dispatcher if f.name == 'i_sound.c' else native_status if f.name == 'st_stuff.c' else f for f in files]
# Do not link objects from source files removed since a previous build.
expected_objects = {file.stem + '.o' for file in files}
for stale in objects.glob('*.o'):
    if stale.name not in expected_objects:
        stale.unlink()
flags = ['-O2', '-g', f'-ffile-prefix-map={root}=.', '-std=gnu11', '-arch', 'arm64', '-mmacosx-version-min=13.0',
         '-DNORMALUNIX', '-D_DEFAULT_SOURCE', '-D__MACOSX__',
         '-DDOOMGENERIC_RESX=320', '-DDOOMGENERIC_RESY=200', '-I', str(source), '-I', str(root / 'Sources')]

def compile_one(file):
    extra = ['-DI_Quit=DD_OriginalQuit', '-DI_Error=DD_OriginalError'] if file.name == 'i_system.c' else []
    if file.name in ('i_sound.c', 'm_config.c'): extra += ['-DFEATURE_SOUND']
    result = subprocess.run([clang, *flags, *extra, '-c', str(file), '-o', str(objects / (file.stem + '.o'))], capture_output=True, text=True)
    return file.name, result

failures = []
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    for name, result in pool.map(compile_one, files):
        if result.returncode:
            print(f'{name}:\n{result.stderr}')
            failures.append(name)
        elif result.stderr:
            # Preserve upstream warnings for review without obscuring build errors.
            (objects / (name + '.warnings.txt')).write_text(result.stderr)
if failures:
    raise SystemExit('Failed: ' + ', '.join(failures))
print(f'Compiled {len(files)} engine/platform C files for arm64.')
