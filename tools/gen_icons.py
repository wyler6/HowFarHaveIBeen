"""Generate the shipped icon formats from the source logo.

    pip install Pillow numpy
    python tools/gen_icons.py

Reads art/logo.png (square, RGB or RGBA) and writes:

    Media/icon.tga              64x64 32-bit uncompressed - the in-game addon icon
    art/curseforge-logo-400.png 400x400 - the CurseForge project avatar

Only Media/icon.tga ships; art/ is in the .pkgmeta ignore list.
"""
import os
import sys

import numpy as np
from PIL import Image

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(REPO, 'art', 'logo.png')


def resize_premultiplied(im, size):
    """Downscale RGBA without colour fringing on soft edges.

    Pillow resizes channels independently, so RGB from fully transparent
    pixels bleeds into the glow -- and transparent pixels may carry
    non-black colour. Premultiplying weights each pixel's colour by its
    own alpha first, which is what a correct filter needs.
    """
    a = np.array(im).astype(np.float64)
    rgb, al = a[..., :3], a[..., 3:4] / 255.0
    pm = np.concatenate([rgb * al, a[..., 3:4]], axis=2)
    small = np.array(
        Image.fromarray(pm.round().clip(0, 255).astype(np.uint8), 'RGBA')
        .resize(size, Image.LANCZOS)
    ).astype(np.float64)
    out_a = small[..., 3:4]
    with np.errstate(divide='ignore', invalid='ignore'):
        out_rgb = np.where(out_a > 0, small[..., :3] / (out_a / 255.0), 0)
    return Image.fromarray(
        np.concatenate([out_rgb, out_a], axis=2).round().clip(0, 255).astype(np.uint8),
        'RGBA',
    )


def main():
    src_path = sys.argv[1] if len(sys.argv) > 1 else SRC
    if not os.path.exists(src_path):
        raise SystemExit(f"No source logo at {src_path}\n"
                         f"Put a square PNG there, or pass one as an argument.")

    src = Image.open(src_path).convert('RGBA')
    if src.size[0] != src.size[1]:
        print(f"warning: source is {src.size[0]}x{src.size[1]}, not square; "
              f"it will be squashed")
    print(f"source {os.path.relpath(src_path, REPO)} {src.size}")

    # WoW loads TGA/BLP only, wants power-of-two dimensions, and 64x64 is the
    # size Blizzard's own Interface\Icons art uses.
    tga = os.path.join(REPO, 'Media', 'icon.tga')
    os.makedirs(os.path.dirname(tga), exist_ok=True)
    # Pillow writes uncompressed TGA unless asked for RLE.
    resize_premultiplied(src, (64, 64)).save(tga, format='TGA')

    # CurseForge project avatar, well under their upload size cap.
    cf = os.path.join(REPO, 'art', 'curseforge-logo-400.png')
    resize_premultiplied(src, (400, 400)).save(cf, format='PNG', optimize=True)

    for p in (tga, cf):
        print(f"  wrote {os.path.relpath(p, REPO)}  {os.path.getsize(p):,} bytes")

    with open(tga, 'rb') as fh:
        h = fh.read(18)
    assert h[2] == 2, f"TGA is not uncompressed true-colour (type {h[2]})"
    assert h[16] == 32, f"TGA is not 32bpp (got {h[16]})"
    print(f"  verified {int.from_bytes(h[12:14], 'little')}x"
          f"{int.from_bytes(h[14:16], 'little')} {h[16]}bpp uncompressed")
    print("\nNow run tools/deploy.ps1 and restart the client to see it.")


if __name__ == '__main__':
    main()
