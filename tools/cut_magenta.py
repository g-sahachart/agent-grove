#!/usr/bin/env python3
"""ตัด sprite จากภาพพื้นสีม่วงชมพู (#FF00FF) → PNG พื้นโปร่งใส ตั้งชื่อตามลำดับการอ่าน (ซ้าย→ขวา, บน→ล่าง)

ใช้:  python3 cut_magenta.py [--grid=CxR] <ภาพ.jpeg> <โฟลเดอร์ปลายทาง> name1 name2 ...   ("-" = ข้ามชิ้นนั้น)
  --grid=CxR  ตัดตามช่องตาราง C×R ภายในกรอบที่มีภาพ (ใช้เมื่อตัวติดกันข้ามแถว หรือมีแสง/เงาแยกชิ้น)
- ลบพื้นม่วงชมพู (ขอบที่ผสมสีจะจางแบบนุ่ม), ลบเส้นตารางที่ลากยาวเกือบเต็มภาพ
- แยกชิ้นจากรูปร่างจริง (ไม่ตัดตามช่อง เพราะบางตัวล้นช่อง), ทิ้งจุดเล็กๆ
- ย่อทุกชิ้นด้วยอัตราเดียวกัน → ขนาดเทียบกันได้ภายในภาพเดียว
"""
import sys, os
from collections import deque
from PIL import Image, ImageChops, ImageFilter

SCALE = 0.35          # ย่อผลลัพธ์
BLOCK = 4             # แยกชิ้นบนตารางหยาบ 4px (เร็ว)

def key(im):
    r, g, b = im.split()
    m = ImageChops.subtract(ImageChops.darker(r, b), g)          # "ความม่วงชมพู" = min(R,B) - G
    alpha = m.point(lambda v: 255 if v <= 45 else 0 if v >= 100 else int(255 * (100 - v) / 55))
    # เส้นตาราง: แถว/คอลัมน์ที่ทึบเกือบตลอดแนว
    # ตัวสัตว์ที่เรียงตรงกันหลายแถวจะทึบทั้งแถบ ไม่ถูกนับเป็นเส้น
    w, h = im.size
    rows = alpha.resize((1, h), Image.BOX).tobytes()
    cols = alpha.resize((w, 1), Image.BOX).tobytes()
    def thin(cov, i):   # เส้นหนาทึบเต็มแนว (> 97%) หรือเส้นบาง (> 90% และข้างๆ โปร่ง)
        return cov[i] > 247 or (cov[i] > 230 and cov[max(0, i - 6)] < 150 and cov[min(len(cov) - 1, i + 6)] < 150)
    px = alpha.load()
    for y in range(h):
        if thin(rows, y):
            for x in range(w): px[x, y] = 0
    for x in range(w):
        if thin(cols, x):
            for y in range(h): px[x, y] = 0
    return alpha

def components(alpha):
    w, h = alpha.size
    bw, bh = w // BLOCK, h // BLOCK
    small = alpha.resize((bw, bh), Image.BOX).point(lambda v: 255 if v > 60 else 0)
    grown = small.filter(ImageFilter.MaxFilter(3))                 # รวมชิ้นส่วนที่อยู่ใกล้กัน (หาง/ปีก/ประกาย)
    g, s = grown.tobytes(), small.tobytes()
    seen = bytearray(bw * bh); comps = []
    for start in range(bw * bh):
        if not g[start] or seen[start]: continue
        q = deque([start]); seen[start] = 1; cells = []
        while q:
            i = q.popleft(); cells.append(i); x, y = i % bw, i // bw
            for j in (i - 1 if x else -1, i + 1 if x < bw - 1 else -1, i - bw, i + bw):
                if 0 <= j < bw * bh and g[j] and not seen[j]: seen[j] = 1; q.append(j)
        solid = sum(1 for i in cells if s[i])
        if solid < bw * bh * 0.0015: continue                        # จุดเล็กๆ
        xs = [i % bw for i in cells]; ys = [i // bw for i in cells]
        comps.append(dict(cells=cells, box=(min(xs), min(ys), max(xs) + 1, max(ys) + 1),
                          cy=sum(ys) / len(ys), cx=sum(xs) / len(xs)))
    return comps, (bw, bh)

def grid_cells(alpha, cols, rows):
    """แบ่งกรอบที่มีภาพเป็น cols×rows ช่อง แต่ละช่อง = 1 ชิ้น (ไม่สนว่าติดกันหรือไม่)"""
    w, h = alpha.size
    bw, bh = w // BLOCK, h // BLOCK
    s = alpha.resize((bw, bh), Image.BOX).point(lambda v: 255 if v > 60 else 0)
    x0, y0, x1, y1 = s.getbbox()
    data = s.tobytes(); comps = []
    for r in range(rows):
        for c in range(cols):
            inset = 3   # 12px: กันเศษเส้นตารางที่ขอบช่อง
            cx0, cx1 = x0 + (x1 - x0) * c // cols + inset, x0 + (x1 - x0) * (c + 1) // cols - inset
            cy0, cy1 = y0 + (y1 - y0) * r // rows + inset, y0 + (y1 - y0) * (r + 1) // rows - inset
            cells = [y * bw + x for y in range(cy0, cy1) for x in range(cx0, cx1) if data[y * bw + x]]
            if not cells: comps.append(None); continue
            xs = [i % bw for i in cells]; ys = [i // bw for i in cells]
            comps.append(dict(cells=cells, box=(min(xs), min(ys), max(xs) + 1, max(ys) + 1)))
    return comps, (bw, bh)

def reading_order(comps):
    comps.sort(key=lambda c: c['cy'])
    heights = sorted(c['box'][3] - c['box'][1] for c in comps)
    gap = heights[len(heights) // 2] * 0.45
    rows, cur = [], []
    for c in comps:
        if cur and c['cy'] - cur[-1]['cy'] > gap: rows.append(cur); cur = []
        cur.append(c)
    if cur: rows.append(cur)
    return [c for r in rows for c in sorted(r, key=lambda c: c['cx'])], [len(r) for r in rows]

def main():
    args = sys.argv[1:]
    grid = next((a.split('=')[1] for a in args if a.startswith('--grid=')), None)
    args = [a for a in args if not a.startswith('--grid=')]
    src, out, names = args[0], args[1], args[2:]
    os.makedirs(out, exist_ok=True)
    im = Image.open(src).convert('RGB')
    alpha = key(im)
    if grid:
        gc, gr = map(int, grid.split('x'))
        comps, (bw, bh) = grid_cells(alpha, gc, gr); rows = [gc] * gr
    else:
        comps, (bw, bh) = components(alpha)
        comps, rows = reading_order(comps)
    if len(comps) != len(names):
        print(f"!! {os.path.basename(src)}: เจอ {len(comps)} ชิ้น (แถวละ {rows}) แต่ให้ชื่อมา {len(names)}"); sys.exit(1)
    rgba = im.copy(); rgba.putalpha(alpha)
    for c, name in zip(comps, names):
        if name == '-' or c is None: continue
        x0, y0, x1, y1 = c['box']
        # เฉพาะพื้นที่ของชิ้นนี้ (กันส่วนของตัวข้างๆ ที่ล้นเข้ามาในกรอบ)
        m = Image.new('L', (x1 - x0, y1 - y0), 0); mp = m.load()
        for i in c['cells']: mp[i % bw - x0, i // bw - y0] = 255
        m = m.resize(((x1 - x0) * BLOCK, (y1 - y0) * BLOCK), Image.NEAREST)
        piece = rgba.crop((x0 * BLOCK, y0 * BLOCK, x1 * BLOCK, y1 * BLOCK))
        piece.putalpha(ImageChops.multiply(piece.getchannel('A'), m))
        piece = piece.crop(piece.getbbox())
        piece = piece.resize((max(1, round(piece.width * SCALE)), max(1, round(piece.height * SCALE))), Image.LANCZOS)
        piece.save(os.path.join(out, name + '.png'), optimize=True)
    print(f"ok {os.path.basename(src)}: {len(comps)} ชิ้น (แถวละ {rows})")

main()
