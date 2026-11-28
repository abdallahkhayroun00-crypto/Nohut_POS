"""Prints small JPEG copies of emulator screenshots into the CI log."""
import base64, io, sys, pathlib
from PIL import Image
for f in sorted(pathlib.Path(sys.argv[1]).glob('*.png')):
    im = Image.open(f).convert('RGB'); im.thumbnail((360, 800))
    buf = io.BytesIO(); im.save(buf, 'JPEG', quality=70)
    print(f'NOHUT_SHOT_BEGIN {f.name}'); print(base64.b64encode(buf.getvalue()).decode()); print('NOHUT_SHOT_END')
