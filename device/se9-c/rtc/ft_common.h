#ifndef SE9_FT_COMMON_H
#define SE9_FT_COMMON_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <cJSON.h>
#define SE9_FT_FRAME 16384
#define SE9_FT_HEADER 48
#define SE9_FT_BLOCK 1048576
const char *ft_string(const cJSON *value, const char *name);
bool ft_u64(const cJSON *value, const char *name, uint64_t *number);
void ft_number(cJSON *value, const char *name, uint64_t number);
bool ft_hex(const char *value, size_t bytes);
bool ft_random_hex(char *output, size_t bytes);
bool ft_sha256(const void *data, size_t length, char output[65]);
bool ft_hash_fd(int fd, char output[65]);
char *ft_base64(const void *data, size_t length, bool url);
unsigned char *ft_decode64(const char *input, size_t *length, bool url);
bool ft_constant_equal(const char *a, const char *b);
bool ft_frame_read(const void *data, size_t length, char id[33], uint32_t *epoch, uint32_t *sequence, uint64_t *offset, const unsigned char **payload, size_t *payload_length);
size_t ft_frame_write(void *data, size_t capacity, const char *id, uint32_t epoch, uint32_t sequence, uint64_t offset, const void *payload, size_t length);
#endif
