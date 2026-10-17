#include "CLibcurl.h"

const char *FerryFTP_curl_version(void) {
    return curl_version();
}

CURL *ferry_curl_easy_init(void) {
    return curl_easy_init();
}

void ferry_curl_easy_cleanup(CURL *curl) {
    if (curl) {
        curl_easy_cleanup(curl);
    }
}

void ferry_curl_easy_reset(CURL *curl) {
    if (curl) {
        curl_easy_reset(curl);
    }
}

CURLcode ferry_curl_easy_perform(CURL *curl) {
    return curl_easy_perform(curl);
}

const char *ferry_curl_easy_strerror(CURLcode code) {
    return curl_easy_strerror(code);
}

CURLcode ferry_curl_set_url(CURL *curl, const char *url) {
    return curl_easy_setopt(curl, CURLOPT_URL, url);
}

CURLcode ferry_curl_set_port(CURL *curl, long port) {
    return curl_easy_setopt(curl, CURLOPT_PORT, port);
}

CURLcode ferry_curl_set_userpwd(CURL *curl, const char *userpwd) {
    return curl_easy_setopt(curl, CURLOPT_USERPWD, userpwd);
}

CURLcode ferry_curl_set_timeout(CURL *curl, long seconds) {
    return curl_easy_setopt(curl, CURLOPT_TIMEOUT, seconds);
}

CURLcode ferry_curl_set_connect_timeout(CURL *curl, long seconds) {
    return curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, seconds);
}

CURLcode ferry_curl_set_dirlistonly(CURL *curl, long enable) {
    return curl_easy_setopt(curl, CURLOPT_DIRLISTONLY, enable);
}

CURLcode ferry_curl_set_customrequest(CURL *curl, const char *request) {
    return curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, request);
}

CURLcode ferry_curl_set_quote(CURL *curl, struct curl_slist *quote) {
    return curl_easy_setopt(curl, CURLOPT_QUOTE, quote);
}

CURLcode ferry_curl_set_postquote(CURL *curl, struct curl_slist *postquote) {
    return curl_easy_setopt(curl, CURLOPT_POSTQUOTE, postquote);
}

CURLcode ferry_curl_set_upload(CURL *curl, long enable) {
    return curl_easy_setopt(curl, CURLOPT_UPLOAD, enable);
}

CURLcode ferry_curl_set_append(CURL *curl, long enable) {
    return curl_easy_setopt(curl, CURLOPT_FTPAPPEND, enable);
}

CURLcode ferry_curl_set_resume_from(CURL *curl, curl_off_t offset) {
    return curl_easy_setopt(curl, CURLOPT_RESUME_FROM_LARGE, offset);
}

CURLcode ferry_curl_set_infilesize(CURL *curl, curl_off_t size) {
    return curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, size);
}

CURLcode ferry_curl_set_write_callback(CURL *curl, size_t (*cb)(char *, size_t, size_t, void *), void *userdata) {
    CURLcode rc = curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, cb);
    if (rc != CURLE_OK) return rc;
    return curl_easy_setopt(curl, CURLOPT_WRITEDATA, userdata);
}

CURLcode ferry_curl_set_read_callback(CURL *curl, size_t (*cb)(char *, size_t, size_t, void *), void *userdata) {
    CURLcode rc = curl_easy_setopt(curl, CURLOPT_READFUNCTION, cb);
    if (rc != CURLE_OK) return rc;
    return curl_easy_setopt(curl, CURLOPT_READDATA, userdata);
}

CURLcode ferry_curl_set_xferinfo_callback(CURL *curl, int (*cb)(void *, curl_off_t, curl_off_t, curl_off_t, curl_off_t), void *userdata) {
    CURLcode rc = curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, cb);
    if (rc != CURLE_OK) return rc;
    rc = curl_easy_setopt(curl, CURLOPT_XFERINFODATA, userdata);
    if (rc != CURLE_OK) return rc;
    return curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
}

CURLcode ferry_curl_set_ssl_options(CURL *curl, long usessl) {
    // CURLUSESSL_ALL = 3, CURLUSESSL_TRY = 1, CURLUSESSL_CONTROL = 2
    return curl_easy_setopt(curl, CURLOPT_USE_SSL, usessl);
}

CURLcode ferry_curl_set_ftp_create_missing_dirs(CURL *curl, long enable) {
    return curl_easy_setopt(curl, CURLOPT_FTP_CREATE_MISSING_DIRS, enable);
}

CURLcode ferry_curl_set_nobody(CURL *curl, long enable) {
    return curl_easy_setopt(curl, CURLOPT_NOBODY, enable);
}

CURLcode ferry_curl_set_filetime(CURL *curl, long enable) {
    return curl_easy_setopt(curl, CURLOPT_FILETIME, enable);
}

long ferry_curl_get_response_code(CURL *curl) {
    long code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
    return code;
}

curl_off_t ferry_curl_get_content_length(CURL *curl) {
    curl_off_t len = -1;
    curl_easy_getinfo(curl, CURLINFO_CONTENT_LENGTH_DOWNLOAD_T, &len);
    return len;
}

long ferry_curl_get_filetime(CURL *curl) {
    long time = -1;
    curl_easy_getinfo(curl, CURLINFO_FILETIME, &time);
    return time;
}

struct curl_slist *ferry_curl_slist_append(struct curl_slist *list, const char *str) {
    return curl_slist_append(list, str);
}

void ferry_curl_slist_free_all(struct curl_slist *list) {
    if (list) {
        curl_slist_free_all(list);
    }
}
