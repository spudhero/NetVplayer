#ifndef NVP_FILE_TRANSFER_H
#define NVP_FILE_TRANSFER_H
#include <stdint.h>
#include <stddef.h>
typedef struct nvp_remote nvp_remote;
typedef struct nvp_remote_cancel nvp_remote_cancel;
typedef struct {
    char *name;
    int directory, symlink;
    int64_t size, modified;
} nvp_remote_entry;
typedef struct {
    uint8_t *data;
    size_t size;
    nvp_remote_entry *entries;
    size_t count;
    uint8_t host_sha256[32];
    int listing_is_mlsd;
} nvp_remote_result;
// All session calls are serialized by the Swift owner. Cancellation alone is thread safe.
nvp_remote *nvp_remote_create(int ssh, const char *endpoint, const char *host, int port,
    const char *root, const char *username, const char *password, const uint8_t *host_sha256);
void nvp_remote_destroy(nvp_remote *remote);
nvp_remote_cancel *nvp_remote_cancel_create(void);
void nvp_remote_cancel_set(nvp_remote_cancel *flag);
void nvp_remote_cancel_destroy(nvp_remote_cancel *flag);
// operation: 0 list, 1 stat (SSH), 2 bounded read. FTP URL is already percent encoded.
// status: 0 success, 1 network, 2 auth, 3 host key, 4 missing, 5 permission,
//         6 invalid/oversized response, 7 cancelled, 8 unsupported listing.
int nvp_remote_execute(nvp_remote *remote, int operation, const char *path, const char *ftp_url,
    int64_t offset, size_t length, nvp_remote_cancel *cancel, nvp_remote_result *result);
void nvp_remote_result_free(nvp_remote_result *result);
#endif
