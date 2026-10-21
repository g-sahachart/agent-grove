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

# ภาพที่ Gemini วาดหันซ้าย → กลับให้หันขวา (แอปถือว่าภาพหันขวา แล้วพลิกเองตามทิศที่เดิน)
python3 -c 'import sys; from PIL import Image, ImageOps
for f in sys.argv[1:]: ImageOps.mirror(Image.open(f)).save(f)' \
  "$DOGS"/{bordercollie,husky,shepherd}_stand.png "$DOGS"/{akita,chowchow,shiba,thairidgeback}_walk2.png \
  "$OUT"/{beaver,cheetah,fox,lion,cat,crocodile,dog,leopard,otter,raccoon,redpanda,seal,turtle,wolf,zebra}_stand.png \
  "$OUT"/{cat,crocodile,dog,frog,giraffe,leopard,otter,raccoon,redpanda,seal,turtle,wolf,zebra,axolotl,hamster}_walk.png \
  "$OUT"/{swan,shark,koala,penguin}_walk2.png "$OUT"/{eagle,parrot}_{stand,walk,walk2,sit,sleep,alert}.png
