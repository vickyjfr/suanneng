#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L
#include "device_config.h"
#include <assert.h>
#include <fcntl.h>
#include <openssl/sha.h>
#include <openssl/x509.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
int main(void) {
    unsetenv("SE9_AGENT_PROXY_TOKEN"); unsetenv("SE9_CLOUD_GRANT_PUBLIC_KEY");
    EVP_PKEY *key = se9_load_cloud_grant_key(); assert(key);
    unsigned char *der = NULL, digest[32]; int length = i2d_PUBKEY(key, &der); assert(length > 0);
    SHA256(der, (size_t)length, digest); OPENSSL_free(der); EVP_PKEY_free(key);
    char fingerprint[65]; for (size_t i = 0; i < 32; i++) snprintf(fingerprint + i*2, 3, "%02x", digest[i]);
    assert(!strcmp(fingerprint, "5991d966e23a94d418bff4d1a8bb35f25554e5b0fa392bb5b05bc4db310a8370"));
    setenv("SE9_CLOUD_GRANT_PUBLIC_KEY", "/missing/no-key.pem", 1); assert(!se9_load_cloud_grant_key());
    unsetenv("SE9_CLOUD_GRANT_PUBLIC_KEY");
    char directory[] = "/tmp/se9-config-XXXXXX"; assert(mkdtemp(directory));
    char path[512]; snprintf(path, sizeof(path), "%s/proxy", directory); setenv("SE9_AGENT_PROXY_TOKEN_FILE", path, 1);
    int pipes[2]; assert(pipe(pipes) == 0); pid_t children[6];
    for (int i = 0; i < 6; i++) {
        children[i] = fork(); assert(children[i] >= 0);
        if (!children[i]) { close(pipes[0]); char value[129]; if (!se9_load_proxy_token(value, sizeof(value)) || write(pipes[1], value, 64) != 64) _exit(1); close(pipes[1]); _exit(0); }
    }
    close(pipes[1]); char values[6*64]; size_t got = 0;
    while (got < sizeof(values)) { ssize_t n = read(pipes[0], values + got, sizeof(values) - got); assert(n > 0); got += (size_t)n; }
    close(pipes[0]);
    for (int i = 0; i < 6; i++) { int status; assert(waitpid(children[i], &status, 0) == children[i] && WIFEXITED(status) && WEXITSTATUS(status) == 0); assert(!memcmp(values, values + i*64, 64)); }
    char value[129]; assert(se9_load_proxy_token(value, sizeof(value))); assert(!memcmp(value, values, 64));
    struct stat st; assert(stat(path, &st) == 0 && (st.st_mode & 0777) == 0600);
    assert(chmod(path, 0644) == 0); assert(!se9_load_proxy_token(value, sizeof(value))); assert(chmod(path, 0600) == 0);
    char link_path[512]; snprintf(link_path, sizeof(link_path), "%s/link", directory); assert(symlink(path, link_path) == 0); setenv("SE9_AGENT_PROXY_TOKEN_FILE", link_path, 1); assert(!se9_load_proxy_token(value, sizeof(value)));
    setenv("SE9_AGENT_PROXY_TOKEN", "replace-with-random-32-byte-secret", 1); assert(!se9_load_proxy_token(value, sizeof(value)));
    setenv("SE9_AGENT_PROXY_TOKEN", "isolated-test-secret", 1); assert(se9_load_proxy_token(value, sizeof(value))); assert(!strcmp(value, "isolated-test-secret"));
    unlink(link_path); unlink(path); rmdir(directory);
    puts("PASS: embedded cloud key, explicit key override, concurrent key creation, restart reuse, permissions and symlink protection");
    return 0;
}
