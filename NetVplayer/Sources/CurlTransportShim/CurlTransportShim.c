#include "CurlTransportShim.h"

#include <curl/curl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

struct nvp_curl_buffer {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
};

struct nvp_curl_response_headers {
    char *content_range;
    size_t content_range_capacity;
    char *content_type;
    size_t content_type_capacity;
    char *accept_ranges;
    size_t accept_ranges_capacity;
};

static pthread_once_t nvp_curl_once = PTHREAD_ONCE_INIT;

static void nvp_curl_initialize(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

static size_t nvp_curl_write(void *contents, size_t size, size_t count, void *context) {
    struct nvp_curl_buffer *buffer = context;
    if (size != 0 && count > SIZE_MAX / size) {
        return 0;
    }
    size_t incoming = size * count;
    if (incoming > SIZE_MAX - buffer->length) {
        return 0;
    }
    size_t new_length = buffer->length + incoming;
    if (new_length == SIZE_MAX) {
        return 0;
    }
    if (new_length > buffer->capacity) {
        size_t new_capacity = buffer->capacity == 0 ? 64 * 1024 : buffer->capacity;
        while (new_capacity < new_length) {
            if (new_capacity > SIZE_MAX / 2) {
                new_capacity = new_length;
                break;
            }
            new_capacity *= 2;
        }
        uint8_t *resized = realloc(buffer->bytes, new_capacity + 1);
        if (resized == NULL) {
            return 0;
        }
        buffer->bytes = resized;
        buffer->capacity = new_capacity;
    }
    memcpy(buffer->bytes + buffer->length, contents, incoming);
    buffer->length = new_length;
    buffer->bytes[new_length] = 0;
    return incoming;
}

static void nvp_curl_copy_value(char *destination, size_t capacity, const char *value, size_t length) {
    if (destination == NULL || capacity == 0) {
        return;
    }
    while (length > 0 && (value[length - 1] == '\r' || value[length - 1] == '\n' || value[length - 1] == ' ')) {
        length--;
    }
    size_t copied = length < capacity - 1 ? length : capacity - 1;
    memcpy(destination, value, copied);
    destination[copied] = '\0';
}

static void nvp_curl_capture_header(
    const char *line,
    size_t length,
    const char *name,
    char *destination,
    size_t capacity
) {
    size_t name_length = strlen(name);
    if (length <= name_length || strncasecmp(line, name, name_length) != 0 || line[name_length] != ':') {
        return;
    }
    const char *value = line + name_length + 1;
    size_t value_length = length - name_length - 1;
    while (value_length > 0 && (*value == ' ' || *value == '\t')) {
        value++;
        value_length--;
    }
    nvp_curl_copy_value(destination, capacity, value, value_length);
}

static size_t nvp_curl_header(void *contents, size_t size, size_t count, void *context) {
    if (size != 0 && count > SIZE_MAX / size) {
        return 0;
    }
    size_t incoming = size * count;
    const char *line = contents;
    struct nvp_curl_response_headers *headers = context;
    if (incoming >= 5 && strncasecmp(line, "HTTP/", 5) == 0) {
        headers->content_range[0] = '\0';
        headers->content_type[0] = '\0';
        headers->accept_ranges[0] = '\0';
        return incoming;
    }
    nvp_curl_capture_header(line, incoming, "Content-Range", headers->content_range, headers->content_range_capacity);
    nvp_curl_capture_header(line, incoming, "Content-Type", headers->content_type, headers->content_type_capacity);
    nvp_curl_capture_header(line, incoming, "Accept-Ranges", headers->accept_ranges, headers->accept_ranges_capacity);
    return incoming;
}

static int nvp_curl_progress(
    void *context,
    curl_off_t download_total,
    curl_off_t download_now,
    curl_off_t upload_total,
    curl_off_t upload_now
) {
    (void)download_total;
    (void)download_now;
    (void)upload_total;
    (void)upload_now;
    const atomic_int *cancel_flag = context;
    return cancel_flag != NULL && atomic_load(cancel_flag) != 0;
}

static int nvp_curl_append_header(struct curl_slist **headers, const char *name, const char *value) {
    if (value == NULL || value[0] == '\0') {
        return 1;
    }
    size_t length = strlen(name) + strlen(value) + 3;
    char *line = malloc(length);
    if (line == NULL) {
        return 0;
    }
    snprintf(line, length, "%s: %s", name, value);
    struct curl_slist *updated = curl_slist_append(*headers, line);
    free(line);
    if (updated == NULL) {
        return 0;
    }
    *headers = updated;
    return 1;
}

static const char *nvp_curl_http_version_name(long version) {
    switch (version) {
        case CURL_HTTP_VERSION_1_0:
            return "http/1.0";
        case CURL_HTTP_VERSION_1_1:
            return "http/1.1";
        case CURL_HTTP_VERSION_2_0:
            return "h2";
#ifdef CURL_HTTP_VERSION_3
        case CURL_HTTP_VERSION_3:
            return "h3";
#endif
        default:
            return "unknown";
    }
}

int32_t nvp_curl_baidu_root_get(
    const char *url,
    const char *user_agent,
    const char *cookie,
    long timeout_milliseconds,
    uint8_t **out_bytes,
    size_t *out_length,
    long *out_status_code,
    char *out_error,
    size_t error_capacity
) {
    if (url == NULL || user_agent == NULL || cookie == NULL || out_bytes == NULL ||
        out_length == NULL || out_status_code == NULL || out_error == NULL || error_capacity == 0) {
        return CURLE_BAD_FUNCTION_ARGUMENT;
    }

    *out_bytes = NULL;
    *out_length = 0;
    *out_status_code = 0;
    out_error[0] = '\0';
    pthread_once(&nvp_curl_once, nvp_curl_initialize);

    CURL *handle = curl_easy_init();
    if (handle == NULL) {
        snprintf(out_error, error_capacity, "curl_easy_init failed");
        return CURLE_FAILED_INIT;
    }

    struct nvp_curl_buffer buffer = {0};
    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Connection: Keep-Alive");
    headers = curl_slist_append(headers, "Host: pan.baidu.com");

    size_t cookie_line_length = strlen(cookie) + 9;
    char *cookie_line = malloc(cookie_line_length);
    if (cookie_line == NULL) {
        curl_slist_free_all(headers);
        curl_easy_cleanup(handle);
        return CURLE_OUT_OF_MEMORY;
    }
    snprintf(cookie_line, cookie_line_length, "Cookie: %s", cookie);
    headers = curl_slist_append(headers, cookie_line);
    free(cookie_line);

    curl_easy_setopt(handle, CURLOPT_URL, url);
    curl_easy_setopt(handle, CURLOPT_USERAGENT, user_agent);
    curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(handle, CURLOPT_ACCEPT_ENCODING, "gzip");
    curl_easy_setopt(handle, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, timeout_milliseconds);
    curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, nvp_curl_write);
    curl_easy_setopt(handle, CURLOPT_WRITEDATA, &buffer);
    curl_easy_setopt(handle, CURLOPT_ERRORBUFFER, out_error);

    CURLcode result = curl_easy_perform(handle);
    if (result == CURLE_OK) {
        curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, out_status_code);
        *out_bytes = buffer.bytes;
        *out_length = buffer.length;
    } else {
        free(buffer.bytes);
    }

    curl_slist_free_all(headers);
    curl_easy_cleanup(handle);
    return result;
}

int32_t nvp_curl_range_get(
    const char *url,
    const char *user_agent,
    const char *cookie,
    const char *referer,
    const char *origin,
    const char *range,
    const char *resolve_entry,
    const char *interface_name,
    long timeout_milliseconds,
    const int32_t *cancel_flag,
    uint8_t **out_bytes,
    size_t *out_length,
    long *out_status_code,
    char *out_http_version,
    size_t http_version_capacity,
    char *out_primary_ip,
    size_t primary_ip_capacity,
    int64_t *out_total_time_microseconds,
    int64_t *out_average_bytes_per_second,
    char *out_content_range,
    size_t content_range_capacity,
    char *out_content_type,
    size_t content_type_capacity,
    char *out_accept_ranges,
    size_t accept_ranges_capacity,
    char *out_final_url,
    size_t final_url_capacity,
    char *out_error,
    size_t error_capacity
) {
    if (url == NULL || user_agent == NULL || cookie == NULL || referer == NULL ||
        origin == NULL || range == NULL || resolve_entry == NULL || interface_name == NULL ||
        out_bytes == NULL || out_length == NULL ||
        out_status_code == NULL || out_http_version == NULL || http_version_capacity == 0 ||
        out_primary_ip == NULL || primary_ip_capacity == 0 || out_total_time_microseconds == NULL ||
        out_average_bytes_per_second == NULL || out_content_range == NULL || content_range_capacity == 0 ||
        out_content_type == NULL || content_type_capacity == 0 || out_accept_ranges == NULL ||
        accept_ranges_capacity == 0 || out_final_url == NULL || final_url_capacity == 0 ||
        out_error == NULL || error_capacity == 0) {
        return CURLE_BAD_FUNCTION_ARGUMENT;
    }

    *out_bytes = NULL;
    *out_length = 0;
    *out_status_code = 0;
    out_http_version[0] = '\0';
    out_primary_ip[0] = '\0';
    *out_total_time_microseconds = 0;
    *out_average_bytes_per_second = 0;
    out_content_range[0] = '\0';
    out_content_type[0] = '\0';
    out_accept_ranges[0] = '\0';
    out_final_url[0] = '\0';
    out_error[0] = '\0';
    pthread_once(&nvp_curl_once, nvp_curl_initialize);

    CURL *handle = curl_easy_init();
    if (handle == NULL) {
        snprintf(out_error, error_capacity, "curl_easy_init failed");
        return CURLE_FAILED_INIT;
    }

    struct nvp_curl_buffer buffer = {0};
    struct nvp_curl_response_headers response_headers = {
        out_content_range,
        content_range_capacity,
        out_content_type,
        content_type_capacity,
        out_accept_ranges,
        accept_ranges_capacity
    };
    struct curl_slist *headers = NULL;
    struct curl_slist *resolve_entries = NULL;
    if (!nvp_curl_append_header(&headers, "Cookie", cookie) ||
        !nvp_curl_append_header(&headers, "Origin", origin) ||
        !nvp_curl_append_header(&headers, "Range", range) ||
        !nvp_curl_append_header(&headers, "Connection", "Keep-Alive")) {
        curl_slist_free_all(headers);
        curl_easy_cleanup(handle);
        return CURLE_OUT_OF_MEMORY;
    }
    if (resolve_entry[0] != '\0') {
        resolve_entries = curl_slist_append(resolve_entries, resolve_entry);
        if (resolve_entries == NULL) {
            curl_slist_free_all(headers);
            curl_easy_cleanup(handle);
            return CURLE_OUT_OF_MEMORY;
        }
    }

    curl_easy_setopt(handle, CURLOPT_URL, url);
    curl_easy_setopt(handle, CURLOPT_USERAGENT, user_agent);
    curl_easy_setopt(handle, CURLOPT_REFERER, referer);
    curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(handle, CURLOPT_ACCEPT_ENCODING, "identity");
    curl_easy_setopt(handle, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2TLS);
    if (resolve_entries != NULL) {
        curl_easy_setopt(handle, CURLOPT_RESOLVE, resolve_entries);
    }
    if (interface_name[0] != '\0') {
        curl_easy_setopt(handle, CURLOPT_INTERFACE, interface_name);
    }
    curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(handle, CURLOPT_MAXREDIRS, 5L);
    curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(handle, CURLOPT_CONNECTTIMEOUT_MS, timeout_milliseconds < 15000L ? timeout_milliseconds : 15000L);
    curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, timeout_milliseconds);
    curl_easy_setopt(handle, CURLOPT_TCP_NODELAY, 1L);
    curl_easy_setopt(handle, CURLOPT_BUFFERSIZE, 512L * 1024L);
    curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, nvp_curl_write);
    curl_easy_setopt(handle, CURLOPT_WRITEDATA, &buffer);
    curl_easy_setopt(handle, CURLOPT_HEADERFUNCTION, nvp_curl_header);
    curl_easy_setopt(handle, CURLOPT_HEADERDATA, &response_headers);
    curl_easy_setopt(handle, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(handle, CURLOPT_XFERINFOFUNCTION, nvp_curl_progress);
    curl_easy_setopt(handle, CURLOPT_XFERINFODATA, cancel_flag);
    curl_easy_setopt(handle, CURLOPT_ERRORBUFFER, out_error);

    CURLcode result = curl_easy_perform(handle);
    long negotiated_http_version = CURL_HTTP_VERSION_NONE;
    char *primary_ip = NULL;
    curl_off_t total_time_microseconds = 0;
    curl_off_t average_bytes_per_second = 0;
    curl_easy_getinfo(handle, CURLINFO_HTTP_VERSION, &negotiated_http_version);
    curl_easy_getinfo(handle, CURLINFO_PRIMARY_IP, &primary_ip);
    curl_easy_getinfo(handle, CURLINFO_TOTAL_TIME_T, &total_time_microseconds);
    curl_easy_getinfo(handle, CURLINFO_SPEED_DOWNLOAD_T, &average_bytes_per_second);
    const char *http_version_name = nvp_curl_http_version_name(negotiated_http_version);
    nvp_curl_copy_value(out_http_version, http_version_capacity, http_version_name, strlen(http_version_name));
    if (primary_ip != NULL) {
        nvp_curl_copy_value(out_primary_ip, primary_ip_capacity, primary_ip, strlen(primary_ip));
    }
    *out_total_time_microseconds = (int64_t)total_time_microseconds;
    *out_average_bytes_per_second = (int64_t)average_bytes_per_second;
    if (result == CURLE_OK) {
        char *effective_url = NULL;
        curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, out_status_code);
        curl_easy_getinfo(handle, CURLINFO_EFFECTIVE_URL, &effective_url);
        if (effective_url != NULL) {
            nvp_curl_copy_value(out_final_url, final_url_capacity, effective_url, strlen(effective_url));
        }
        *out_bytes = buffer.bytes;
        *out_length = buffer.length;
    } else {
        free(buffer.bytes);
    }

    curl_slist_free_all(headers);
    curl_slist_free_all(resolve_entries);
    curl_easy_cleanup(handle);
    return result;
}

void nvp_curl_cancel(int32_t *cancel_flag) {
    if (cancel_flag != NULL) {
        atomic_store((atomic_int *)cancel_flag, 1);
    }
}

void nvp_curl_free(void *pointer) {
    free(pointer);
}
