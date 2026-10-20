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

# ── โหมดสุนัข (Sprites/dogs) ── ใส่ชื่อไฟล์ภาพแต่ละชุดแล้วเอา # ออก
# DOGS=$OUT/dogs
# animals_to() { local f=$1 out=$2; shift 2; local names=(); for a in "$@"; do for p in $P; do names+=("${a}_$p"); done; done; python3 cut_magenta.py "$DL/$f" "$out" $names; }
# animals_to <ชุด1.jpeg> $DOGS shiba corgi golden labrador
# animals_to <ชุด2.jpeg> $DOGS husky shepherd bordercollie samoyed
# animals_to <ชุด3.jpeg> $DOGS pug frenchie bulldog bostonterrier
# animals_to <ชุด4.jpeg> $DOGS chihuahua pomeranian yorkie maltese
# animals_to <ชุด5.jpeg> $DOGS dachshund beagle jackrussell basset
# animals_to <ชุด6.jpeg> $DOGS poodle bichon shihtzu cavalier
# animals_to <ชุด7.jpeg> $DOGS dalmatian doberman greatdane stbernard
# animals_to <ชุด8.jpeg> $DOGS akita chowchow thairidgeback bangkaew
# python3 cut_magenta.py "$DL/<ลูกหมา.jpeg>" $DOGS $(for p in stand walk walk2; do for b in shiba corgi golden husky pug dalmatian; do echo baby_${b}_$p; done; done)
