#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netinet/in.h>
#include <netdb.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/sha.h>
#include <openssl/ssl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include "rtc/rtc_transport.h"
#include "rtc/device_config.h"

#define UDP_PORT 37020
#define PACKET_MAX 4096
#define RELAY_MAX (16 * 1024 * 1024)
#define REPLAY_CACHE_SIZE 64
static char key_file[PATH_MAX] = "/var/lib/se9/device-ed25519.pem";
static char device_id[65] = "";
static char device_name[128] = "SE9 NAS";
static int api_port = 8443;
static EVP_PKEY *device_signing_key = NULL;
static EVP_PKEY *handshake_key = NULL;
static unsigned char session_secret[32];
static char lan_session_id[65] = "";
static time_t lan_session_expires = 0;
static char cloud_url[256] = SE9_DEFAULT_CLOUD_URL;
static char cloud_base_path[128] = SE9_DEFAULT_CLOUD_BASE_PATH;
static char cloud_device_token[256] = "";
static char proxy_token[129] = "";
static char token_file[PATH_MAX] = "/var/lib/se9/device-token";
static char ca_file[PATH_MAX] = "/etc/ssl/certs/ca-certificates.crt";
static bool tls_insecure = false;
static bool random_bytes(void *buffer, size_t length);
static bool b64_encode(const unsigned char *input, size_t length, char *output, size_t capacity);
static int connect_host(const char *host, int port);
static bool cloud_request(const char *path, const char *body, const char *token, char *response, size_t response_cap);

static bool tls_peer_identity(SSL *ssl, const char *host) {
    unsigned char address[16];
    if (inet_pton(AF_INET, host, address) == 1 || inet_pton(AF_INET6, host, address) == 1)
        return X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(ssl), host) == 1;
    return SSL_set1_host(ssl, host) == 1;
}

static bool ws_write_all(SSL *ssl, int fd, const void *data, size_t length) {
    const unsigned char *cursor = data;
    while (length > 0) {
        int written = ssl ? SSL_write(ssl, cursor, (int)(length > INT_MAX ? INT_MAX : length)) : (int)send(fd, cursor, length, 0);
        if (written <= 0) return false;
        cursor += written;
        length -= (size_t)written;
    }
    return true;
}

static bool ws_read_all(SSL *ssl, int fd, void *data, size_t length) {
    unsigned char *cursor = data;
    while (length > 0) {
        int read_length = ssl ? SSL_read(ssl, cursor, (int)(length > INT_MAX ? INT_MAX : length)) : (int)recv(fd, cursor, length, 0);
        if (read_length <= 0) return false;
        cursor += read_length;
        length -= (size_t)read_length;
    }
    return true;
}

static bool ws_send_control(SSL *ssl, int fd, unsigned char opcode, const unsigned char *payload, size_t length) {
    if (length > 125) return false;
    unsigned char frame[2 + 4 + 125];
    unsigned char mask[4];
    if (!random_bytes(mask, sizeof(mask))) return false;
    frame[0] = (unsigned char)(0x80 | opcode);
    frame[1] = (unsigned char)(0x80 | length);
    memcpy(frame + 2, mask, sizeof(mask));
    for (size_t i = 0; i < length; i++) frame[6 + i] = payload[i] ^ mask[i % 4];
    return ws_write_all(ssl, fd, frame, 6 + length);
}

static bool ws_send_data(SSL *ssl, int fd, unsigned char opcode, const unsigned char *payload, size_t length) {
    if (length > RELAY_MAX) return false;
    unsigned char header[14], mask[4]; size_t header_length = 2;
    header[0] = (unsigned char)(0x80 | opcode);
    if (length < 126) header[1] = (unsigned char)(0x80 | length);
    else if (length <= 65535) { header[1] = 0xFE; header[2] = (unsigned char)(length >> 8); header[3] = (unsigned char)length; header_length = 4; }
    else { header[1] = 0xFF; for (int i = 0; i < 8; i++) header[2 + i] = (unsigned char)(length >> (56 - i * 8)); header_length = 10; }
    if (!random_bytes(mask, sizeof(mask))) return false;
    memcpy(header + header_length, mask, sizeof(mask));
    if (!ws_write_all(ssl, fd, header, header_length + sizeof(mask))) return false;
    unsigned char *masked = malloc(length ? length : 1);
    if (!masked) return false;
    for (size_t i = 0; i < length; i++) masked[i] = payload[i] ^ mask[i % 4];
    bool ok = ws_write_all(ssl, fd, masked, length);
    free(masked);
    return ok;
}

static bool send_socket_all(int fd, const unsigned char *data, size_t length) {
    while (length > 0) { ssize_t written = send(fd, data, length, 0); if (written <= 0) return false; data += written; length -= (size_t)written; }
    return true;
}

static bool proxy_to_file_api(const unsigned char *request, size_t request_length, unsigned char **response, size_t *response_length, const se9_relay_principal *principal) {
    if (!proxy_token[0] || request_length > RELAY_MAX) return false;
    const unsigned char *separator = NULL;
    for (size_t i = 0; i + 4 <= request_length; i++) if (!memcmp(request + i, "\r\n\r\n", 4)) { separator = request + i; break; }
    if (!separator) return false;
    size_t header_length = (size_t)(separator - request);
    char method[16], target[2048];
    char first_line[2200];
    const unsigned char *first_end = memchr(request, '\r', header_length);
    if (!first_end || (size_t)(first_end-request) >= sizeof(first_line)) return false;
    memcpy(first_line, request, (size_t)(first_end-request)); first_line[first_end-request] = 0;
    if (sscanf(first_line, "%15s %2047s", method, target) != 2) return false;
    bool transfer = !strncmp(target, "/api/v2/transfers", 17);
    if (transfer && (!principal || !principal->user_id[0] || principal->expires <= (int64_t)time(NULL))) return false;
    size_t forward_capacity = request_length + 1024;
    unsigned char *forwarded = malloc(forward_capacity);
    if (!forwarded) return false;
    size_t forward_used = 0;
    const unsigned char *line = request;
    while (line < separator) {
        const unsigned char *end = NULL;
        for (const unsigned char *p = line; p + 1 < separator + 2; p++) if (p[0] == '\r' && p[1] == '\n') { end = p; break; }
        if (!end || end > separator) { free(forwarded); return false; }
        size_t length = (size_t)(end - line);
        bool trusted = (length >= 20 && !strncasecmp((const char *)line, "X-Agent-Proxy-Token:", 20)) || (length >= 14 && !strncasecmp((const char *)line, "X-SE9-User-ID:", 14)) || (length >= 16 && !strncasecmp((const char *)line, "X-SE9-Device-ID:", 16));
        if (!trusted) { memcpy(forwarded + forward_used, line, length); forward_used += length; memcpy(forwarded + forward_used, "\r\n", 2); forward_used += 2; }
        line = end + 2;
    }
    int inserted = snprintf((char *)forwarded + forward_used, forward_capacity - forward_used, "X-Agent-Proxy-Token: %s\r\n", proxy_token);
    if (inserted < 0 || (size_t)inserted >= forward_capacity - forward_used) { free(forwarded); return false; }
    forward_used += (size_t)inserted;
    if (transfer) {
        inserted = snprintf((char *)forwarded + forward_used, forward_capacity - forward_used, "X-SE9-User-ID: %s\r\nX-SE9-Device-ID: %s\r\n", principal->user_id, principal->device_id);
        if (inserted < 0 || (size_t)inserted >= forward_capacity - forward_used) { free(forwarded); return false; }
        forward_used += (size_t)inserted;
    }
    memcpy(forwarded + forward_used, "\r\n", 2); forward_used += 2;
    size_t body_offset = header_length + 4;
    memcpy(forwarded + forward_used, request + body_offset, request_length - body_offset);
    size_t forwarded_length = forward_used + request_length - body_offset;
    int fd = connect_host("127.0.0.1", api_port);
    if (fd < 0) { free(forwarded); return false; }
    struct timeval timeout = {.tv_sec = 30, .tv_usec = 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)); setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    bool ok = send_socket_all(fd, forwarded, forwarded_length); free(forwarded);
    size_t capacity = 65536, used = 0; unsigned char *buffer = ok ? malloc(capacity) : NULL;
    while (ok && buffer && used <= RELAY_MAX) {
        if (used == capacity) { size_t next = capacity * 2; unsigned char *grown = realloc(buffer, next); if (!grown) { ok = false; break; } buffer = grown; capacity = next; }
        ssize_t read_length = recv(fd, buffer + used, capacity - used, 0);
        if (read_length <= 0) break;
        used += (size_t)read_length;
    }
    close(fd);
    if (!ok || !buffer || used == 0 || used > RELAY_MAX) { free(buffer); return false; }
    *response = buffer; *response_length = used; return true;
}

static bool parse_cloud_host(const char *url, char *host, size_t host_capacity, int *port) {
    const char *start = NULL;
    if (!strncmp(url, "wss://", 6)) { start = url + 6; *port = 443; }
    else if (!strncmp(url, "https://", 8)) { start = url + 8; *port = 443; }
    else if (!strncmp(url, "http://", 7)) { start = url + 7; *port = 80; }
    else if (!strncmp(url, "ws://", 5)) { start = url + 5; *port = 80; }
    else return false;
    const char *colon = strchr(start, ':');
    const char *end = strchr(start, '/');
    if (!end) end = start + strlen(start);
    if (colon && colon < end) {
        size_t length = (size_t)(colon - start);
        if (!length || length >= host_capacity) return false;
        memcpy(host, start, length); host[length] = 0;
        *port = atoi(colon + 1);
    } else {
        size_t length = (size_t)(end - start);
        if (!length || length >= host_capacity) return false;
        memcpy(host, start, length); host[length] = 0;
    }
    return *port > 0 && *port <= 65535;
}

static int connect_host(const char *host, int port) {
    char port_text[16]; snprintf(port_text, sizeof(port_text), "%d", port);
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM};
    struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, port_text, &hints, &addresses) != 0) return -1;
    int fd = -1;
    for (struct addrinfo *it = addresses; it; it = it->ai_next) {
        fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (fd >= 0 && connect(fd, it->ai_addr, it->ai_addrlen) == 0) break;
        if (fd >= 0) { close(fd); fd = -1; }
    }
    freeaddrinfo(addresses);
    return fd;
}

static bool websocket_session(void) {
    char host[128]; int port = 0;
    if (!parse_cloud_host(cloud_url, host, sizeof(host), &port) || !cloud_device_token[0]) return false;
    int fd = connect_host(host, port);
    if (fd < 0) return false;
    struct timeval timeout = {.tv_sec = 10, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    SSL_CTX *ctx = NULL;
    SSL *ssl = NULL;
    bool use_tls = !strncmp(cloud_url, "https://", 8) || !strncmp(cloud_url, "wss://", 6);
    if (use_tls) {
    ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) { close(fd); return false; }
    if (tls_insecure) SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    else if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) { SSL_CTX_free(ctx); close(fd); return false; }
    if (!tls_insecure) SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    ssl = SSL_new(ctx);
    if (!ssl || SSL_set_tlsext_host_name(ssl, host) != 1 || (!tls_insecure && !tls_peer_identity(ssl, host)) || SSL_set_fd(ssl, fd) != 1 || SSL_connect(ssl) != 1) {
        SSL_free(ssl); SSL_CTX_free(ctx); close(fd); return false;
    }
    }
    unsigned char raw_key[16]; char websocket_key[64];
    if (!random_bytes(raw_key, sizeof(raw_key)) || !b64_encode(raw_key, sizeof(raw_key), websocket_key, sizeof(websocket_key))) { SSL_free(ssl); SSL_CTX_free(ctx); close(fd); return false; }
    char request[1024];
    char relay_path[512]; int relay_path_length = snprintf(relay_path, sizeof(relay_path), "%s/api/v2/relay/device?deviceId=%s", cloud_base_path, device_id);
    int request_length = relay_path_length > 0 ? snprintf(request, sizeof(request), "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nX-Device-Token: %s\r\n\r\n", relay_path, host, websocket_key, cloud_device_token) : -1;
    bool ok = request_length > 0 && (size_t)request_length < sizeof(request) && ws_write_all(ssl, fd, request, (size_t)request_length);
    char headers[4096]; size_t used = 0;
    while (ok && used + 1 < sizeof(headers)) {
        if (!ws_read_all(ssl, fd, headers + used, 1)) { ok = false; break; }
        used++;
        if (used >= 4 && !memcmp(headers + used - 4, "\r\n\r\n", 4)) break;
    }
    headers[used < sizeof(headers) ? used : sizeof(headers) - 1] = 0;
    char accept_source[128], expected_accept[64]; unsigned char accept_digest[SHA_DIGEST_LENGTH];
    snprintf(accept_source, sizeof(accept_source), "%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", websocket_key);
    SHA1((const unsigned char *)accept_source, strlen(accept_source), accept_digest);
    b64_encode(accept_digest, sizeof(accept_digest), expected_accept, sizeof(expected_accept));
    const char *accept = strstr(headers, "Sec-WebSocket-Accept: ");
    if (!ok || !strstr(headers, " 101 ") || !accept || strncmp(accept + strlen("Sec-WebSocket-Accept: "), expected_accept, strlen(expected_accept))) ok = false;
    fprintf(stdout, "cloud WSS relay %s\n", ok ? "connected" : "connection failed");
    se9_relay_principal relay_principal = {0};
    time_t next_ping = time(NULL) + 20;
    while (ok) {
        fd_set read_set; FD_ZERO(&read_set); FD_SET(fd, &read_set);
        struct timeval wait = {.tv_sec = 1, .tv_usec = 0};
        int ready = select(fd + 1, &read_set, NULL, NULL, &wait);
        if (time(NULL) >= next_ping) { ok = ws_send_control(ssl, fd, 0x9, NULL, 0); next_ping = time(NULL) + 20; }
        if (!ok || ((ready <= 0 || !FD_ISSET(fd, &read_set)) && (!ssl || SSL_pending(ssl) == 0))) continue;
        unsigned char frame_header[2];
        if (!ws_read_all(ssl, fd, frame_header, sizeof(frame_header))) { ok = false; break; }
        unsigned char opcode = frame_header[0] & 0x0f; bool masked = (frame_header[1] & 0x80) != 0; size_t length = frame_header[1] & 0x7f;
        if (length == 126) { unsigned char extended[2]; if (!ws_read_all(ssl, fd, extended, sizeof(extended))) { ok = false; break; } length = ((size_t)extended[0] << 8) | extended[1]; }
        else if (length == 127) { unsigned char extended[8]; if (!ws_read_all(ssl, fd, extended, sizeof(extended))) { ok = false; break; } length = 0; for (size_t i = 0; i < sizeof(extended); i++) length = (length << 8) | extended[i]; }
        if (length > RELAY_MAX || !(frame_header[0] & 0x80) || masked) { ok = false; break; }
        unsigned char mask[4], *payload = length ? malloc(length) : NULL;
        if (length && !payload) { ok = false; break; }
        if (masked && !ws_read_all(ssl, fd, mask, sizeof(mask))) { free(payload); ok = false; break; }
        if (length && !ws_read_all(ssl, fd, payload, length)) { free(payload); ok = false; break; }
        if (masked) for (size_t i = 0; i < length; i++) payload[i] ^= mask[i % 4];
        if (opcode == 0x8) { free(payload); ok = false; break; }
        if (opcode == 0x9) ok = ws_send_control(ssl, fd, 0xA, payload, length);
#ifdef SE9_WITH_WEBRTC
        else if (opcode == 0x1 && payload && length && payload[0] == '{') {
            if (se9_rtc_relay_attach(payload, length, &relay_principal)) { const char *ack = "{\"type\":\"relay.attached\"}"; ok = ws_send_data(ssl, fd, 0x1, (const unsigned char *)ack, strlen(ack)); }
            else ok = false;
        }
#endif
        else if ((opcode == 0x1 || opcode == 0x2) && payload) { unsigned char *reply = NULL; size_t reply_length = 0; if (proxy_to_file_api(payload, length, &reply, &reply_length, &relay_principal)) { ok = ws_send_data(ssl, fd, 0x2, reply, reply_length); free(reply); } else ok = false; }
        free(payload);
    }
    if (ssl) SSL_shutdown(ssl);
    SSL_free(ssl); SSL_CTX_free(ctx); close(fd);
    return ok;
}

static void *websocket_worker(void *unused) {
    (void)unused;
    for (;;) {
        (void)websocket_session();
        sleep(5);
    }
    return NULL;
}
static char replay_ids[REPLAY_CACHE_SIZE][128];
static time_t replay_times[REPLAY_CACHE_SIZE];
static size_t replay_cursor = 0;

static bool accept_request(const char *request_id, const char *timestamp) {
    char *end = NULL;
    long long sent_ms = strtoll(timestamp, &end, 10);
    long long now_ms = (long long)time(NULL) * 1000;
    if (!request_id[0] || !timestamp[0] || end == timestamp || *end != '\0' || sent_ms < now_ms - 300000 || sent_ms > now_ms + 300000) return false;
    time_t now = time(NULL);
    for (size_t i = 0; i < REPLAY_CACHE_SIZE; i++) {
        if (replay_ids[i][0] && now - replay_times[i] <= 300 && strcmp(replay_ids[i], request_id) == 0) return false;
    }
    snprintf(replay_ids[replay_cursor], sizeof(replay_ids[replay_cursor]), "%s", request_id);
    replay_times[replay_cursor] = now;
    replay_cursor = (replay_cursor + 1) % REPLAY_CACHE_SIZE;
    return true;
}

static bool b64_encode(const unsigned char *input, size_t length, char *output, size_t capacity) {
    if (capacity < 4 * ((length + 2) / 3) + 1) return false;
    int written = EVP_EncodeBlock((unsigned char *)output, input, (int)length);
    output[written] = 0;
    return true;
}

static bool b64_decode(const char *input, unsigned char *output, size_t *length) {
    size_t input_length = strlen(input);
    if (input_length % 4 != 0) return false;
    int written = EVP_DecodeBlock(output, (const unsigned char *)input, (int)input_length);
    if (written < 0) return false;
    while (input_length && input[input_length - 1] == '=') { written--; input_length--; }
    *length = (size_t)written;
    return true;
}

static bool random_bytes(void *buffer, size_t length) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return false;
    unsigned char *cursor = buffer;
    size_t offset = 0;
    while (offset < length) {
        ssize_t read_length = read(fd, cursor + offset, length - offset);
        if (read_length <= 0) { close(fd); return false; }
        offset += (size_t)read_length;
    }
    close(fd);
    return true;
}

static bool random_hex(char *output, size_t bytes) {
    unsigned char data[32];
    if (bytes > sizeof(data) || RAND_bytes(data, (int)bytes) != 1) return false;
    for (size_t i = 0; i < bytes; i++) snprintf(output + i * 2, 3, "%02x", data[i]);
    output[bytes * 2] = 0;
    return true;
}

static void load_device_token(void) { FILE *file = fopen(token_file, "r"); if (!file) return; if (fgets(cloud_device_token, sizeof(cloud_device_token), file)) cloud_device_token[strcspn(cloud_device_token, "\r\n")] = 0; fclose(file); }
static void save_device_token(void) { FILE *file = fopen(token_file, "w"); if (!file) return; fputs(cloud_device_token, file); fputc('\n', file); fclose(file); chmod(token_file, 0600); }

static bool extract_string(const char *json, const char *key, char *out, size_t cap) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return false;
    p = strchr(p + strlen(needle), ':');
    if (!p) return false;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    if (*p != '"') return false;
    p++;
    size_t n = 0;
    while (*p && *p != '"' && n + 1 < cap) out[n++] = *p++;
    if (*p != '"') return false;
    out[n] = 0;
    return true;
}

static bool extract_number(const char *json, const char *key, char *out, size_t cap) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(json, needle);
    if (!p) return false;
    p = strchr(p + strlen(needle), ':');
    if (!p) return false;
    p++;
    while (*p == ' ' || *p == '\t') p++;
    size_t n = 0;
    while (*p >= '0' && *p <= '9' && n + 1 < cap) out[n++] = *p++;
    out[n] = 0;
    return n > 0;
}

static bool mkdir_parent(const char *path) {
    char copy[PATH_MAX];
    if (snprintf(copy, sizeof(copy), "%s", path) >= (int)sizeof(copy)) return false;
    char *slash = strrchr(copy, '/');
    if (!slash) return true;
    *slash = 0;
    return mkdir(copy, 0700) == 0 || errno == EEXIST;
}

static EVP_PKEY *load_or_create_key(void) {
    FILE *file = fopen(key_file, "rb");
    if (file) {
        EVP_PKEY *key = PEM_read_PrivateKey(file, NULL, NULL, NULL);
        fclose(file);
        return key;
    }
    if (!mkdir_parent(key_file)) return NULL;
    EVP_PKEY_CTX *ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, NULL);
    if (!ctx || EVP_PKEY_keygen_init(ctx) <= 0) { EVP_PKEY_CTX_free(ctx); return NULL; }
    EVP_PKEY *key = NULL;
    if (EVP_PKEY_keygen(ctx, &key) <= 0) key = NULL;
    EVP_PKEY_CTX_free(ctx);
    if (!key) return NULL;
    file = fopen(key_file, "wb");
    if (!file || !PEM_write_PrivateKey(file, key, NULL, NULL, 0, NULL, NULL)) {
        if (file) fclose(file);
        EVP_PKEY_free(key);
        return NULL;
    }
    fclose(file);
    chmod(key_file, 0600);
    return key;
}

static bool init_device_id(EVP_PKEY *key) {
    unsigned char *public_key = NULL;
    int length = i2d_PUBKEY(key, &public_key);
    if (length <= 0) return false;
    unsigned char digest[SHA256_DIGEST_LENGTH];
    SHA256(public_key, (size_t)length, digest);
    OPENSSL_free(public_key);
    for (int i = 0; i < 16; i++) snprintf(device_id + i * 2, 3, "%02x", digest[i]);
    device_id[32] = 0;
    return true;
}

static bool sign_text(EVP_PKEY *key, const char *text, char *out, size_t cap) {
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!ctx || EVP_DigestSignInit(ctx, NULL, NULL, NULL, key) <= 0) { EVP_MD_CTX_free(ctx); return false; }
    size_t length = 0;
    if (EVP_DigestSign(ctx, NULL, &length, (const unsigned char *)text, strlen(text)) <= 0 || length > 512) { EVP_MD_CTX_free(ctx); return false; }
    unsigned char signature[512];
    if (EVP_DigestSign(ctx, signature, &length, (const unsigned char *)text, strlen(text)) <= 0) { EVP_MD_CTX_free(ctx); return false; }
    EVP_MD_CTX_free(ctx);
    if (cap < 4 * ((length + 2) / 3) + 1) return false;
    int encoded = EVP_EncodeBlock((unsigned char *)out, signature, (int)length);
    out[encoded] = 0;
    return true;
}

static void send_response(int fd, const struct sockaddr_in *peer, socklen_t peer_len, EVP_PKEY *key, const char *type, const char *request_id, const char *timestamp, const char *nonce) {
    (void)type;
    unsigned char raw_public[64]; size_t raw_length = sizeof(raw_public); char public_key[256] = "";
    if (EVP_PKEY_get_raw_public_key(key, raw_public, &raw_length) <= 0 || !b64_encode(raw_public, raw_length, public_key, sizeof(public_key))) return;
    char body[1400];
    snprintf(body, sizeof(body), "{\"name\":\"%s\",\"httpsPort\":%d,\"apiBase\":\"/api/v2\",\"claimStatus\":\"pending_claim\",\"publicKey\":\"%s\",\"publicKeyFingerprint\":\"ed25519:%s\",\"capabilities\":[\"files\",\"upload\",\"download\"]}", device_name, api_port, public_key, device_id);
    char transcript[2048];
    snprintf(transcript, sizeof(transcript), "1|discover_response|%s|%s|%s|%s", request_id, timestamp, nonce, body);
    char signature[1024] = "";
    if (!sign_text(key, transcript, signature, sizeof(signature))) return;
    char packet[PACKET_MAX];
    int length = snprintf(packet, sizeof(packet), "{\"version\":1,\"type\":\"discover_response\",\"requestId\":\"%s\",\"timestamp\":%lld,\"serverTimestamp\":%lld,\"deviceId\":\"%s\",\"body\":%s,\"signature\":\"%s\"}", request_id, (long long)time(NULL) * 1000, (long long)time(NULL) * 1000, device_id, body, signature);
    if (length > 0) sendto(fd, packet, (size_t)length, 0, (const struct sockaddr *)peer, peer_len);
}

static bool derive_session(const char *app_public_b64, char *device_public_b64, size_t capacity) {
    unsigned char app_public[64]; size_t app_length = 0;
    if (strlen(app_public_b64) != 44 || !b64_decode(app_public_b64, app_public, &app_length) || app_length != 32) return false;
    EVP_PKEY_free(handshake_key); handshake_key = NULL;
    EVP_PKEY_CTX *keygen = EVP_PKEY_CTX_new_id(EVP_PKEY_X25519, NULL);
    if (!keygen || EVP_PKEY_keygen_init(keygen) <= 0 || EVP_PKEY_keygen(keygen, &handshake_key) <= 0) { EVP_PKEY_CTX_free(keygen); return false; }
    EVP_PKEY_CTX_free(keygen);
    unsigned char device_public[32]; size_t device_length = sizeof(device_public);
    if (EVP_PKEY_get_raw_public_key(handshake_key, device_public, &device_length) <= 0 || !b64_encode(device_public, device_length, device_public_b64, capacity)) return false;
    EVP_PKEY *peer = EVP_PKEY_new_raw_public_key(EVP_PKEY_X25519, NULL, app_public, app_length);
    EVP_PKEY_CTX *derive = peer ? EVP_PKEY_CTX_new(handshake_key, NULL) : NULL;
    size_t secret_length = sizeof(session_secret);
    bool ok = derive && EVP_PKEY_derive_init(derive) > 0 && EVP_PKEY_derive_set_peer(derive, peer) > 0 && EVP_PKEY_derive(derive, session_secret, &secret_length) > 0 && secret_length == sizeof(session_secret);
    EVP_PKEY_CTX_free(derive); EVP_PKEY_free(peer);
    return ok;
}

static bool encrypt_claim(const char *claim, char *nonce_b64, size_t nonce_cap, char *cipher_b64, size_t cipher_cap, char *tag_b64, size_t tag_cap) {
    unsigned char nonce[12], ciphertext[256], tag[16];
    if (strlen(claim) > sizeof(ciphertext)) return false;
    if (RAND_bytes(nonce, sizeof(nonce)) != 1) return false;
    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx || EVP_EncryptInit_ex(ctx, EVP_aes_256_gcm(), NULL, NULL, NULL) <= 0 || EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_SET_IVLEN, sizeof(nonce), NULL) <= 0 || EVP_EncryptInit_ex(ctx, NULL, NULL, session_secret, nonce) <= 0) { EVP_CIPHER_CTX_free(ctx); return false; }
    int length = 0, final_length = 0;
    bool ok = EVP_EncryptUpdate(ctx, ciphertext, &length, (const unsigned char *)claim, (int)strlen(claim)) > 0 && EVP_EncryptFinal_ex(ctx, ciphertext + length, &final_length) > 0 && EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_GCM_GET_TAG, sizeof(tag), tag) > 0;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok) return false;
    return b64_encode(nonce, sizeof(nonce), nonce_b64, nonce_cap) && b64_encode(ciphertext, (size_t)(length + final_length), cipher_b64, cipher_cap) && b64_encode(tag, sizeof(tag), tag_b64, tag_cap);
}

static void send_handshake(int fd, const struct sockaddr_in *peer, socklen_t peer_len, const char *request_id, const char *timestamp, const char *nonce, const char *app_key) {
    fprintf(stderr, "[UDP] handshake accepted requestId=%s\n", request_id);
    char device_key[128];
    if (!derive_session(app_key, device_key, sizeof(device_key))) { fprintf(stderr, "[UDP] handshake key derivation failed requestId=%s\n", request_id); return; }
    if (!random_hex(lan_session_id, 32)) return;
    lan_session_expires = time(NULL) + 600;
    char body[512];
    snprintf(body, sizeof(body), "{\"deviceEphemeralPublicKey\":\"%s\",\"lanSessionId\":\"%s\",\"expiresAt\":%lld,\"apiBase\":\"/api/v2\"}", device_key, lan_session_id, (long long)lan_session_expires);
    char transcript[2048], signature[1024];
    snprintf(transcript, sizeof(transcript), "1|handshake_response|%s|%s|%s|%s", request_id, timestamp, nonce, body);
    if (!sign_text(device_signing_key, transcript, signature, sizeof(signature))) return;
    char packet[PACKET_MAX];
    int length = snprintf(packet, sizeof(packet), "{\"version\":1,\"type\":\"handshake_response\",\"requestId\":\"%s\",\"timestamp\":%lld,\"deviceId\":\"%s\",\"body\":%s,\"signature\":\"%s\"}", request_id, (long long)time(NULL) * 1000, device_id, body, signature);
    if (length > 0) sendto(fd, packet, (size_t)length, 0, (const struct sockaddr *)peer, peer_len);
}

static void send_pairing_result(int fd, const struct sockaddr_in *peer, socklen_t peer_len, const char *request_id) {
    if (!lan_session_id[0] || time(NULL) >= lan_session_expires) { fprintf(stderr, "[UDP] pairing session expired requestId=%s\n", request_id); return; }
    fprintf(stderr, "[UDP] pairing accepted requestId=%s\n", request_id);
    char claim[65], plaintext[256], nonce[128], ciphertext[512], tag[128];
    if (!random_hex(claim, 32)) return;
    long long expires_at = (long long)time(NULL) + 300;
    char path[256], claim_body[512], response[2048];
    snprintf(path, sizeof(path), "/api/v2/devices/%s/claim/prepare", device_id);
    snprintf(claim_body, sizeof(claim_body), "{\"claimString\":\"%s\",\"requestId\":\"%s\",\"expiresAt\":%lld}", claim, request_id, expires_at);
    if (!cloud_request(path, claim_body, cloud_device_token, response, sizeof(response))) { fprintf(stderr, "claim preparation failed\n"); return; }
    snprintf(plaintext, sizeof(plaintext), "{\"claimString\":\"%s\",\"deviceId\":\"%s\",\"requestId\":\"%s\",\"expiresAt\":%lld}", claim, device_id, request_id, expires_at);
    if (!encrypt_claim(plaintext, nonce, sizeof(nonce), ciphertext, sizeof(ciphertext), tag, sizeof(tag))) return;
    char body[768];
    snprintf(body, sizeof(body), "{\"requestId\":\"%s\",\"keyId\":\"%s\",\"algorithm\":\"AES-256-GCM\",\"nonce\":\"%s\",\"ciphertext\":\"%s\",\"tag\":\"%s\",\"expiresAt\":%lld}", request_id, device_id, nonce, ciphertext, tag, (long long)time(NULL) + 300);
    char packet[PACKET_MAX];
    int length = snprintf(packet, sizeof(packet), "{\"version\":1,\"type\":\"pairing_result\",\"requestId\":\"%s\",\"timestamp\":%lld,\"deviceId\":\"%s\",\"body\":%s}", request_id, (long long)time(NULL) * 1000, device_id, body);
    if (length > 0) sendto(fd, packet, (size_t)length, 0, (const struct sockaddr *)peer, peer_len);
}

static bool cloud_request(const char *path, const char *body, const char *token, char *response, size_t response_cap) {
    if (!response || !response_cap) return false;
    response[0] = 0;
    if (!response || response_cap == 0) return false;
    response[0] = 0;
    char host[128]; int port = 0;
    bool tls = !strncmp(cloud_url, "https://", 8);
    if ((!tls && strncmp(cloud_url, "http://", 7)) || !parse_cloud_host(cloud_url, host, sizeof(host), &port)) return false;
    char port_text[16]; snprintf(port_text, sizeof(port_text), "%d", port);
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}; struct addrinfo *addresses = NULL;
    if (getaddrinfo(host, port_text, &hints, &addresses) != 0) return false;
    int fd = -1; for (struct addrinfo *it = addresses; it; it = it->ai_next) { fd = socket(it->ai_family, it->ai_socktype, it->ai_protocol); if (fd >= 0 && connect(fd, it->ai_addr, it->ai_addrlen) == 0) break; if (fd >= 0) { close(fd); fd = -1; } }
    freeaddrinfo(addresses); if (fd < 0) return false;
    struct timeval timeout = {.tv_sec = 5, .tv_usec = 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    SSL_CTX *ctx = NULL; SSL *ssl = NULL;
    if (tls) {
        ctx = SSL_CTX_new(TLS_client_method());
        if (!ctx) { close(fd); return false; }
        if (tls_insecure) SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
        else if (SSL_CTX_load_verify_locations(ctx, ca_file, NULL) != 1) { SSL_CTX_free(ctx); close(fd); return false; }
        if (!tls_insecure) SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
    ssl = SSL_new(ctx);
        if (!ssl || SSL_set_tlsext_host_name(ssl, host) != 1 || (!tls_insecure && !tls_peer_identity(ssl, host)) || SSL_set_fd(ssl, fd) != 1 || SSL_connect(ssl) != 1) { SSL_free(ssl); SSL_CTX_free(ctx); close(fd); return false; }
    }
    char request_path[512]; int path_length = snprintf(request_path, sizeof(request_path), "%s%s", cloud_base_path, path);
    if (path_length <= 0 || (size_t)path_length >= sizeof(request_path)) { if (ssl) { SSL_free(ssl); SSL_CTX_free(ctx); } close(fd); return false; }
    char request[4096]; int length = snprintf(request, sizeof(request), "POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n%s%s%s\r\n%s", request_path, host, strlen(body), token && *token ? "X-Device-Token: " : "", token && *token ? token : "", token && *token ? "\r\n" : "", body);
    if (length <= 0 || (size_t)length >= sizeof(request)) { SSL_free(ssl); SSL_CTX_free(ctx); close(fd); return false; }
    size_t sent = 0; while (length > 0 && sent < (size_t)length) { int n = tls ? SSL_write(ssl, request + sent, (int)((size_t)length - sent)) : (int)send(fd, request + sent, (size_t)length - sent, 0); if (n <= 0) break; sent += (size_t)n; }
    bool ok = length > 0 && sent == (size_t)length;
    size_t used = 0; if (ok) while (used + 1 < response_cap) { int n = tls ? SSL_read(ssl, response + used, (int)(response_cap - used - 1)) : (int)recv(fd, response + used, response_cap - used - 1, 0); if (n <= 0) break; used += (size_t)n; }
    if (ssl) { SSL_shutdown(ssl); SSL_free(ssl); }
    if (ctx) SSL_CTX_free(ctx);
    close(fd); response[used] = 0; int status = 0; (void)sscanf(response, "HTTP/%*s %d", &status); fprintf(stderr, "[CLOUD] path=%s status=%d bytes=%zu\n", path, status, used); return ok && status >= 200 && status < 300;
}

static bool public_key_b64(EVP_PKEY *key, char *output, size_t capacity) {
    unsigned char raw[64]; size_t length = sizeof(raw);
    return EVP_PKEY_get_raw_public_key(key, raw, &length) > 0 && b64_encode(raw, length, output, capacity);
}

static void cloud_register(EVP_PKEY *key) {
    char public_key[256], body[768], response[4096];
    if (!public_key_b64(key, public_key, sizeof(public_key))) return;
    snprintf(body, sizeof(body), "{\"deviceId\":\"%s\",\"name\":\"%s\",\"publicKey\":\"%s\"}", device_id, device_name, public_key);
    bool registered = cloud_request("/api/v2/devices/register", body, cloud_device_token, response, sizeof(response));
    if (!registered && strstr(response, "40906")) { cloud_device_token[0] = 0; registered = cloud_request("/api/v2/devices/register", body, "", response, sizeof(response)); }
    if (registered && extract_string(response, "deviceToken", cloud_device_token, sizeof(cloud_device_token))) save_device_token();
    fprintf(stdout, "cloud registration %s\n", registered && cloud_device_token[0] ? "succeeded" : "failed");
}

static void cloud_heartbeat(void) {
    if (!cloud_device_token[0]) return;
    char path[256], response[2048]; char body[512];
    snprintf(path, sizeof(path), "/api/v2/devices/%s/heartbeat", device_id);
    snprintf(body, sizeof(body), "{\"agentVersion\":\"0.1.0\",\"status\":\"online\",\"ip\":\"\",\"storageFree\":0,\"storageTotal\":0}");
    cloud_request(path, body, cloud_device_token, response, sizeof(response));
}

static void *heartbeat_worker(void *unused) {
    (void)unused;
    for (;;) { sleep(30); cloud_heartbeat(); }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--config-info")) {
#ifdef SE9_WITH_WEBRTC
        return se9_print_config_info(true);
#else
        return se9_print_config_info(false);
#endif
    }
    if (argc != 1) { fprintf(stderr, "usage: se9_agent [--config-info]\n"); return 1; }
    const char *env;
    if ((env = getenv("SE9_KEY_FILE")) && *env) snprintf(key_file, sizeof(key_file), "%s", env);
    if ((env = getenv("SE9_DEVICE_NAME")) && *env) snprintf(device_name, sizeof(device_name), "%s", env);
    if ((env = getenv("FILE_API_PORT")) && *env) api_port = atoi(env);
    if ((env = getenv("SE9_CLOUD_URL")) && *env) snprintf(cloud_url, sizeof(cloud_url), "%s", env);
    if ((env = getenv("SE9_CLOUD_BASE_PATH"))) snprintf(cloud_base_path, sizeof(cloud_base_path), "%s", env);
    if ((env = getenv("SE9_TOKEN_FILE")) && *env) snprintf(token_file, sizeof(token_file), "%s", env);
    if (!se9_load_proxy_token(proxy_token, sizeof(proxy_token))) { fprintf(stderr, "cannot load local proxy key; create /var/lib/se9 with service ownership or check SE9_AGENT_PROXY_TOKEN_FILE\n"); return 1; }
    if ((env = getenv("SE9_CA_FILE")) && *env) snprintf(ca_file, sizeof(ca_file), "%s", env);
    if ((env = getenv("SE9_TLS_INSECURE")) && !strcmp(env, "1")) tls_insecure = true;
    EVP_PKEY *key = load_or_create_key();
    if (!key || !init_device_id(key)) { fprintf(stderr, "cannot initialize device identity\n"); return 1; }
    device_signing_key = key;
    load_device_token();
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return 1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_ANY), .sin_port = htons(UDP_PORT)};
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) < 0) { perror("bind"); return 1; }
    signal(SIGPIPE, SIG_IGN);
    fprintf(stdout, "SE9 Agent UDP discovery listening on 0.0.0.0:%d, device=%s\n", UDP_PORT, device_id);
    cloud_register(key);
    if (!cloud_device_token[0]) { fprintf(stderr, "cloud registration failed; restart after checking network and certificate trust\n"); return 1; }
#ifdef SE9_WITH_WEBRTC
    if (!se9_rtc_start(device_id, key, cloud_device_token, cloud_url, cloud_base_path, api_port, proxy_token, ca_file)) { fprintf(stderr, "[RTC] initialization failed; check key and configuration\n"); return 1; }
#endif
    pthread_t relay_thread;
    if (pthread_create(&relay_thread, NULL, websocket_worker, NULL) == 0) pthread_detach(relay_thread);
    pthread_t heartbeat_thread;
    if (pthread_create(&heartbeat_thread, NULL, heartbeat_worker, NULL) != 0) { fprintf(stderr, "cannot start cloud heartbeat worker\n"); return 1; }
    pthread_detach(heartbeat_thread);
    for (;;) {
        char packet[PACKET_MAX];
        struct sockaddr_in peer;
        socklen_t peer_len = sizeof(peer);
        fd_set read_set; FD_ZERO(&read_set); FD_SET(fd, &read_set);
        struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
        int ready = select(fd + 1, &read_set, NULL, NULL, &timeout);
        if (ready <= 0 || !FD_ISSET(fd, &read_set)) continue;
        ssize_t length = recvfrom(fd, packet, sizeof(packet) - 1, 0, (struct sockaddr *)&peer, &peer_len);
        if (length <= 0) continue;
        packet[length] = 0;
        char type[64], request_id[128], timestamp[64], nonce[128];
        if (!extract_string(packet, "type", type, sizeof(type)) || !extract_string(packet, "requestId", request_id, sizeof(request_id))) continue;
        if (!extract_number(packet, "timestamp", timestamp, sizeof(timestamp)) || !accept_request(request_id, timestamp)) { fprintf(stderr, "[UDP] rejected timestamp/replay type=%s requestId=%s serverTime=%lld\n", type, request_id, (long long)time(NULL)); continue; }
        fprintf(stderr, "[UDP] received type=%s requestId=%s peer=%s:%u\n", type, request_id, inet_ntoa(peer.sin_addr), ntohs(peer.sin_port));
        if (!extract_string(packet, "nonce", nonce, sizeof(nonce))) nonce[0] = 0;
        if (!strcmp(type, "discover_request")) send_response(fd, &peer, peer_len, key, type, request_id, timestamp, nonce);
        else if (!strcmp(type, "handshake_request")) { char app_key[256]; if (extract_string(packet, "appEphemeralPublicKey", app_key, sizeof(app_key))) send_handshake(fd, &peer, peer_len, request_id, timestamp, nonce, app_key); }
        else if (!strcmp(type, "pairing_request")) { char session_id[128]; if (extract_string(packet, "lanSessionId", session_id, sizeof(session_id)) && !strcmp(session_id, lan_session_id)) send_pairing_result(fd, &peer, peer_len, request_id); }
    }
}
