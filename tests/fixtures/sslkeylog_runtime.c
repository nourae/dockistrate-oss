#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#ifdef KEYLOG_RUNTIME_MOCK
#include "sslkeylog_mock.h"
#else
#include <openssl/err.h>
#include <openssl/ssl.h>
#endif
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

typedef void (*keylog_callback)(const SSL *, const char *);
static SSL *(*helper_ssl_new)(SSL_CTX *);
static SSL_CTX *(*helper_set_context)(SSL *, SSL_CTX *);
static void (*helper_set_callback)(SSL_CTX *, keylog_callback);
static keylog_callback (*helper_get_callback)(const SSL_CTX *);
static SSL_CTX *server_contexts[3];
static SSL_CTX *client_context;
static unsigned callback_counts[3];
static int context_switches;
static int protocol_version;

static void require(int condition, const char *message) {
  if (!condition) {
    fprintf(stderr, "TLS keylog runtime: %s\n", message);
    ERR_print_errors_fp(stderr);
    exit(1);
  }
}

static void callback_a(const SSL *ssl, const char *line) {
  require(line != NULL && *line != '\0', "empty application callback record");
  require(helper_get_callback(SSL_get_SSL_CTX(ssl)) == callback_a,
    "application callback could not query its own registration");
  /* Applications may call OpenSSL callback APIs while handling a keylog line. */
  helper_set_callback(SSL_get_SSL_CTX(ssl), callback_a);
  callback_counts[0]++;
}

static void callback_b(const SSL *ssl, const char *line) {
  require(line != NULL && *line != '\0', "empty application callback record");
  require(helper_get_callback(SSL_get_SSL_CTX(ssl)) == callback_b,
    "second application callback registration was not preserved");
  callback_counts[1]++;
}

static void callback_c(const SSL *ssl, const char *line) {
  require(line != NULL && *line != '\0', "empty application callback record");
  require(helper_get_callback(SSL_get_SSL_CTX(ssl)) == callback_c,
    "third application callback registration was not preserved");
  callback_counts[2]++;
}

#ifndef KEYLOG_RUNTIME_MOCK
static int select_server_context(SSL *ssl, int *alert, void *arg) {
  const char *name = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
  SSL_CTX *selected = NULL;
  (void)alert;
  (void)arg;
  if (name != NULL && strcmp(name, "first.example.com") == 0) {
    selected = server_contexts[1];
  } else if (name != NULL && strcmp(name, "second.example.com") == 0) {
    selected = server_contexts[2];
  }
  if (selected != NULL) {
    require(helper_set_context(ssl, selected) == selected, "SNI context switch failed");
    context_switches++;
  }
  return SSL_TLSEXT_ERR_OK;
}
#endif

static void initialize_contexts(int version) {
#ifdef KEYLOG_RUNTIME_MOCK
  unsigned i;
  (void)version;
  for (i = 0; i < 3; i++) {
    server_contexts[i] = SSL_CTX_new(NULL);
    require(server_contexts[i] != NULL, "mock server allocation failed");
  }
  client_context = SSL_CTX_new(NULL);
  require(client_context != NULL, "mock client allocation failed");
#else
  EVP_PKEY_CTX *generator = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, NULL);
  EVP_PKEY *key = NULL;
  X509 *certificate = X509_new();
  X509_NAME *subject = X509_NAME_new();
  unsigned i;

  require(generator != NULL && certificate != NULL && subject != NULL,
    "certificate allocation failed");
  require(EVP_PKEY_keygen_init(generator) == 1 &&
      EVP_PKEY_CTX_set_ec_paramgen_curve_nid(generator, NID_X9_62_prime256v1) == 1 &&
      EVP_PKEY_keygen(generator, &key) == 1, "test key generation failed");
  require(X509_set_version(certificate, 2) == 1 &&
      ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1) == 1 &&
      X509_gmtime_adj(X509_getm_notBefore(certificate), -60) != NULL &&
      X509_gmtime_adj(X509_getm_notAfter(certificate), 3600) != NULL &&
      X509_set_pubkey(certificate, key) == 1, "certificate initialization failed");
  /* Own the mutable name rather than modifying a borrowed certificate name. */
  require(X509_NAME_add_entry_by_txt(subject, "CN", MBSTRING_ASC,
      (const unsigned char *)"example.com", -1, -1, 0) == 1 &&
      X509_set_subject_name(certificate, subject) == 1 &&
      X509_set_issuer_name(certificate, subject) == 1 &&
      X509_sign(certificate, key, EVP_sha256()) > 0, "certificate signing failed");
  X509_NAME_free(subject);

  for (i = 0; i < 3; i++) {
    server_contexts[i] = SSL_CTX_new(TLS_server_method());
    require(server_contexts[i] != NULL, "server context allocation failed");
    require(SSL_CTX_set_min_proto_version(server_contexts[i], version) == 1 &&
        SSL_CTX_set_max_proto_version(server_contexts[i], version) == 1 &&
        SSL_CTX_use_certificate(server_contexts[i], certificate) == 1 &&
        SSL_CTX_use_PrivateKey(server_contexts[i], key) == 1,
      "server context initialization failed");
  }
  SSL_CTX_set_tlsext_servername_callback(server_contexts[0], select_server_context);
  client_context = SSL_CTX_new(TLS_client_method());
  require(client_context != NULL &&
      SSL_CTX_set_min_proto_version(client_context, version) == 1 &&
      SSL_CTX_set_max_proto_version(client_context, version) == 1,
    "client context initialization failed");
  SSL_CTX_set_verify(client_context, SSL_VERIFY_NONE, NULL);
  EVP_PKEY_CTX_free(generator);
  EVP_PKEY_free(key);
  X509_free(certificate);
#endif
}

#ifndef KEYLOG_RUNTIME_MOCK
static void handshake_step(SSL *ssl) {
  int result = SSL_do_handshake(ssl);
  int error;
  if (result == 1) {
    return;
  }
  error = SSL_get_error(ssl, result);
  require(error == SSL_ERROR_WANT_READ || error == SSL_ERROR_WANT_WRITE,
    "TLS handshake failed");
}
#endif

static void handshake(const char *name, unsigned selected, int expected_callback) {
  SSL *server = helper_ssl_new(server_contexts[0]);
#ifdef KEYLOG_RUNTIME_MOCK
  static unsigned sequence;
  char random_hex[65];
  unsigned i;
  memset(callback_counts, 0, sizeof(callback_counts));
  require(server != NULL, "mock SSL allocation failed");
  if (selected != 0) {
    require(helper_set_context(server, server_contexts[selected]) == server_contexts[selected],
      "mock SNI context switch failed");
    context_switches++;
  }
  snprintf(random_hex, sizeof(random_hex), "%032lx%032x", (unsigned long)getpid(), ++sequence);
  mock_emit_records(server, protocol_version, random_hex);
#else
  /* The client uses libssl directly; only server records may reach the helper. */
  SSL *client = SSL_new(client_context);
  BIO *server_bio = NULL;
  BIO *client_bio = NULL;
  unsigned char random[SSL3_RANDOM_SIZE];
  char random_hex[SSL3_RANDOM_SIZE * 2 + 1];
  char payload[5];
  unsigned i;
  int attempts;
  int switches_before = context_switches;

  memset(callback_counts, 0, sizeof(callback_counts));
  require(server != NULL && client != NULL, "SSL allocation failed");
  require(BIO_new_bio_pair(&server_bio, 0, &client_bio, 0) == 1, "BIO pair failed");
  SSL_set_bio(server, server_bio, server_bio);
  SSL_set_bio(client, client_bio, client_bio);
  SSL_set_accept_state(server);
  SSL_set_connect_state(client);
  if (name != NULL) {
    require(SSL_set_tlsext_host_name(client, name) == 1, "SNI setup failed");
  }
  for (attempts = 0; attempts < 1000; attempts++) {
    handshake_step(client);
    handshake_step(server);
    if (SSL_is_init_finished(client) && SSL_is_init_finished(server)) {
      break;
    }
  }
  require(attempts < 1000, "TLS handshake did not complete");
  require(SSL_get_SSL_CTX(server) == server_contexts[selected], "wrong SNI context selected");
  require(context_switches - switches_before == (selected == 0 ? 0 : 1),
    "SNI did not perform the expected context switch");
  require(SSL_write(client, "hello", 5) == 5 && SSL_read(server, payload, 5) == 5 &&
      memcmp(payload, "hello", 5) == 0, "TLS application data exchange failed");
#endif
  for (i = 0; i < 3; i++) {
    require(callback_counts[i] == ((int)i == expected_callback ?
        (protocol_version == TLS1_2_VERSION ? 1U : 5U) : 0U),
      "application keylog callback was lost, duplicated across contexts, or not cleared");
  }
#ifndef KEYLOG_RUNTIME_MOCK
  require(SSL_get_client_random(server, random, sizeof(random)) == sizeof(random),
    "could not obtain handshake random");
  for (i = 0; i < sizeof(random); i++) {
    snprintf(random_hex + i * 2, 3, "%02x", random[i]);
  }
  SSL_free(client);
#endif
  printf("HANDSHAKE %s %s %s\n", name != NULL ? name : "default",
    protocol_version == TLS1_2_VERSION ? "TLSv1.2" : "TLSv1.3", random_hex);
  fflush(stdout);
  SSL_free(server);
}

static void exercise_contexts(void) {
  /* A callback registered before helper installation must also survive wrapping. */
  SSL_CTX_set_keylog_callback(server_contexts[0], callback_a);
  /* This context must first be instrumented by the SNI switch, not the setter. */
  SSL_CTX_set_keylog_callback(server_contexts[1], callback_b);
  helper_set_callback(server_contexts[2], callback_c);
  require(helper_get_callback(server_contexts[0]) == callback_a &&
      helper_get_callback(server_contexts[1]) == callback_b &&
      helper_get_callback(server_contexts[2]) == callback_c, "callback getter changed application state");
  handshake(NULL, 0, 0);
  handshake("first.example.com", 1, 1);
  handshake("second.example.com", 2, 2);
  require(helper_get_callback(server_contexts[0]) == callback_a &&
      helper_get_callback(server_contexts[1]) == callback_b &&
      helper_get_callback(server_contexts[2]) == callback_c, "installed wrapper leaked through callback getter");
  helper_set_callback(server_contexts[1], callback_a);
  require(helper_get_callback(server_contexts[1]) == callback_a, "callback replacement was ignored");
  handshake("first.example.com", 1, 0);
  helper_set_callback(server_contexts[1], NULL);
  require(helper_get_callback(server_contexts[1]) == NULL, "callback removal was ignored");
  handshake("first.example.com", 1, -1);
}

static void require_private_append_descriptor(const char *path) {
  struct stat target, candidate;
  int fd, matches = 0;
  require(stat(path, &target) == 0, "preopened log file is missing");
  for (fd = 3; fd < 256; fd++) {
    if (fstat(fd, &candidate) == 0 && candidate.st_dev == target.st_dev &&
        candidate.st_ino == target.st_ino) {
      matches++;
      require((fcntl(fd, F_GETFL) & (O_ACCMODE | O_APPEND)) == (O_WRONLY | O_APPEND),
        "keylog descriptor must be write-only and append-only");
      require((fcntl(fd, F_GETFD) & FD_CLOEXEC) != 0,
        "keylog descriptor must not survive exec into unrelated programs");
    }
  }
  require(matches == 1, "helper must open exactly one log descriptor before forking");
}

static void fork_workers(const char *path) {
  pid_t workers[3];
  unsigned i;
  int status;
  char *directory = strdup(path);
  char *separator;
  int privileged = geteuid() == 0;
  require(directory != NULL, "path allocation failed");
  separator = strrchr(directory, '/');
  require(separator != NULL, "log path must be absolute");
  *separator = '\0';
  if (!privileged) {
    require(chmod(directory, 0) == 0, "could not revoke path access after initialization");
  }
  for (i = 0; i < 3; i++) {
    workers[i] = fork();
    require(workers[i] >= 0, "worker fork failed");
    if (workers[i] == 0) {
      int fd;
      alarm(15);
      if (privileged) {
        require(setgroups(0, NULL) == 0 && setgid(101) == 0 && setuid(101) == 0,
          "worker privilege drop failed");
      }
      errno = 0;
      fd = open(path, O_WRONLY | O_APPEND);
      require(fd == -1 && errno == EACCES, "worker unexpectedly retained pathname write access");
      exercise_contexts();
      _exit(0);
    }
  }
  for (i = 0; i < 3; i++) {
    require(waitpid(workers[i], &status, 0) == workers[i] && WIFEXITED(status) &&
        WEXITSTATUS(status) == 0, "forked TLS worker failed");
  }
  if (!privileged) {
    require(chmod(directory, 0700) == 0, "could not restore fixture directory permissions");
  }
  printf("WORKERS %s\n", privileged ? "uid=101" : "pathname-access-revoked");
  free(directory);
}

int main(int argc, char **argv) {
  void *helper;
  unsigned i;
  require(argc == 5, "usage: harness helper.so 12|13 handshake|fork logfile");
  alarm(20); /* Also bounds constructor opens of unsuitable endpoints such as FIFOs. */
  helper = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (helper == NULL) {
    fprintf(stderr, "TLS keylog runtime: dlopen: %s\n", dlerror());
    return 1;
  }
  helper_ssl_new = (SSL *(*)(SSL_CTX *))dlsym(helper, "SSL_new");
  helper_set_context = (SSL_CTX *(*)(SSL *, SSL_CTX *))dlsym(helper, "SSL_set_SSL_CTX");
  helper_set_callback = (void (*)(SSL_CTX *, keylog_callback))dlsym(helper, "SSL_CTX_set_keylog_callback");
  helper_get_callback = (keylog_callback (*)(const SSL_CTX *))dlsym(helper, "SSL_CTX_get_keylog_callback");
  require(helper_ssl_new != NULL && helper_set_context != NULL && helper_set_callback != NULL &&
      helper_get_callback != NULL, "required helper interposition symbols are missing");
  protocol_version = strcmp(argv[2], "12") == 0 ? TLS1_2_VERSION : TLS1_3_VERSION;
  initialize_contexts(protocol_version);
  if (strcmp(argv[3], "fork") == 0) {
    require_private_append_descriptor(argv[4]);
    fork_workers(argv[4]);
  } else {
    exercise_contexts();
  }
  for (i = 0; i < 3; i++) {
    SSL_CTX_free(server_contexts[i]);
  }
  SSL_CTX_free(client_context);
  /* The helper remains loaded until process exit, as it does under LD_PRELOAD. */
  return 0;
}
