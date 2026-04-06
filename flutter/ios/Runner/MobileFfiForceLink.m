#import <Foundation/Foundation.h>

#define M3U8_FFI_EXPORT __attribute__((visibility("default"))) __attribute__((used))

extern char *m3u8_local_server_start(uint16_t port, const char *downloads_dir, const char *auth_password);
extern char *m3u8_local_server_status(void);
extern char *m3u8_local_server_stop(void);
extern void m3u8_string_free(char *ptr);

M3U8_FFI_EXPORT char *m3u8_flutter_local_server_start(uint16_t port, const char *downloads_dir, const char *auth_password) {
  return m3u8_local_server_start(port, downloads_dir, auth_password);
}

M3U8_FFI_EXPORT char *m3u8_flutter_local_server_status(void) {
  return m3u8_local_server_status();
}

M3U8_FFI_EXPORT char *m3u8_flutter_local_server_stop(void) {
  return m3u8_local_server_stop();
}

M3U8_FFI_EXPORT void m3u8_flutter_string_free(char *ptr) {
  m3u8_string_free(ptr);
}

void MobileFfiForceLink(void) {
  (void)&m3u8_flutter_local_server_start;
  (void)&m3u8_flutter_local_server_status;
  (void)&m3u8_flutter_local_server_stop;
  (void)&m3u8_flutter_string_free;
}
