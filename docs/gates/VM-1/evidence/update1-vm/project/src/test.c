#include <stdio.h>
int add(int, int);
int main(void) { if (add(2, 3) != 5) { puts("FAIL add"); return 1; } puts("PASS add"); return 0; }
