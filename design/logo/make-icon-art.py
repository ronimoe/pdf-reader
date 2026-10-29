# Builds the full-bleed artwork for App/AppIcon.icon from design/logo/lectern-logo.webp.
# Needs Pillow, NumPy and SciPy. Usage: python3 make-icon-art.py lectern-logo.webp ../../App/AppIcon.icon/Assets/lectern.png
# The logo is a rounded square on a transparent background. The icon needs a full square (macOS applies
# its own shape and margins), so the square is cropped out and its transparent corners are filled with
# a smooth colour field fitted to the rim.
import sys, numpy as np
from PIL import Image
from scipy import ndimage
src, out = sys.argv[1], sys.argv[2]
a = np.asarray(Image.open(src).convert("RGBA")).astype(float)
# Square crop of the opaque squircle (x 104-1145, y 114-1141): 1028 px tall, centred horizontally.
y0, y1 = 114, 1142
cx = (104 + 1145 + 1) // 2
x0 = cx - (y1 - y0) // 2; x1 = x0 + (y1 - y0)
a = a[y0:y1, x0:x1]
al = a[..., 3]
# Trust only pixels well inside the squircle; the anti-aliased rim and the corners are rebuilt.
solid = ndimage.binary_erosion(al >= 250, iterations=6)
# Fit a smooth quadratic colour field to the outer band of the squircle and paint it everywhere outside.
dist = ndimage.distance_transform_edt(solid)
band = solid & (dist < 60)
yy, xx = np.mgrid[0:a.shape[0], 0:a.shape[1]] / a.shape[0]
def feats(x, y): return np.stack([np.ones_like(x), x, y, x*x, x*y, y*y], -1)
F = feats(xx[band], yy[band])
field = np.zeros(a.shape[:2] + (3,))
for c in range(3):
    coef, *_ = np.linalg.lstsq(F, a[..., c][band], rcond=None)
    field[..., c] = feats(xx, yy) @ coef
field = np.clip(field, 0, 255)
# Feather from the fitted field into the artwork over ~6 px so there is no seam.
w = np.clip(ndimage.distance_transform_edt(solid) / 6.0, 0, 1)[..., None]
rgb = a[..., :3] * w + field * (1 - w)
img = Image.fromarray(rgb.round().astype(np.uint8), "RGB").resize((1024, 1024), Image.LANCZOS)
img.save(out)
print("saved", out, img.size, "corner px", np.asarray(img)[5,5], np.asarray(img)[1018,1018])
