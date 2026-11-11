#include "sslkeylog_mock.h"

#include <stdlib.h>
#include <string.h>

struct ssl_ctx_st {
  SSL_CTX_keylog_cb_func callback;
  void *ex_data[16];
};
struct ssl_st { SSL_CTX *ctx; };
static CRYPTO_EX_free *free_callbacks[16];
static int next_index;

SSL_CTX *SSL_CTX_new(const void *method) {
  (void)method;
  return calloc(1, sizeof(SSL_CTX));
}

void SSL_CTX_free(SSL_CTX *ctx) {
  int i;
  for (i = 0; i < next_index; i++) {
    if (free_callbacks[i] != NULL) {
      free_callbacks[i](ctx, ctx->ex_data[i], NULL, i, 0, NULL);
    }
  }
  free(ctx);
}

SSL *SSL_new(SSL_CTX *ctx) {
  SSL *ssl = malloc(sizeof(SSL));
  if (ssl != NULL) {
    ssl->ctx = ctx;
  }
  return ssl;
}

void SSL_free(SSL *ssl) { free(ssl); }

SSL_CTX *SSL_set_SSL_CTX(SSL *ssl, SSL_CTX *ctx) {
  ssl->ctx = ctx;
  return ctx;
}

SSL_CTX *SSL_get_SSL_CTX(const SSL *ssl) { return ssl->ctx; }

void SSL_CTX_set_keylog_callback(SSL_CTX *ctx, SSL_CTX_keylog_cb_func callback) {
  ctx->callback = callback;
}

SSL_CTX_keylog_cb_func SSL_CTX_get_keylog_callback(const SSL_CTX *ctx) {
  return ctx->callback;
}

int SSL_CTX_set_ex_data(SSL_CTX *ctx, int index, void *data) {
  if (index < 0 || index >= 16) {
    return 0;
  }
  ctx->ex_data[index] = data;
  return 1;
}

void *SSL_CTX_get_ex_data(const SSL_CTX *ctx, int index) {
  return index < 0 || index >= 16 ? NULL : ctx->ex_data[index];
}

int CRYPTO_get_ex_new_index(int class_index, long argl, void *argp,
    CRYPTO_EX_new *new_func, CRYPTO_EX_dup *dup_func, CRYPTO_EX_free *free_func) {
  (void)argl;
  (void)argp;
  (void)new_func;
  (void)dup_func;
  if (class_index != 1 || next_index >= 16) {
    return -1;
  }
  free_callbacks[next_index] = free_func;
  return next_index++;
}

void ERR_print_errors_fp(FILE *stream) { (void)stream; }

void mock_emit_records(SSL *ssl, int version, const char *random) {
  const char *labels[] = {"SERVER_HANDSHAKE_TRAFFIC_SECRET", "CLIENT_HANDSHAKE_TRAFFIC_SECRET",
    "EXPORTER_SECRET", "SERVER_TRAFFIC_SECRET_0", "CLIENT_TRAFFIC_SECRET_0"};
  char secret[97];
  char record[256];
  int i;
  memset(secret, 'a', sizeof(secret) - 1);
  secret[sizeof(secret) - 1] = '\0';
  for (i = 0; i < (version == TLS1_2_VERSION ? 1 : 5); i++) {
    snprintf(record, sizeof(record), "%s %s %s",
      version == TLS1_2_VERSION ? "CLIENT_RANDOM" : labels[i], random, secret);
    if (ssl->ctx->callback != NULL) {
      ssl->ctx->callback(ssl, record);
    }
  }
}
