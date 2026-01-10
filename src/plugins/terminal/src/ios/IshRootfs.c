#include "IshRootfs.h"
#include <stdlib.h>
#include <string.h>

static char *ish_root_path = NULL;

void IshSetRootPath(const char *path) {
    if (!path) {
        return;
    }
    free(ish_root_path);
    ish_root_path = strdup(path);
}

__attribute__((weak)) const char *DefaultRootPath(void) {
    return ish_root_path ? ish_root_path : "";
}

__attribute__((weak)) void ReportPanic(const char *message) {
    (void)message;
}
