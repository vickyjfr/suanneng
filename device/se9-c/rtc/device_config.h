#ifndef SE9_DEVICE_CONFIG_H
#define SE9_DEVICE_CONFIG_H
#include <stdbool.h>
#include <stddef.h>
#include <openssl/evp.h>
#define SE9_DEFAULT_CLOUD_URL "https://123.56.147.51:8443"
#define SE9_DEFAULT_CLOUD_BASE_PATH "/se9"
#define SE9_DEFAULT_PROXY_KEY_FILE "/var/lib/se9/agent-proxy-token"
int se9_print_config_info(bool rtc_compiled);
bool se9_load_proxy_token(char *output, size_t capacity);
EVP_PKEY *se9_load_cloud_grant_key(void);
#endif
