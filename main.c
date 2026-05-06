#include "stdio.h"
#include "math.h"

extern int mprintf(const char *fmt, ...);

int main() 
{
    mprintf("%x  %o  %b\n", 0xDEAD, 34535, 23);

    mprintf("%s: %x%%\n","Ded_32", 0xded32);

    mprintf("%d %d %d %d %d %d %d \n", 1, 1, 1, 1, 1, 1, 1);

    mprintf("HELLO %d %d %d %d %d %d %d %d %d %d\n %d %s %x %d%c%b\n", 1, 2, 3, 4, 5,
                                                     6, 7, 8, -9, -10, -1, "love", 3802, 100, 33, 126);
    mprintf("\nHello\n");
}

