#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "device_config.h"
#include "ft_common.h"
#include "se9_cloud_grant_key.h"
#include <errno.h>
#include <fcntl.h>
#include <openssl/pem.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

bool se9_load_proxy_token(char *output, size_t capacity) {
    if (!output || capacity < 65) return false;
    const char *configured = getenv("SE9_AGENT_PROXY_TOKEN");
    if (configured && *configured) {
        size_t length = strlen(configured);
        if (length >= capacity || length > 128 || !strncmp(configured, "replace-", 8)) return false;
        for (size_t i = 0; i < length; i++) if ((unsigned char)configured[i] < 33 || (unsigned char)configured[i] > 126) return false;
        memcpy(output, configured, length + 1);
        return true;
    }
    const char *path = getenv("SE9_AGENT_PROXY_TOKEN_FILE");
    if (!path || !*path) path = SE9_DEFAULT_PROXY_KEY_FILE;
    if (strlen(path) > 3500) return false;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0 && errno == ENOENT) {
        char value[65], suffix[17], temporary[4096];
        if (!ft_random_hex(value, 32) || !ft_random_hex(suffix, 8)) return false;
        if (snprintf(temporary, sizeof(temporary), "%s.%s.tmp", path, suffix) >= (int)sizeof(temporary)) return false;
        int temporary_fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (temporary_fd < 0) return false;
        size_t sent = 0;
        bool ok = true;
        while (sent < 64) {
            ssize_t n = write(temporary_fd, value + sent, 64 - sent);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { ok = false; break; }
            sent += (size_t)n;
        }
        if (ok) ok = fsync(temporary_fd) == 0;
        if (close(temporary_fd) != 0) ok = false;
        if (ok && link(temporary, path) != 0 && errno != EEXIST) ok = false;
        unlink(temporary);
        if (!ok) return false;
        char parent[4096];
        snprintf(parent, sizeof(parent), "%s", path);
        char *slash = strrchr(parent, '/');
        if (slash) { if (slash == parent) slash[1] = 0; else *slash = 0; }
        else snprintf(parent, sizeof(parent), ".");
        int directory = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (directory < 0) return false;
        ok = fsync(directory) == 0;
        close(directory);
        if (!ok) return false;
        fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    }
    if (fd < 0) return false;
    struct stat st;
    bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == geteuid() && (st.st_mode & 077) == 0 && st.st_size == 64;
    size_t got = 0;
    while (ok && got < 64) {
        ssize_t n = read(fd, output + got, 64 - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = false; break; }
        got += (size_t)n;
    }
    close(fd);
    output[got] = 0;
    return ok && ft_hex(output, 32);
}

EVP_PKEY *se9_load_cloud_grant_key(void) {
    const char *path = getenv("SE9_CLOUD_GRANT_PUBLIC_KEY");
    EVP_PKEY *key = NULL;
    if (path && *path) {
        FILE *file = fopen(path, "rb");
        if (!file) return NULL;
        key = PEM_read_PUBKEY(file, NULL, NULL, NULL);
        fclose(file);
    } else {
        BIO *bio = BIO_new_mem_buf(se9_cloud_grant_public_pem, -1);
        if (!bio) return NULL;
        key = PEM_read_bio_PUBKEY(bio, NULL, NULL, NULL);
        BIO_free(bio);
    }
    if (key && EVP_PKEY_base_id(key) != EVP_PKEY_ED25519) { EVP_PKEY_free(key); return NULL; }
    return key;
}

int se9_print_config_info(bool rtc_compiled) {
    EVP_PKEY *key = se9_load_cloud_grant_key();
    if (!key) return 1;
    unsigned char *der = NULL;
    int size = i2d_PUBKEY(key, &der);
    char hash[65];
    bool ok = size > 0 && ft_sha256(der, (size_t)size, hash);
    OPENSSL_free(der);
    EVP_PKEY_free(key);
    if (!ok) return 1;
    cJSON *info = cJSON_CreateObject();
    cJSON_AddNumberToObject(info, "configVersion", 2);
    cJSON_AddStringToObject(info, "buildProfile", "SE9_NAS_EMBEDDED_CONFIG_V2");
    cJSON_AddStringToObject(info, "cloudOrigin", SE9_DEFAULT_CLOUD_URL);
    cJSON_AddStringToObject(info, "cloudBasePath", SE9_DEFAULT_CLOUD_BASE_PATH);
    cJSON_AddStringToObject(info, "cloudPublicKeySha256", hash);
    cJSON_AddBoolToObject(info, "rtcCompiled", rtc_compiled);
    cJSON_AddStringToObject(info, "proxyKeyFile", SE9_DEFAULT_PROXY_KEY_FILE);
    char *text = cJSON_PrintUnformatted(info);
    bool printed = text != NULL;
    if (text) puts(text);
    free(text);
    cJSON_Delete(info);
    return printed ? 0 : 1;
}
