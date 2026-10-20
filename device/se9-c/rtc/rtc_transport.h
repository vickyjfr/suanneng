#ifndef SE9_RTC_TRANSPORT_H
#define SE9_RTC_TRANSPORT_H
#include <stdbool.h>
#include <stdint.h>
#include <openssl/evp.h>
typedef struct {char user_id[129];char device_id[129];int64_t expires;} se9_relay_principal;
bool se9_rtc_start(const char *device_id,EVP_PKEY *device_key,const char *device_token,const char *cloud_url,const char *base_path,int api_port,const char *proxy_secret,const char *ca_file);
bool se9_rtc_relay_attach(const void *data,size_t length,se9_relay_principal *principal);
#endif
