ASM_SRC="mprintf.s"
C_SRC="main.c"
OUT="main"

nasm -f elf64 "$ASM_SRC" -o mprintf.o
gcc -O0 -fPIE -pie "$C_SRC" mprintf.o -o "$OUT"

echo "Built: $OUT"
echo "Run with: ./$OUT"
