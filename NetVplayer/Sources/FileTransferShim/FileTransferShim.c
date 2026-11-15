#include "FileTransferShim.h"
#include <curl/curl.h>
#include <libssh2.h>
#include <libssh2_sftp.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <netdb.h>
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>

#define NVP_MAX_READ (4 * 1024 * 1024)
#define NVP_MAX_LIST (8 * 1024 * 1024)
#define NVP_MAX_ENTRIES 20000
struct nvp_remote_cancel { atomic_int cancelled; };
struct nvp_remote {
    int ssh, port, socket, pinned;
    char *endpoint, *host, *root, *username, *password;
    uint8_t fingerprint[32];
    char canonical_root[4096];
    CURL *curl;
    LIBSSH2_SESSION *session;
    LIBSSH2_SFTP *sftp;
};
static pthread_once_t initialization = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); libssh2_init(0); }
static int cancelled(nvp_remote_cancel *c) { return c && atomic_load(&c->cancelled); }
nvp_remote_cancel *nvp_remote_cancel_create(void) {
    nvp_remote_cancel *c = calloc(1, sizeof(*c));
    if(c) atomic_init(&c->cancelled, 0);
    return c;
}
void nvp_remote_cancel_set(nvp_remote_cancel *c) { if(c) atomic_store(&c->cancelled, 1); }
void nvp_remote_cancel_destroy(nvp_remote_cancel *c) { free(c); }

nvp_remote *nvp_remote_create(int ssh, const char *endpoint, const char *host, int port,
    const char *root, const char *username, const char *password, const uint8_t *fingerprint) {
    pthread_once(&initialization, initialize);
    nvp_remote *r = calloc(1, sizeof(*r));
    if(!r) return NULL;
    r->ssh = ssh; r->port = port; r->socket = -1;
    r->endpoint = strdup(endpoint); r->host = strdup(host); r->root = strdup(root);
    r->username = strdup(username); r->password = strdup(password);
    if(fingerprint) { memcpy(r->fingerprint, fingerprint, 32); r->pinned = 1; }
    if(!r->endpoint || !r->host || !r->root || !r->username || !r->password) { nvp_remote_destroy(r); return NULL; }
    if(!ssh) r->curl = curl_easy_init();
    if(!ssh && !r->curl) { nvp_remote_destroy(r); return NULL; }
    return r;
}
static void close_ssh(nvp_remote *r) {
    // Closing the socket first makes cleanup bounded even after a dropped peer.
    if(r->socket >= 0) { shutdown(r->socket, SHUT_RDWR); close(r->socket); r->socket = -1; }
    if(r->sftp) { libssh2_sftp_shutdown(r->sftp); r->sftp = NULL; }
    if(r->session) { libssh2_session_free(r->session); r->session = NULL; }
    r->canonical_root[0] = 0;
}
void nvp_remote_destroy(nvp_remote *r) {
    if(!r) return;
    close_ssh(r);
    if(r->curl) curl_easy_cleanup(r->curl);
    if(r->password) { memset(r->password, 0, strlen(r->password)); free(r->password); }
    free(r->endpoint); free(r->host); free(r->root); free(r->username); free(r);
}
void nvp_remote_result_free(nvp_remote_result *result) {
    free(result->data);
    for(size_t i = 0; i < result->count; i++) free(result->entries[i].name);
    free(result->entries); memset(result, 0, sizeof(*result));
}
static int ssh_error(nvp_remote *r) {
    unsigned long code = r->sftp ? libssh2_sftp_last_error(r->sftp) : 0;
    if(code == LIBSSH2_FX_NO_SUCH_FILE || code == LIBSSH2_FX_NO_SUCH_PATH) return 4;
    if(code == LIBSSH2_FX_PERMISSION_DENIED) return 5;
    return 1;
}
static int connect_socket(nvp_remote *r, nvp_remote_cancel *cancel) {
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    char port[8]; snprintf(port, sizeof(port), "%d", r->port);
    if(getaddrinfo(r->host, port, &hints, &addresses)) return 1;
    for(struct addrinfo *a = addresses; a && !cancelled(cancel); a = a->ai_next) {
        int fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if(fd < 0) continue;
        int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        int flags = fcntl(fd, F_GETFL, 0); fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        int rc = connect(fd, a->ai_addr, a->ai_addrlen);
        if(rc != 0 && errno == EINPROGRESS) {
            for(int i = 0; i < 100 && !cancelled(cancel); i++) {
                struct pollfd p = { fd, POLLOUT, 0 };
                rc = poll(&p, 1, 100);
                if(rc > 0) { int error = 0; socklen_t size = sizeof(error); getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size); rc = error ? -1 : 0; break; }
                if(rc < 0) break;
                rc = -1;
            }
        }
        if(rc == 0 && !cancelled(cancel)) { fcntl(fd, F_SETFL, flags); r->socket = fd; break; }
        close(fd);
    }
    freeaddrinfo(addresses);
    return cancelled(cancel) ? 7 : r->socket < 0 ? 1 : 0;
}
static int ensure_ssh(nvp_remote *r, nvp_remote_cancel *cancel, nvp_remote_result *out) {
    if(r->sftp) return 0;
    int status = connect_socket(r, cancel);
    if(status) return status;
    r->session = libssh2_session_init();
    if(!r->session) { close_ssh(r); return 1; }
    libssh2_session_set_blocking(r->session, 1);
    libssh2_session_set_timeout(r->session, 10000);
    if(libssh2_session_handshake(r->session, r->socket)) { close_ssh(r); return 1; }
    const char *hash = libssh2_hostkey_hash(r->session, LIBSSH2_HOSTKEY_HASH_SHA256);
    if(hash) memcpy(out->host_sha256, hash, 32);
    if(!hash || !r->pinned || memcmp(hash, r->fingerprint, 32)) { close_ssh(r); return 3; }
    if(cancelled(cancel)) { close_ssh(r); return 7; }
    if(libssh2_userauth_password(r->session, r->username, r->password)) { close_ssh(r); return 2; }
    r->sftp = libssh2_sftp_init(r->session);
    if(!r->sftp) { close_ssh(r); return 1; }
    int length = libssh2_sftp_realpath(r->sftp, r->root, r->canonical_root, sizeof(r->canonical_root) - 1);
    if(length <= 0) { status = ssh_error(r); close_ssh(r); return status; }
    r->canonical_root[length] = 0;
    return 0;
}
static int append_entry(nvp_remote_result *out, const char *name, const LIBSSH2_SFTP_ATTRIBUTES *a) {
    size_t name_size = strlen(name) + 1;
    if(out->count >= NVP_MAX_ENTRIES || a->filesize > INT64_MAX ||
       name_size + sizeof(nvp_remote_entry) > NVP_MAX_LIST - out->size) return 6;
    nvp_remote_entry *entries = realloc(out->entries, (out->count + 1) * sizeof(*entries));
    if(!entries) return 6;
    out->entries = entries;
    nvp_remote_entry *entry = &entries[out->count]; memset(entry, 0, sizeof(*entry));
    entry->name = strdup(name); if(!entry->name) return 6;
    entry->directory = (a->flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) && LIBSSH2_SFTP_S_ISDIR(a->permissions);
    entry->symlink = (a->flags & LIBSSH2_SFTP_ATTR_PERMISSIONS) && LIBSSH2_SFTP_S_ISLNK(a->permissions);
    entry->size = a->flags & LIBSSH2_SFTP_ATTR_SIZE ? (int64_t)a->filesize : 0;
    entry->modified = a->flags & LIBSSH2_SFTP_ATTR_ACMODTIME ? (int64_t)a->mtime : 0;
    out->count++; out->size += name_size + sizeof(nvp_remote_entry); return 0;
}
static int ssh_execute(nvp_remote *r, int operation, const char *path, int64_t offset, size_t length,
    nvp_remote_cancel *cancel, nvp_remote_result *out) {
    int status = ensure_ssh(r, cancel, out);
    if(status) return status;
    char canonical[4096];
    int count = libssh2_sftp_realpath(r->sftp, path, canonical, sizeof(canonical) - 1);
    if(count <= 0) return ssh_error(r);
    canonical[count] = 0;
    size_t root_length = strlen(r->canonical_root);
    if(strcmp(r->canonical_root, "/") && (strncmp(canonical, r->canonical_root, root_length) ||
       (canonical[root_length] && canonical[root_length] != '/'))) return 5;
    if(operation == 1) {
        LIBSSH2_SFTP_ATTRIBUTES attributes = {0};
        if(libssh2_sftp_lstat(r->sftp, path, &attributes)) return ssh_error(r);
        return append_entry(out, "", &attributes);
    }
    LIBSSH2_SFTP_HANDLE *handle = operation == 0 ? libssh2_sftp_opendir(r->sftp, path)
        : libssh2_sftp_open(r->sftp, path, LIBSSH2_FXF_READ, 0);
    if(!handle) return ssh_error(r);
    if(operation == 0) {
        while(!cancelled(cancel)) {
            char name[4096]; LIBSSH2_SFTP_ATTRIBUTES attributes = {0};
            int size = libssh2_sftp_readdir(handle, name, sizeof(name) - 1, &attributes);
            if(size == 0) break;
            if(size < 0) { status = ssh_error(r); break; }
            name[size] = 0;
            if(!strcmp(name, ".") || !strcmp(name, "..")) continue;
            if(strchr(name, '/') || strlen(name) != (size_t)size) { status = 6; break; }
            status = append_entry(out, name, &attributes); if(status) break;
        }
    } else {
        out->data = malloc(length ? length : 1);
        if(!out->data) status = 6;
        else {
            libssh2_sftp_seek64(handle, (uint64_t)offset);
            while(out->size < length && !cancelled(cancel)) {
                ssize_t size = libssh2_sftp_read(handle, (char *)out->data + out->size, length - out->size);
                if(size == 0) break;
                if(size < 0) { status = ssh_error(r); break; }
                out->size += (size_t)size;
            }
        }
    }
    libssh2_sftp_close(handle);
    if(cancelled(cancel)) status = 7;
    if(status == 1 || status == 7) close_ssh(r);
    return status;
}
typedef struct { nvp_remote_result *out; size_t limit; nvp_remote_cancel *cancel; } ftp_buffer;
static size_t ftp_write(char *data, size_t size, size_t count, void *context) {
    ftp_buffer *b = context;
    if(size && count > SIZE_MAX / size) return 0;
    size_t bytes = size * count;
    if(cancelled(b->cancel) || bytes > b->limit - b->out->size) return 0;
    uint8_t *next = realloc(b->out->data, b->out->size + bytes + 1);
    if(!next) return 0;
    b->out->data = next; memcpy(next + b->out->size, data, bytes); b->out->size += bytes;
    return bytes;
}
static int ftp_progress(void *context, curl_off_t total, curl_off_t now, curl_off_t up, curl_off_t done) {
    (void)total; (void)now; (void)up; (void)done; return cancelled(context);
}
static int ftp_execute(nvp_remote *r, int operation, const char *url, int64_t offset, size_t length,
    nvp_remote_cancel *cancel, nvp_remote_result *out) {
    CURL *curl = r->curl;
    curl_easy_reset(curl);
    ftp_buffer buffer = { out, operation == 0 ? NVP_MAX_LIST : length, cancel };
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_USERNAME, r->username[0] ? r->username : "anonymous");
    curl_easy_setopt(curl, CURLOPT_PASSWORD, r->password);
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "ftp,ftps");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(curl, CURLOPT_PROXY, "");
    curl_easy_setopt(curl, CURLOPT_FTP_SKIP_PASV_IP, 1L);
    if(!strncmp(url, "ftps://", 7)) curl_easy_setopt(curl, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, ftp_write);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buffer);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, ftp_progress);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, cancel);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    char range[96];
    if(operation == 0) { curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "MLSD"); out->listing_is_mlsd = 1; }
    else { snprintf(range, sizeof(range), "%lld-%lld", (long long)offset, (long long)(offset + length - 1)); curl_easy_setopt(curl, CURLOPT_RANGE, range); }
    CURLcode code = curl_easy_perform(curl);
    long response = 0; curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response);
    if(operation == 0 && (response == 500 || response == 501 || response == 502 || response == 504)) {
        free(out->data); out->data = NULL; out->size = 0; out->listing_is_mlsd = 0;
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "LIST");
        code = curl_easy_perform(curl); curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response);
    }
    if(cancelled(cancel)) return 7;
    if(code == CURLE_OK) return 0;
    if(code == CURLE_LOGIN_DENIED || response == 530) return 2;
    if(code == CURLE_REMOTE_FILE_NOT_FOUND || code == CURLE_FTP_COULDNT_RETR_FILE || response == 550) return 4;
    if(code == CURLE_REMOTE_ACCESS_DENIED) return 5;
    if(code == CURLE_WRITE_ERROR || code == CURLE_RANGE_ERROR || code == CURLE_BAD_DOWNLOAD_RESUME) return 6;
    return 1;
}
int nvp_remote_execute(nvp_remote *r, int operation, const char *path, const char *url,
    int64_t offset, size_t length, nvp_remote_cancel *cancel, nvp_remote_result *out) {
    memset(out, 0, sizeof(*out));
    if(cancelled(cancel)) return 7;
    if(!r || operation < 0 || operation > 2 || offset < 0 || length > NVP_MAX_READ ||
       (uint64_t)offset > INT64_MAX - length) return 6;
    if(operation == 2 && !length) return 0;
    return r->ssh ? ssh_execute(r, operation, path, offset, length, cancel, out)
                  : ftp_execute(r, operation, url, offset, length, cancel, out);
}
