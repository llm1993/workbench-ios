"""Compile the existing Workbench SVG mark into the opaque iOS icon asset.

Install scripts/requirements-icons.txt into a tooling environment, then run this
script. --renderer-libs may point to a pip --target directory. CI uses the checked
in PNG; it does not need these rendering dependencies.
"""
import argparse
from io import BytesIO
from pathlib import Path
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--renderer-libs')
args = parser.parse_args()
if args.renderer_libs:
    sys.path.insert(0, args.renderer_libs)
from PIL import Image
from resvg_py import svg_to_bytes

root = Path(__file__).resolve().parents[1]
source = root / 'Design/workbench-app-icon.svg'
target = root / 'ClipStudio/Assets.xcassets/AppIcon.appiconset/icon.png'
png = svg_to_bytes(svg_path=str(source), width=1024, height=1024, skip_system_fonts=True)
with Image.open(BytesIO(png)) as icon:
    assert icon.size == (1024, 1024)
    assert icon.convert('RGBA').getchannel('A').getextrema() == (255, 255)
    icon.convert('RGB').save(target, optimize=True)
print('Compiled opaque 1024 x 1024 Workbench AppIcon from SVG.')
