#ifndef CLIBSSH2_H
#define CLIBSSH2_H

#include <libssh2.h>
#include <libssh2_sftp.h>

/* 链接自检用的三个取值函数。放在 C 侧是因为 Swift 拿不到
   LIBSSH2_VERSION_NUM 这种编译期宏，也不该去解析 "1.11.1_DEV" 字符串。 */

unsigned long FerrySSH_libssh2_version_num(void);
const char *FerrySSH_libssh2_version_string(void);
/* 返回 libssh2_crypto_engine_t：0=无 1=OpenSSL 2=gcrypt 3=mbedtls 4=wincng 5=OS400 */
int FerrySSH_libssh2_crypto_engine(void);

#endif /* CLIBSSH2_H */
