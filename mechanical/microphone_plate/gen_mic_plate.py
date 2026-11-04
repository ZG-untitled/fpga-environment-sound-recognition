# -*- coding: utf-8 -*-
"""
麦克风阵列底板 v2 —— 参数化生成 STL（无需外部 CAD）
输出：
    mic_plate_v2.stl   主板 100x100x4，带沉孔 + 定位盲孔
    mic_cap_v1.stl     压罩 x4（一次打印，摆放已错开）

几何策略：所有零件都可用「若干层 2D 轮廓沿 Z 挤出」精确描述，
逐层生成侧壁 + 层间接缝 + 上下封盖，得到闭合 watertight 网格。
"""

import math
import os

import numpy as np
import trimesh
from shapely.geometry import Point, box
from shapely.geometry.polygon import orient
from shapely.ops import unary_union

# ============================ 参数区（改这里） ============================
PLATE_W, PLATE_H, PLATE_T = 100.0, 100.0, 4.0
HOLE_XY = [(-30, -30), (30, -30), (-30, 30), (30, 30)]

MIC_D      = 14.5   # INMP441 模块 PCB 实测外径
MIC_T      = 1.6    # 模块 PCB 厚度
CB_D       = 14.7   # 沉孔直径（比模块大 0.2，单边间隙 0.1）
CB_DEPTH   = 2.0    # 沉孔深度（= MIC_T + 0.4，模块凹下去 0.4）
THRU_D     = 12.4   # 通孔直径（模块边缘 r6.2~r7.25 搭在台阶上）

PIN_D      = 2.6    # 压罩定位销直径
PIN_HOLE_D = 2.4    # 板上定位孔直径（过盈 0.2）
PIN_LEN    = 3.2    # 销长（板上盲孔深 3.3）
PIN_R      = 10.5   # 销的分布半径
PIN_ANG    = [90, 210, 330]

CAP_D         = 30.0  # 压罩外径
CAP_T         = 3.0   # 压罩厚度
CAV_D         = 15.2  # 内侧空腔直径（容纳模块元件）
CAV_DEPTH     = 1.2   # 空腔深度（从贴板面往里）

SEG = 96            # 圆的离散段数
# ========================================================================


def circ(x, y, r, seg=SEG):
    return Point(x, y).buffer(r, quad_segs=seg // 4)


def polys(p):
    return list(p.geoms) if p.geom_type == "MultiPolygon" else [p]


def add_mesh(V, F, tris):
    for tri in tris:
        b = len(V)
        V.extend(tri)
        F.append([b, b + 1, b + 2])


def cap_tris(poly, z, down=False):
    """把 2D 多边形（可带孔）三角化成水平面片；down=True 时法线朝 -Z。"""
    out = []
    p = orient(poly, 1.0)
    verts, faces = trimesh.creation.triangulate_polygon(p)
    verts = np.asarray(verts)[:, :2]
    for f in np.asarray(faces):
        (x0, y0), (x1, y1), (x2, y2) = verts[f[0]], verts[f[1]], verts[f[2]]
        a = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
        idx = f[::-1] if ((a > 0) == down) else f
        out.append([(verts[i][0], verts[i][1], z) for i in idx])
    return out


def side_tris(poly, z0, z1):
    """侧壁：用第一条边判定法线朝向，保证一律指向体外（材料外侧）。"""
    out = []
    for ring in [poly.exterior] + list(poly.interiors):
        pts = list(ring.coords)[:-1]
        n = len(pts)
        px, py = pts[0]
        qx, qy = pts[1]
        dx, dy = qx - px, qy - py
        L = math.hypot(dx, dy) or 1.0
        nx, ny = dy / L, -dx / L          # 行进方向的右法线
        mx, my = (px + qx) / 2, (py + qy) / 2
        # 右法线指向多边形内部 → 该环需整体翻转
        flip = poly.covers(Point(mx + nx * 0.05, my + ny * 0.05))
        for i in range(n):
            ax, ay = pts[i]
            bx, by = pts[(i + 1) % n]
            p0, q0 = (ax, ay, z0), (bx, by, z0)
            p1, q1 = (ax, ay, z1), (bx, by, z1)
            if flip:
                out.append([p0, q1, q0])
                out.append([p0, p1, q1])
            else:
                out.append([p0, q0, q1])
                out.append([p0, q1, p1])
    return out


def build(layers, name):
    """layers = [(z0, z1, polygon), ...]，自下而上；各层轮廓可以不同。"""
    V, F = [], []
    for g in polys(layers[0][2]):
        add_mesh(V, F, cap_tris(g, layers[0][0], down=True))

    for z0, z1, poly in layers:
        for g in polys(poly):
            add_mesh(V, F, side_tris(g, z0, z1))

    # 层间接缝：下层独有 → 朝上(+Z)；上层独有(=悬垂) → 朝下(-Z)
    for i in range(len(layers) - 1):
        z = layers[i][1]
        lo, up = layers[i][2], layers[i + 1][2]
        for g in polys(lo.difference(up)):
            if g.area > 1e-6:
                add_mesh(V, F, cap_tris(g, z, down=False))
        for g in polys(up.difference(lo)):
            if g.area > 1e-6:
                add_mesh(V, F, cap_tris(g, z, down=True))

    for g in polys(layers[-1][2]):
        add_mesh(V, F, cap_tris(g, layers[-1][1], down=False))

    m = trimesh.Trimesh(vertices=np.array(V, dtype=np.float64),
                        faces=np.array(F), process=False)
    m.merge_vertices()

    # 边界边检查（只被 1 个三角形使用的边 = 破洞）
    e = np.sort(m.faces[:, [0, 1, 1, 2, 2, 0]].reshape(-1, 2), axis=1)
    _, cnt = np.unique(e, axis=0, return_counts=True)
    bad = int((cnt == 1).sum())
    if m.volume < 0:
        m.invert()
    print(f"{name:6s} tri={len(m.faces):6d}  open_edges={bad:5d}  "
          f"vol={m.volume/1000:6.2f}cm3  extents={np.round(m.extents,2)}")
    return m


# ------------------------------ 主板 ------------------------------
plate = box(-PLATE_W / 2, -PLATE_H / 2, PLATE_W / 2, PLATE_H / 2)
cb_holes, thru_holes, pin_holes = [], [], []
for (hx, hy) in HOLE_XY:
    cb_holes.append(circ(hx, hy, CB_D / 2))
    thru_holes.append(circ(hx, hy, THRU_D / 2))
    for a in PIN_ANG:
        r = math.radians(a)
        pin_holes.append(circ(hx + PIN_R * math.cos(r), hy + PIN_R * math.sin(r), PIN_HOLE_D / 2))

L0 = plate.difference(unary_union(cb_holes + pin_holes))     # z 0.0 .. 2.0  沉孔段
L1 = plate.difference(unary_union(thru_holes + pin_holes))   # z 2.0 .. 3.3  通孔 + 盲孔
L2 = plate.difference(unary_union(thru_holes))               # z 3.3 .. 4.0  通孔

plate_mesh = build([(0.0, CB_DEPTH, L0),
                    (CB_DEPTH, 3.3, L1),
                    (3.3, PLATE_T, L2)], "主板")

# ------------------------------ 压罩 ------------------------------
# z=0 外侧（贴床打印面）；z=CAP_T 内侧（贴板）；销朝 +Z 伸出
capbody = circ(0, 0, CAP_D / 2)
cav = circ(0, 0, CAV_D / 2)

C1 = capbody                                     # z 0 .. 1.8   顶盖
C2 = capbody.difference(cav)                     # z 1.8 .. 3.0 内侧空腔
C3 = unary_union([circ(PIN_R * math.cos(math.radians(a)),
                       PIN_R * math.sin(math.radians(a)), PIN_D / 2) for a in PIN_ANG])

cap_mesh = build([(0.0, CAP_T - CAV_DEPTH, C1),
                  (CAP_T - CAV_DEPTH, CAP_T, C2),
                  (CAP_T, CAP_T + PIN_LEN, C3)], "压罩")

# ------------------------------ 导出 ------------------------------
out = os.path.dirname(os.path.abspath(__file__))
plate_mesh.export(os.path.join(out, "mic_plate_v2.stl"))

caps = []
for (dx, dy) in [(-19, -19), (19, -19), (-19, 19), (19, 19)]:
    c = cap_mesh.copy()
    c.apply_translation([dx, dy, 0])
    caps.append(c)
trimesh.util.concatenate(caps).export(os.path.join(out, "mic_cap_v1.stl"))
print("exported ->", out)
