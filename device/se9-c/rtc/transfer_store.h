#ifndef SE9_TRANSFER_STORE_H
#define SE9_TRANSFER_STORE_H
#include <stdbool.h>
#include <stdint.h>
bool se9_transfer_init(const char *root,const char *proxy_secret);
bool se9_transfer_handle(int fd,const char *method,const char *target,const char *headers,int64_t length);
#endif
