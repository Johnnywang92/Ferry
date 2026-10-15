#include "CLibssh2.h"

unsigned long FerrySSH_libssh2_version_num(void) {
    return (unsigned long)LIBSSH2_VERSION_NUM;
}

const char *FerrySSH_libssh2_version_string(void) {
    return libssh2_version(0);
}

int FerrySSH_libssh2_crypto_engine(void) {
    return (int)libssh2_crypto_engine();
}
