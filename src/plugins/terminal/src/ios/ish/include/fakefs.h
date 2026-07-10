#ifndef ACODE_ISH_FAKEFS_H
#define ACODE_ISH_FAKEFS_H

#include <stdbool.h>

struct fakefsify_error {
    int line;
    enum { ERR_ARCHIVE, ERR_SQLITE, ERR_POSIX, ERR_CANCELLED } type;
    int code;
    char *message;
};

struct progress {
    void *cookie;
    void (*callback)(void *cookie, double progress, const char *message, bool *cancel_out);
};

bool fakefs_import(const char *archive_path, const char *fs, struct fakefsify_error *err_out, struct progress progress);
bool fakefs_import_directory(const char *source_path, const char *fs, struct fakefsify_error *err_out, struct progress progress);

#endif
