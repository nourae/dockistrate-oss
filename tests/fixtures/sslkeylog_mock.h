#ifndef DOCKISTRATE_SSLKEYLOG_MOCK_H
#define DOCKISTRATE_SSLKEYLOG_MOCK_H

#include <stdio.h>

/* Minimal public ABI for exercising the interposer without OpenSSL headers. */
typedef struct ssl_st SSL;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct crypto_ex_data_st CRYPTO_EX_DATA;
typedef void (*SSL_CTX_keylog_cb_func)(const SSL *, const char *);
typedef void CRYPTO_EX_new(void *, void *, CRYPTO_EX_DATA *, int, long, void *);
typedef int CRYPTO_EX_dup(CRYPTO_EX_DATA *, const CRYPTO_EX_DATA *, void **, int, long, void *);
typedef void CRYPTO_EX_free(void *, void *, CRYPTO_EX_DATA *, int, long, void *);
#define TLS1_2_VERSION 0x0303
#define TLS1_3_VERSION 0x0304

SSL_CTX *SSL_CTX_new(const void *method);
void SSL_CTX_free(SSL_CTX *ctx);
SSL *SSL_new(SSL_CTX *ctx);
void SSL_free(SSL *ssl);
SSL_CTX *SSL_set_SSL_CTX(SSL *ssl, SSL_CTX *ctx);
SSL_CTX *SSL_get_SSL_CTX(const SSL *ssl);
void SSL_CTX_set_keylog_callback(SSL_CTX *ctx, SSL_CTX_keylog_cb_func callback);
SSL_CTX_keylog_cb_func SSL_CTX_get_keylog_callback(const SSL_CTX *ctx);
int SSL_CTX_set_ex_data(SSL_CTX *ctx, int index, void *data);
void *SSL_CTX_get_ex_data(const SSL_CTX *ctx, int index);
int CRYPTO_get_ex_new_index(int class_index, long argl, void *argp,
    CRYPTO_EX_new *new_func, CRYPTO_EX_dup *dup_func, CRYPTO_EX_free *free_func);
void ERR_print_errors_fp(FILE *stream);
void mock_emit_records(SSL *ssl, int version, const char *random);

#endif
