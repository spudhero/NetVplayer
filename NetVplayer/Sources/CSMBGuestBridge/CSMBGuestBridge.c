#include "CSMBGuestBridge.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <time.h>
#include "vendor/smb2/smb2.h"
#include "vendor/smb2/libsmb2.h"

struct NVSMBGuest { struct smb2_context *context; char error[1024]; };
NVSMBGuest *nv_smb_guest_create(void) { return calloc(1, sizeof(NVSMBGuest)); }
static void save_error(NVSMBGuest *guest) {
    const char *error = smb2_get_error(guest->context);
    snprintf(guest->error, sizeof(guest->error), "%s", error ? error : "SMB guest connection failed");
}
int nv_smb_guest_connect(NVSMBGuest *guest, const char *server, const char *share, const char *domain) {
    enum smb2_negotiate_version versions[] = {SMB2_VERSION_0302, SMB2_VERSION_0210};
    int result = -1;
    for (int i = 0; i < 2; i++) {
        if (guest->context) smb2_destroy_context(guest->context);
        guest->context = smb2_init_context();
        if (!guest->context) return -1;
        smb2_set_version(guest->context, versions[i]);
        smb2_set_security_mode(guest->context, 0);
        smb2_set_authentication(guest->context, SMB2_SEC_NTLMSSP);
        smb2_set_timeout(guest->context, 10);
        smb2_set_user(guest->context, "guest"); smb2_set_password(guest->context, "");
        smb2_set_domain(guest->context, domain);
        result = smb2_connect_share(guest->context, server, share, "guest");
        if (!result) return 0;
        save_error(guest);
    }
    return result;
}
void nv_smb_guest_destroy(NVSMBGuest *guest) {
    if (!guest) return;
    if (guest->context) { smb2_disconnect_share(guest->context); smb2_destroy_context(guest->context); }
    free(guest);
}
const char *nv_smb_guest_error(NVSMBGuest *guest) { return guest->error; }
static void copy_stat(NVSMBGuestStat *out, const struct smb2_stat_64 *info) {
    out->kind = info->smb2_type; out->size = info->smb2_size;
    out->modified_seconds = info->smb2_mtime; out->modified_nanoseconds = info->smb2_mtime_nsec;
}
void *nv_smb_guest_opendir(NVSMBGuest *guest, const char *path) {
    struct smb2dir *dir = smb2_opendir(guest->context, path);
    if (!dir) save_error(guest);
    return dir;
}
const char *nv_smb_guest_readdir(NVSMBGuest *guest, void *dir, NVSMBGuestStat *out) {
    struct smb2dirent *item = smb2_readdir(guest->context, dir);
    if (!item) return NULL;
    copy_stat(out, &item->st); return item->name;
}
void nv_smb_guest_closedir(NVSMBGuest *guest, void *dir) { smb2_closedir(guest->context, dir); }
int nv_smb_guest_stat(NVSMBGuest *guest, const char *path, NVSMBGuestStat *out) {
    struct smb2_stat_64 info;
    int result = smb2_stat(guest->context, path, &info);
    if (!result) copy_stat(out, &info); else save_error(guest);
    return result;
}
int nv_smb_guest_read(NVSMBGuest *guest, const char *path, uint8_t *bytes, uint32_t count, uint64_t offset) {
    struct smb2fh *file = smb2_open(guest->context, path, O_RDONLY);
    if (!file) { save_error(guest); return -1; }
    uint32_t maximum = smb2_get_max_read_size(guest->context), done = 0;
    if (!maximum) maximum = 65536;
    int result = 0;
    while (done < count) {
        uint32_t next = count - done; if (next > maximum) next = maximum;
        result = smb2_pread(guest->context, file, bytes + done, next, offset + done);
        if (result <= 0) break;
        done += (uint32_t)result;
    }
    if (result < 0) save_error(guest);
    smb2_close(guest->context, file);
    return result < 0 ? result : (int)done;
}
