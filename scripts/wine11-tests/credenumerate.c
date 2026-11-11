/* Local regression probe for the macOS empty-Keychain CredEnumerateW bug.
 * Build: x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -o credenumerate.exe credenumerate.c -ladvapi32
 * Run with the Wine runtime being tested and a disposable WINEPREFIX.
 * Only a uniquely named dummy credential is written/read/deleted. No network.
 */
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wincred.h>
#include <stdio.h>
#include <wchar.h>

int main(void)
{
    WCHAR target[128];
    BYTE blob[] = "local-regression-not-a-secret";
    CREDENTIALW credential = {0};
    PCREDENTIALW readback = NULL;
    PCREDENTIALW *entries = NULL;
    PCREDENTIALW *missing = NULL;
    DWORD count = 0, missing_count = 0;
    DWORD read_error, enum_error, missing_error;
    BOOL read_ok, enum_ok, deleted, missing_ok;

    if (swprintf(target, 128, L"iOdus-CredEnumerate-Probe-%lu-%lu",
                 GetCurrentProcessId(), GetTickCount()) < 0)
        return 2;

    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = target;
    credential.UserName = L"local-regression";
    credential.CredentialBlob = blob;
    credential.CredentialBlobSize = sizeof(blob);
    credential.Persist = CRED_PERSIST_SESSION;
    if (!CredWriteW(&credential, 0))
    {
        printf("WRITE_FAILED error=%lu\n", GetLastError());
        return 2;
    }

    read_ok = CredReadW(target, CRED_TYPE_GENERIC, 0, &readback);
    read_error = read_ok ? 0 : GetLastError();
    if (readback) CredFree(readback);

    enum_ok = CredEnumerateW(target, 0, &count, &entries);
    enum_error = enum_ok ? 0 : GetLastError();
    if (entries) CredFree(entries);

    deleted = CredDeleteW(target, CRED_TYPE_GENERIC, 0);
    missing_ok = CredEnumerateW(target, 0, &missing_count, &missing);
    missing_error = missing_ok ? 0 : GetLastError();
    if (missing) CredFree(missing);

    printf("READ success=%d error=%lu; ENUM success=%d count=%lu error=%lu; CLEANUP success=%d\n",
           read_ok, read_error, enum_ok, count, enum_error, deleted);
    printf("MISSING success=%d count=%lu error=%lu\n",
           missing_ok, missing_count, missing_error);

    return read_ok && enum_ok && count == 1 && deleted &&
           !missing_ok && missing_count == 0 && missing_error == ERROR_NOT_FOUND ? 0 : 1;
}
