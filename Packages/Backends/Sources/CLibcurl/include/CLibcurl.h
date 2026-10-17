#ifndef CLIBCURL_H
#define CLIBCURL_H

#include <curl/curl.h>
#include <stddef.h>

const char *FerryFTP_curl_version(void);

CURL *ferry_curl_easy_init(void);
void ferry_curl_easy_cleanup(CURL *curl);
void ferry_curl_easy_reset(CURL *curl);
CURLcode ferry_curl_easy_perform(CURL *curl);
const char *ferry_curl_easy_strerror(CURLcode code);

CURLcode ferry_curl_set_url(CURL *curl, const char *url);
CURLcode ferry_curl_set_port(CURL *curl, long port);
CURLcode ferry_curl_set_userpwd(CURL *curl, const char *userpwd);
CURLcode ferry_curl_set_timeout(CURL *curl, long seconds);
CURLcode ferry_curl_set_connect_timeout(CURL *curl, long seconds);
CURLcode ferry_curl_set_dirlistonly(CURL *curl, long enable);
CURLcode ferry_curl_set_customrequest(CURL *curl, const char *request);
CURLcode ferry_curl_set_quote(CURL *curl, struct curl_slist *quote);
CURLcode ferry_curl_set_postquote(CURL *curl, struct curl_slist *postquote);
CURLcode ferry_curl_set_upload(CURL *curl, long enable);
CURLcode ferry_curl_set_append(CURL *curl, long enable);
CURLcode ferry_curl_set_resume_from(CURL *curl, curl_off_t offset);
CURLcode ferry_curl_set_infilesize(CURL *curl, curl_off_t size);
CURLcode ferry_curl_set_write_callback(CURL *curl, size_t (*cb)(char *, size_t, size_t, void *), void *userdata);
CURLcode ferry_curl_set_read_callback(CURL *curl, size_t (*cb)(char *, size_t, size_t, void *), void *userdata);
CURLcode ferry_curl_set_xferinfo_callback(CURL *curl, int (*cb)(void *, curl_off_t, curl_off_t, curl_off_t, curl_off_t), void *userdata);
CURLcode ferry_curl_set_ssl_options(CURL *curl, long usessl);
CURLcode ferry_curl_set_ftp_create_missing_dirs(CURL *curl, long enable);
CURLcode ferry_curl_set_nobody(CURL *curl, long enable);
CURLcode ferry_curl_set_filetime(CURL *curl, long enable);

long ferry_curl_get_response_code(CURL *curl);
curl_off_t ferry_curl_get_content_length(CURL *curl);
long ferry_curl_get_filetime(CURL *curl);

struct curl_slist *ferry_curl_slist_append(struct curl_slist *list, const char *str);
void ferry_curl_slist_free_all(struct curl_slist *list);

#endif /* CLIBCURL_H */
