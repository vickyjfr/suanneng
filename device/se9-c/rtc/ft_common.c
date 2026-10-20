#define _POSIX_C_SOURCE 200809L
#include "ft_common.h"
#include <errno.h>
#include <inttypes.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
const char *ft_string(const cJSON *value,const char *name){const cJSON *item=cJSON_GetObjectItemCaseSensitive(value,name);return cJSON_IsString(item)?item->valuestring:"";}
bool ft_u64(const cJSON *value,const char *name,uint64_t *number){const char *s=ft_string(value,name);if(!*s||strlen(s)>20)return false;for(const char*p=s;*p;p++)if(*p<'0'||*p>'9')return false;errno=0;char*end=NULL;unsigned long long n=strtoull(s,&end,10);if(errno||!end||*end)return false;*number=(uint64_t)n;return true;}
void ft_number(cJSON *value,const char *name,uint64_t number){char text[32];snprintf(text,sizeof(text),"%" PRIu64,number);cJSON_AddStringToObject(value,name,text);}
bool ft_hex(const char *value,size_t bytes){if(!value||strlen(value)!=bytes*2)return false;for(size_t i=0;i<bytes*2;i++)if(!((value[i]>='0'&&value[i]<='9')||(value[i]>='a'&&value[i]<='f')))return false;return true;}
bool ft_random_hex(char *output,size_t bytes){if(bytes>64)return false;unsigned char raw[64];if(RAND_bytes(raw,(int)bytes)!=1)return false;for(size_t i=0;i<bytes;i++)snprintf(output+i*2,3,"%02x",raw[i]);return true;}
static void digest_hex(const unsigned char *raw,char output[65]){for(size_t i=0;i<32;i++)snprintf(output+i*2,3,"%02x",raw[i]);}
bool ft_sha256(const void *data,size_t length,char output[65]){unsigned char raw[EVP_MAX_MD_SIZE];unsigned int size=0;if(EVP_Digest(data,length,raw,&size,EVP_sha256(),NULL)!=1||size!=32)return false;digest_hex(raw,output);return true;}
bool ft_hash_fd(int fd,char output[65]){EVP_MD_CTX *ctx=EVP_MD_CTX_new();if(!ctx)return false;bool ok=EVP_DigestInit_ex(ctx,EVP_sha256(),NULL)==1;unsigned char buffer[65536];off_t offset=0;while(ok){ssize_t n=pread(fd,buffer,sizeof(buffer),offset);if(n<0&&errno==EINTR)continue;if(n<0){ok=false;break;}if(n==0)break;ok=EVP_DigestUpdate(ctx,buffer,(size_t)n)==1;offset+=n;}unsigned char raw[32];unsigned int size=0;if(ok)ok=EVP_DigestFinal_ex(ctx,raw,&size)==1&&size==32;EVP_MD_CTX_free(ctx);if(ok)digest_hex(raw,output);return ok;}
char *ft_base64(const void *data,size_t length,bool url){if(length>1048576)return NULL;size_t capacity=4*((length+2)/3)+1;char *result=malloc(capacity);if(!result)return NULL;int n=EVP_EncodeBlock((unsigned char*)result,data,(int)length);if(n<0){free(result);return NULL;}if(url){for(int i=0;i<n;i++){if(result[i]=='+')result[i]='-';else if(result[i]=='/')result[i]='_';}while(n&&result[n-1]=='=')result[--n]=0;}return result;}
unsigned char *ft_decode64(const char *input,size_t *length,bool url){size_t n=strlen(input);if(n>1048576||n%4==1)return NULL;size_t padded=(n+3)/4*4;char *copy=malloc(padded+1);unsigned char *output=malloc(padded/4*3+1);if(!copy||!output){free(copy);free(output);return NULL;}for(size_t i=0;i<n;i++){char c=input[i];if(url&&c=='-')c='+';if(url&&c=='_')c='/';copy[i]=c;}for(size_t i=n;i<padded;i++)copy[i]='=';copy[padded]=0;int size=EVP_DecodeBlock(output,(unsigned char*)copy,(int)padded);if(size>=0){if(padded&&copy[padded-1]=='=')size--;if(padded>1&&copy[padded-2]=='=')size--;}free(copy);if(size<0){free(output);return NULL;}*length=(size_t)size;output[size]=0;return output;}
bool ft_constant_equal(const char *a,const char *b){size_t n=strlen(a);return n==strlen(b)&&CRYPTO_memcmp(a,b,n)==0;}
static uint32_t get32(const unsigned char *p){return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];}
static void put32(unsigned char *p,uint32_t n){p[0]=(unsigned char)(n>>24);p[1]=(unsigned char)(n>>16);p[2]=(unsigned char)(n>>8);p[3]=(unsigned char)n;}
bool ft_frame_read(const void *data,size_t length,char id[33],uint32_t *epoch,uint32_t *sequence,uint64_t *offset,const unsigned char **payload,size_t *payload_length){if(length<48||length>SE9_FT_FRAME)return false;const unsigned char *p=data;if(memcmp(p,"S9FT",4)||p[4]!=1||p[5]!=1||p[6]||p[7]||get32(p+44)||get32(p+40)!=length-48)return false;for(size_t i=0;i<16;i++)snprintf(id+i*2,3,"%02x",p[8+i]);*epoch=get32(p+24);*sequence=get32(p+28);*offset=((uint64_t)get32(p+32)<<32)|get32(p+36);*payload=p+48;*payload_length=length-48;return *epoch>0&&*payload_length>0&&(*offset%SE9_FT_BLOCK)+*payload_length<=SE9_FT_BLOCK;}
size_t ft_frame_write(void *data,size_t capacity,const char *id,uint32_t epoch,uint32_t sequence,uint64_t offset,const void *payload,size_t length){if(!ft_hex(id,16)||!epoch||length==0||length>SE9_FT_FRAME-48||capacity<48+length||offset%SE9_FT_BLOCK+length>SE9_FT_BLOCK)return 0;unsigned char *p=data;memset(p,0,48);memcpy(p,"S9FT",4);p[4]=1;p[5]=1;for(size_t i=0;i<16;i++){char text[3]={id[i*2],id[i*2+1],0};p[8+i]=(unsigned char)strtoul(text,NULL,16);}put32(p+24,epoch);put32(p+28,sequence);put32(p+32,(uint32_t)(offset>>32));put32(p+36,(uint32_t)offset);put32(p+40,(uint32_t)length);memcpy(p+48,payload,length);return 48+length;}
