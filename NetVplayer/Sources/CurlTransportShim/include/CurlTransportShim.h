#ifndef CURL_TRANSPORT_SHIM_H
#define CURL_TRANSPORT_SHIM_H

#include <stddef.h>
#include <stdint.h>

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
);

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
);

void nvp_curl_cancel(int32_t *cancel_flag);

void nvp_curl_free(void *pointer);

#endif
