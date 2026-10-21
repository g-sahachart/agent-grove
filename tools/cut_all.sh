#!/bin/zsh
# ตัดภาพชุด Gemini ทั้งหมด → Sprites/  (ลำดับชื่อ = ลำดับการอ่านในภาพ)
# ไม่ใช้ set -e: ให้รันครบทุกไฟล์แล้วดูว่าไฟล์ไหนไม่ผ่าน
cd "${0:A:h}"
DL=~/Downloads; OUT=${1:-../Sprites}
P=(stand walk walk2 sit sleep alert)
animals() { local f=$1; shift; local names=(); for a in "$@"; do for p in $P; do names+=("${a}_$p"); done; done; python3 cut_magenta.py "$DL/$f" "$OUT" $names; }

animals Gemini_Generated_Image_gzvn01gzvn01gzvn.jpeg cat dog fox wolf
animals Gemini_Generated_Image_aggmsuaggmsuaggm.jpeg raccoon redpanda panda koala
animals Gemini_Generated_Image_dyvia3dyvia3dyvi.jpeg bear polarbear lion tiger
animals Gemini_Generated_Image_3bvsi73bvsi73bvs.jpeg leopard cheetah zebra giraffe
animals Gemini_Generated_Image_gv64f3gv64f3gv64.jpeg elephant hippo rhino monkey
animals Gemini_Generated_Image_125g2u125g2u125g.jpeg gorilla sloth kangaroo deer
animals Gemini_Generated_Image_ls1h25ls1h25ls1h.jpeg rabbit hamster mouse squirrel
animals Gemini_Generated_Image_pagxerpagxerpagx.jpeg hedgehog otter beaver capybara
animals Gemini_Generated_Image_4uohm54uohm54uoh.jpeg penguin owl chicken duck
animals Gemini_Generated_Image_sgx1gvsgx1gvsgx1.jpeg parrot flamingo eagle swan
animals Gemini_Generated_Image_cjyg2ycjyg2ycjyg.jpeg seal octopus snake shark
# กบ/เต่า/จระเข้: ช่องที่ Gemini วาดเป็นกบแทน → ข้าม
python3 cut_magenta.py "$DL/Gemini_Generated_Image_mibhpbmibhpbmibh.jpeg" "$OUT" \
  frog_{stand,walk,walk2,sit,sleep,alert} turtle_stand turtle_walk turtle_walk2 - turtle_sleep - \
  crocodile_stand crocodile_walk crocodile_walk2 crocodile_sit crocodile_sleep - axolotl_{stand,walk,walk2,sit,sleep,alert}
# ตัวเล็ก (subagent): 6 ตัว × (ยืน, เดิน, เดิน2) เรียงเป็นแถวตามท่า
BABY=(chick duckling bunny mouse hoglet penguin)
python3 cut_magenta.py --grid=6x3 "$DL/Gemini_Generated_Image_rp20xprp20xprp20 (1).jpeg" "$OUT" \
  $(for p in stand walk walk2; do for b in $BABY; do echo baby_${b}_$p; done; done)
python3 cut_magenta.py "$DL/Gemini_Generated_Image_rp20xprp20xprp20 (2).jpeg" "$OUT" \
  table_mid table_left table_right chair_front chair_back laptop papers mug whiteboard tv watercooler plant_office
python3 cut_magenta.py --grid=4x3 "$DL/Gemini_Generated_Image_rp20xprp20xprp20 (3).jpeg" "$OUT" \
  sofa_orange sofa_blue beanbag coffee_table rug bookshelf lamp tv_cabinet window picture console plant_big
python3 cut_magenta.py "$DL/Gemini_Generated_Image_rp20xprp20xprp20 (4).jpeg" "$OUT" \
  item_laptop item_book item_magnifier item_toolbox item_clipboard item_globe item_terminal item_pencil item_folder item_plug item_robot item_bulb

# ── โหมดสุนัข (Sprites/dogs) ── "-" = ช่องที่ Gemini วาดผิด (เป็นสายพันธุ์อื่น/ท่าผิด) → ข้าม ใช้ท่ายืนแทน
DOGS=$OUT/dogs
dogs() { local f=$1; shift; python3 cut_magenta.py "$DL/$f" "$DOGS" "$@"; }
d6() { for p in $P; do echo "${1}_$p"; done; }
dogs Gemini_Generated_Image_9ck11r9ck11r9ck1.jpeg $(d6 shiba) $(d6 corgi) $(d6 golden) $(d6 labrador)
dogs Gemini_Generated_Image_vgtlt1vgtlt1vgtl.jpeg $(d6 husky) $(d6 shepherd) $(d6 bordercollie) $(d6 samoyed)
dogs Gemini_Generated_Image_sa58j8sa58j8sa58.jpeg $(d6 pug) frenchie_{stand,walk,walk2,sit} - frenchie_alert $(d6 bulldog) $(d6 bostonterrier)
dogs Gemini_Generated_Image_ify7yfify7yfify7.jpeg $(d6 chihuahua) pomeranian_{stand,walk,walk2} - pomeranian_sleep - \
  yorkie_{stand,walk,walk2,sit,sleep} - $(d6 maltese)
dogs Gemini_Generated_Image_prom7vprom7vprom.jpeg $(d6 dachshund) $(d6 beagle) $(d6 jackrussell) $(d6 basset)
dogs Gemini_Generated_Image_r0tv76r0tv76r0tv.jpeg $(d6 poodle) $(d6 bichon) $(d6 shihtzu) $(d6 cavalier)
dogs Gemini_Generated_Image_ope9neope9neope9.jpeg $(d6 dalmatian) $(d6 doberman) greatdane_{stand,walk} - - greatdane_sleep - $(d6 stbernard)
dogs Gemini_Generated_Image_5thkgo5thkgo5thk.jpeg $(d6 akita) chowchow_{stand,walk,walk2,sit,sleep} - $(d6 thairidgeback) $(d6 bangkaew)
# ลูกหมา (subagent): 8 คอลัมน์ × 3 แถว (ยืน, เดิน, เดิน2) — คอลัมน์ 3 กับ 7 ซ้ำ (คอร์กี้/ปั๊ก) → ข้าม
PUPS=(shiba corgi - golden husky pug - dalmatian)
python3 cut_magenta.py --grid=8x3 "$DL/Gemini_Generated_Image_3m9c3x3m9c3x3m9c.jpeg" "$DOGS" \
  $(for p in stand walk walk2; do for b in $PUPS; do [[ $b == - ]] && printf "%s\n" - || echo baby_${b}_$p; done; done)

# 🚀 อวกาศ: ภาพรวม (โดรน 6×3 + เฟอร์นิเจอร์ 3 กลุ่มขนาดไม่เท่ากัน) → แบ่งเป็นส่วนก่อน แล้วตัดทีละส่วน
SPACE=$OUT/space; TMP=$(mktemp -d)
python3 -c 'import sys; from PIL import Image
im = Image.open(sys.argv[1]); k = im.width / 2000
for n, b in {"drones": (50, 58, 998, 548), "furn1": (1002, 58, 1952, 548), "furn2": (48, 566, 1952, 810), "furn3": (48, 834, 1952, 1060)}.items():
    im.crop(tuple(round(v * k) for v in b)).save(f"{sys.argv[2]}/{n}.png")' "$DL/Gemini_Generated_Image_mbz74embz74embz7.jpeg" "$TMP"
python3 cut_magenta.py "$TMP/furn1.png" "$SPACE" sofa_orange sofa_blue window tv_cabinet
python3 cut_magenta.py "$TMP/furn2.png" "$SPACE" - beanbag bookshelf - - chair_back chair_front
python3 cut_magenta.py "$TMP/furn3.png" "$SPACE" table_left table_mid table_right tv plant_big console whiteboard watercooler
python3 cut_magenta.py --grid=6x3 "$TMP/drones.png" "$SPACE" \
  $(for p in stand walk walk2; do for b in drone ballbot satellite alien catbot core; do echo baby_${b}_$p; done; done)
# หุ่นยนต์ 8 คอลัมน์: ยืน, ยืนยิ้ม(ข้าม), เดิน, เดิน2, นั่ง, ชาร์จ, ปิดเครื่อง(ข้าม), ตกใจ — catbot/alien ช่องชาร์จวาดผิด → ข้าม
python3 cut_magenta.py --grid=8x4 "$DL/Gemini_Generated_Image_bzgtolbzgtolbzgt.jpeg" "$SPACE" \
  ballbot_stand - ballbot_walk ballbot_walk2 ballbot_sit ballbot_sleep - ballbot_alert \
  tvbot_stand - tvbot_walk tvbot_walk2 tvbot_sit tvbot_sleep - tvbot_alert \
  catbot_stand - catbot_walk catbot_walk2 catbot_sit - - catbot_alert \
  alien_stand - alien_walk alien_walk2 alien_sit - - alien_alert
python3 cut_magenta.py --grid=4x3 "$DL/Gemini_Generated_Image_8qjyxk8qjyxk8qjy.jpeg" "$SPACE" item_terminal item_book item_magnifier \
  item_toolbox item_folder item_bulb item_radar item_spinner item_battery item_alarm item_mug item_globe
python3 -c 'import sys; from PIL import Image
Image.open(sys.argv[1]).convert("RGB").resize((1600, 893), Image.LANCZOS).save(sys.argv[2], quality=88)' \
  "$DL/Gemini_Generated_Image_10haoa10haoa10ha.jpeg" "$SPACE/background.jpg"
# ชิ้นที่ใช้ภาพเดียวกัน (ชื่อตามของเดิมในฉาก)
for pair in plant_big:plant_office whiteboard:picture watercooler:lamp item_mug:mug item_terminal:laptop item_folder:papers; do
  cp "$SPACE/${pair%%:*}.png" "$SPACE/${pair##*:}.png"
done
rm -r "${TMP:?}"

# ภาพที่ Gemini วาดหันซ้าย → กลับให้หันขวา (แอปถือว่าภาพหันขวา แล้วพลิกเองตามทิศที่เดิน)
python3 -c 'import sys; from PIL import Image, ImageOps
for f in sys.argv[1:]: ImageOps.mirror(Image.open(f)).save(f)' \
  "$DOGS"/{bordercollie,husky,shepherd}_stand.png "$DOGS"/{akita,chowchow,shiba,thairidgeback}_walk2.png \
  "$OUT"/{beaver,cheetah,fox,lion,cat,crocodile,dog,leopard,otter,raccoon,redpanda,seal,turtle,wolf,zebra}_stand.png \
  "$OUT"/{cat,crocodile,dog,frog,giraffe,leopard,otter,raccoon,redpanda,seal,turtle,wolf,zebra,axolotl,hamster}_walk.png \
  "$OUT"/{swan,shark,koala,penguin}_walk2.png "$OUT"/{eagle,parrot}_{stand,walk,walk2,sit,sleep,alert}.png
