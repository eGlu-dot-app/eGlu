"""The icon cursor's fill: the cursor drawn smaller by the border's width.

In eGlu's icon the cursor is a black fill inside a white border. The white
layer is the whole cursor (Shared/eGlu.icon/Assets/cursor.svg); the black
one lies over it and is this shape: each straight edge of the cursor moved
in by the border's width, its outer corners rounded off again, its two
inner corners (the notches) rounded by the border's width round the
cursor's own corner, as any shape drawn smaller by a constant width is.

Run it again whenever the cursor changes. From the repository's folder:

    python3 Marketing/Brand/cursor-inset.py

It reads the straight edges (the L commands) of the cursor's path, so the
path has to be absolute M, L, C and Z, as symbol.swift writes it.
"""
import argparse
import math
import re

parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
parser.add_argument("cursor", nargs="?", default="Shared/eGlu.icon/Assets/cursor.svg",
                    help="the whole cursor (default: %(default)s)")
parser.add_argument("output", nargs="?", default="Shared/eGlu.icon/Assets/cursor-fill.svg",
                    help="where the fill goes (default: %(default)s)")
parser.add_argument("--border", type=float, default=12,
                    help="the white border's width, in the SVG's units (default: %(default)s)")
parser.add_argument("--radius", type=float, default=4,
                    help="the fill's outer corners' radius (default: %(default)s)")
args = parser.parse_args()
D, R = args.border, args.radius

source = open(args.cursor).read()
path = re.search(r'\sd="([^"]+)"', source).group(1)
tokens = re.findall(r"[A-Za-z]|-?\d*\.?\d+(?:e-?\d+)?", path)

# Only the straight edges are kept: the curves are the cursor's rounded
# corners, and the fill's corners are drawn again from the moved edges.
edges, point, i = [], None, 0
while i < len(tokens):
    command = tokens[i]
    if command not in "MLCZ":
        raise SystemExit(f"Only absolute M, L, C and Z are read, not {command}")
    count = {"M": 2, "L": 2, "C": 6, "Z": 0}[command]
    numbers = [float(n) for n in tokens[i + 1:i + 1 + count]]
    if command == "L":
        edges.append((point, (numbers[0], numbers[1])))
    if count:
        point = (numbers[-2], numbers[-1])
    i += 1 + count


def cross(a, b): return a[0] * b[1] - a[1] * b[0]
def sub(a, b): return (a[0] - b[0], a[1] - b[1])
def add(a, b): return (a[0] + b[0], a[1] + b[1])
def mul(a, s): return (a[0] * s, a[1] * s)


def unit(a):
    length = math.hypot(*a)
    return (a[0] / length, a[1] / length)


def meet(p, r, q, s):
    """Where the line through p along r meets the one through q along s."""
    return add(p, mul(r, cross(sub(q, p), s) / cross(r, s)))


# The path may run either way round, so its winding decides which side of
# each edge is inside; the wrong one would grow the cursor, not shrink it.
sharp =[meet(edges[i - 1][0], sub(edges[i - 1][1], edges[i - 1][0]), edges[i][0], sub(edges[i][1], edges[i][0]))
         for i in range(len(edges))]
side = 1 if sum(cross(a, b) for a, b in zip(sharp, sharp[1:] + sharp[:1])) > 0 else -1

moved = []
for a, b in edges:
    u = unit(sub(b, a))
    inward = (-u[1] * side, u[0] * side)
    moved.append((add(a, mul(inward, D)), u, inward))

out = []
for i in range(len(edges)):
    (p0, u0, n0), (p1, u1, n1) = moved[i - 1], moved[i]
    if cross(u0, u1) * side > 0:
        # Without the cursor's curves the moved edges meet in a point;
        # R softens it as the cursor's own corners are.
        corner = meet(p0, u0, p1, u1)
        half = math.acos(max(-1, min(1, -(u0[0] * u1[0] + u0[1] * u1[1])))) / 2
        t = R / math.tan(half)
        a, b = sub(corner, mul(u0, t)), add(corner, mul(u1, t))
        k = 4 / 3 * math.tan((math.pi - 2 * half) / 4) * R
        out.append(("L", a))
        out.append(("C", add(a, mul(u0, k)), sub(b, mul(u1, k)), b))
    else:
        # In a notch the moved edges don't meet. An arc of D round the
        # cursor's own corner keeps the white border D wide there too;
        # carried on to meet in a point, the edges would widen it.
        a0, a1 = math.atan2(n0[1], n0[0]), math.atan2(n1[1], n1[0])
        while a1 - a0 > math.pi: a1 -= 2 * math.pi
        while a1 - a0 < -math.pi: a1 += 2 * math.pi
        for step in range(9):
            angle = a0 + (a1 - a0) * step / 8
            out.append(("L", add(sharp[i], (math.cos(angle) * D, math.sin(angle) * D))))


def f(p): return f"{p[0]:.2f} {p[1]:.2f}"


d = "M" + f(out[0][1])
for segment in out[1:]:
    d += ("L" + f(segment[1])) if segment[0] == "L" else ("C" + f(segment[1]) + " " + f(segment[2]) + " " + f(segment[3]))
d += "Z"
with open(args.output, "w") as file:
    file.write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 800" width="800" height="800">\n'
               f'<path fill="#000000" fill-rule="nonzero" d="{d}"/>\n</svg>\n')
