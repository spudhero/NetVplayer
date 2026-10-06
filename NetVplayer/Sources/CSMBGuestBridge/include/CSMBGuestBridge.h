#pragma once
#include <stdint.h>
typedef struct NVSMBGuest NVSMBGuest;
typedef struct {
    uint32_t kind;
    uint64_t size;
    uint64_t modified_seconds;
    uint64_t modified_nanoseconds;
} NVSMBGuestStat;
NVSMBGuest *nv_smb_guest_create(void);
int nv_smb_guest_connect(NVSMBGuest *, const char *server, const char *share, const char *domain);
void nv_smb_guest_destroy(NVSMBGuest *);
const char *nv_smb_guest_error(NVSMBGuest *);
void *nv_smb_guest_opendir(NVSMBGuest *, const char *path);
const char *nv_smb_guest_readdir(NVSMBGuest *, void *dir, NVSMBGuestStat *);
void nv_smb_guest_closedir(NVSMBGuest *, void *dir);
int nv_smb_guest_stat(NVSMBGuest *, const char *path, NVSMBGuestStat *);
int nv_smb_guest_read(NVSMBGuest *, const char *path, uint8_t *bytes, uint32_t count, uint64_t offset);
