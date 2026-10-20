#ifndef SE9_RTC_SOCKET_H
#define SE9_RTC_SOCKET_H
#include <stdbool.h>
#include <stddef.h>
#include <openssl/ssl.h>
typedef struct {int fd;SSL_CTX *ctx;SSL *ssl;} ft_socket;
bool ft_socket_open(ft_socket *socket,const char *url,const char *path,const char *header_name,const char *token,const char *ca_file,bool allow_local);
void ft_socket_close(ft_socket *socket);
bool ft_socket_send(ft_socket *socket,unsigned char opcode,const void *body,size_t length);
int ft_socket_receive(ft_socket *socket,unsigned char **body,size_t *length);
#endif
