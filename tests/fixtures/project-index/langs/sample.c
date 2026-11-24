#include <stdio.h>
#define MAX_ITEMS 16
struct point { int x; int y; };
typedef struct point point_t;
enum color { RED, GREEN };
static int counter = 0;
int add(int a, int b);
int add(int a, int b) { int local = a; return local + b; }
/* int fake(void) { } */
