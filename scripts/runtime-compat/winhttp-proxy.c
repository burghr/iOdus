/* iOdus winhttp proxy.
 *
 * GDK games send Xbox Live requests through libHttpClient and XCurl, which use
 * WinHTTP. In the WINHTTP_CALLBACK_STATUS_SENDING_REQUEST callback, they ask
 * for WinHttpQueryOption(WINHTTP_OPTION_URL). The winhttp.dll of GPTK Wine 7.7
 * does not have that option, so the client closes the request. Example: the
 * profile request of Shelldiver fails three times, and
 * XblProfileGetUserProfileAsync returns E_FAIL.
 *
 * The winhttp.dll of the Xodus Wine 11 build has the option, but it crashes in
 * Wine 7.7. So this DLL loads the real GPTK winhttp.dll from the Wine DLL
 * folder and sends all calls to it. It keeps the URL of each request handle,
 * and it gives that URL when the real DLL cannot answer WINHTTP_OPTION_URL.
 *
 * The proxy also writes a line to %LOCALAPPDATA%\iOdus\achievement-signal when
 * a game opens an achievement update request (POST to achievements.xboxlive.com,
 * path ".../update"). iOdus then reads the achievement list from Xbox Live and
 * shows a popup for each new unlock. The request itself does not change.
 *
 * WinHttpSetOption(WINHTTP_OPTION_DECOMPRESSION) on a request handle fails in
 * Wine before 11.4 ("unimplemented option 118"). The Xbox build of Disney
 * Speedstorm sets it on its first Gameloft request, closes the request when the
 * set fails, and stops with "failed to connect to the server (2)". The proxy
 * accepts the option, like upstream Wine 22aedfab35. WinHTTP then sends no
 * Accept-Encoding header, so the server answers without compression.
 *
 * Install: system32\winhttp.dll with the DLL override winhttp=native,builtin. */
#include <windows.h>
#define _WINHTTP_INTERNAL_   /* This DLL defines the WinHTTP functions; do not import them. */
#include <winhttp.h>

static HMODULE real;
static SRWLOCK lock = SRWLOCK_INIT;

/* The forwarded exports: a jump through a pointer that DllMain sets. */
#define FORWARDS \
    F(DllCanUnloadNow) F(DllGetClassObject) F(DllRegisterServer) F(DllUnregisterServer) \
    F(WinHttpAddRequestHeaders) F(WinHttpCheckPlatform) F(WinHttpCrackUrl) F(WinHttpCreateProxyResolver) \
    F(WinHttpDetectAutoProxyConfigUrl) F(WinHttpFreeProxyResult) F(WinHttpFreeProxyResultEx) \
    F(WinHttpFreeProxySettings) F(WinHttpGetDefaultProxyConfiguration) F(WinHttpGetIEProxyConfigForCurrentUser) \
    F(WinHttpGetProxyForUrl) F(WinHttpGetProxyForUrlEx) F(WinHttpGetProxyForUrlEx2) F(WinHttpGetProxyResult) \
    F(WinHttpGetProxyResultEx) F(WinHttpGetProxySettingsVersion) F(WinHttpOpen) F(WinHttpQueryAuthSchemes) \
    F(WinHttpQueryDataAvailable) F(WinHttpQueryHeaders) F(WinHttpReadData) F(WinHttpReadProxySettings) \
    F(WinHttpReceiveResponse) F(WinHttpResetAutoProxy) F(WinHttpSendRequest) F(WinHttpSetCredentials) \
    F(WinHttpSetDefaultProxyConfiguration) F(WinHttpSetStatusCallback) \
    F(WinHttpSetTimeouts) F(WinHttpTimeFromSystemTime) F(WinHttpTimeToSystemTime) F(WinHttpWebSocketClose) \
    F(WinHttpWebSocketCompleteUpgrade) F(WinHttpWebSocketQueryCloseStatus) F(WinHttpWebSocketReceive) \
    F(WinHttpWebSocketSend) F(WinHttpWebSocketShutdown) F(WinHttpWriteData) F(WinHttpWriteProxySettings)

#define F(name) void *real_##name; \
    __asm__( ".text\n.globl " #name "\n" #name ":\n\tjmp *real_" #name "(%rip)\n" );
FORWARDS
#undef F

#ifndef WINHTTP_OPTION_DECOMPRESSION
#define WINHTTP_OPTION_DECOMPRESSION 118
#endif
#ifndef WINHTTP_DECOMPRESSION_FLAG_ALL
#define WINHTTP_DECOMPRESSION_FLAG_ALL 0x3
#endif

/* The five calls that this DLL changes. */
static HINTERNET (WINAPI *real_connect)( HINTERNET, const WCHAR *, INTERNET_PORT, DWORD );
static HINTERNET (WINAPI *real_open_request)( HINTERNET, const WCHAR *, const WCHAR *, const WCHAR *,
                                              const WCHAR *, const WCHAR **, DWORD );
static BOOL (WINAPI *real_close)( HINTERNET );
static BOOL (WINAPI *real_query_option)( HINTERNET, DWORD, void *, DWORD * );
static BOOL (WINAPI *real_set_option)( HINTERNET, DWORD, void *, DWORD );
static BOOL (WINAPI *real_create_url)( URL_COMPONENTS *, DWORD, WCHAR *, DWORD * );

/* A connect handle (host and port) or a request handle (the full URL). */
struct entry
{
    struct entry *next;
    HINTERNET handle;
    WCHAR *host;
    INTERNET_PORT port;
    WCHAR *url;
};
static struct entry *entries;

static WCHAR *copy_string( const WCHAR *str )
{
    WCHAR *ret;
    if (!str) return NULL;
    if ((ret = HeapAlloc( GetProcessHeap(), 0, (lstrlenW( str ) + 1) * sizeof(WCHAR) ))) lstrcpyW( ret, str );
    return ret;
}

static void add_entry( HINTERNET handle, WCHAR *host, INTERNET_PORT port, WCHAR *url )
{
    struct entry *entry = HeapAlloc( GetProcessHeap(), 0, sizeof(*entry) );
    if (!entry)
    {
        HeapFree( GetProcessHeap(), 0, host );
        HeapFree( GetProcessHeap(), 0, url );
        return;
    }
    entry->handle = handle;
    entry->host = host;
    entry->port = port;
    entry->url = url;
    AcquireSRWLockExclusive( &lock );
    entry->next = entries;
    entries = entry;
    ReleaseSRWLockExclusive( &lock );
}

/* Call with the lock held. */
static struct entry *find_entry( HINTERNET handle )
{
    struct entry *entry;
    for (entry = entries; entry; entry = entry->next) if (entry->handle == handle) return entry;
    return NULL;
}

static void remove_entry( HINTERNET handle )
{
    struct entry **link, *entry = NULL;
    AcquireSRWLockExclusive( &lock );
    for (link = &entries; *link; link = &(*link)->next)
    {
        if ((*link)->handle == handle)
        {
            entry = *link;
            *link = entry->next;
            break;
        }
    }
    ReleaseSRWLockExclusive( &lock );
    if (!entry) return;
    HeapFree( GetProcessHeap(), 0, entry->host );
    HeapFree( GetProcessHeap(), 0, entry->url );
    HeapFree( GetProcessHeap(), 0, entry );
}

/* The URL in the form of the Wine 11 build_url: scheme, host, port, and path. */
static WCHAR *make_url( const WCHAR *host, INTERNET_PORT port, const WCHAR *object, DWORD flags )
{
    URL_COMPONENTS uc;
    WCHAR *path, *url;
    DWORD len = 0;
    BOOL secure = (flags & WINHTTP_FLAG_SECURE) != 0;

    /* Wine and Windows add a "/" in front of a path that does not have one. */
    if (!object || !object[0]) path = copy_string( L"/" );
    else if (object[0] != '/')
    {
        if ((path = HeapAlloc( GetProcessHeap(), 0, (lstrlenW( object ) + 2) * sizeof(WCHAR) )))
        {
            path[0] = '/';
            lstrcpyW( path + 1, object );
        }
    }
    else path = copy_string( object );
    if (!path) return NULL;

    memset( &uc, 0, sizeof(uc) );
    uc.dwStructSize = sizeof(uc);
    uc.nScheme = secure ? INTERNET_SCHEME_HTTPS : INTERNET_SCHEME_HTTP;
    uc.lpszHostName = (WCHAR *)host;
    uc.dwHostNameLength = lstrlenW( host );
    uc.nPort = port ? port : (secure ? INTERNET_DEFAULT_HTTPS_PORT : INTERNET_DEFAULT_HTTP_PORT);
    uc.lpszUrlPath = path;
    uc.dwUrlPathLength = lstrlenW( path );

    url = NULL;
    real_create_url( &uc, 0, NULL, &len );
    if (GetLastError() == ERROR_INSUFFICIENT_BUFFER && (url = HeapAlloc( GetProcessHeap(), 0, len * sizeof(WCHAR) )))
    {
        if (!real_create_url( &uc, 0, url, &len ))
        {
            HeapFree( GetProcessHeap(), 0, url );
            url = NULL;
        }
    }
    HeapFree( GetProcessHeap(), 0, path );
    return url;
}

/* Adds "<tick count>\t<url>" to %LOCALAPPDATA%\iOdus\achievement-signal. */
static void signal_achievement_update( const WCHAR *verb, const WCHAR *host, const WCHAR *url )
{
    WCHAR path[MAX_PATH];
    char line[1200];
    HANDLE file;
    DWORD len, written;
    int converted;

    if (!verb || lstrcmpiW( verb, L"POST" ) || !host || lstrcmpiW( host, L"achievements.xboxlive.com" )) return;
    if (!url || !wcsstr( url, L"/update" )) return;
    len = GetEnvironmentVariableW( L"LOCALAPPDATA", path, MAX_PATH );
    if (!len || len >= MAX_PATH - 40) return;
    lstrcatW( path, L"\\iOdus" );
    CreateDirectoryW( path, NULL );
    lstrcatW( path, L"\\achievement-signal" );
    len = wsprintfA( line, "%I64u\t", GetTickCount64() );
    converted = WideCharToMultiByte( CP_UTF8, 0, url, -1, line + len, sizeof(line) - len - 2, NULL, NULL );
    if (converted <= 1) return;   /* The URL is too long, or the conversion failed. */
    len += converted;
    line[len - 1] = '\n';   /* Replaces the terminating null. */
    file = CreateFileW( path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS,
                        FILE_ATTRIBUTE_NORMAL, NULL );
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile( file, line, len, &written, NULL );
    CloseHandle( file );
}

HINTERNET WINAPI WinHttpConnect( HINTERNET session, const WCHAR *server, INTERNET_PORT port, DWORD reserved )
{
    HINTERNET handle = real_connect( session, server, port, reserved );
    DWORD error = GetLastError();
    if (handle && server) add_entry( handle, copy_string( server ), port, NULL );
    SetLastError( error );
    return handle;
}

HINTERNET WINAPI WinHttpOpenRequest( HINTERNET connect, const WCHAR *verb, const WCHAR *object, const WCHAR *version,
                                     const WCHAR *referrer, const WCHAR **types, DWORD flags )
{
    HINTERNET handle = real_open_request( connect, verb, object, version, referrer, types, flags );
    DWORD error = GetLastError();
    if (handle)
    {
        WCHAR *host = NULL, *url;
        INTERNET_PORT port = 0;
        struct entry *entry;

        AcquireSRWLockShared( &lock );
        if ((entry = find_entry( connect )))
        {
            host = copy_string( entry->host );
            port = entry->port;
        }
        ReleaseSRWLockShared( &lock );
        if (host)
        {
            url = make_url( host, port, object, flags );
            signal_achievement_update( verb, host, url );
            HeapFree( GetProcessHeap(), 0, host );
            if (url) add_entry( handle, NULL, 0, url );
        }
    }
    SetLastError( error );
    return handle;
}

BOOL WINAPI WinHttpCloseHandle( HINTERNET handle )
{
    remove_entry( handle );
    return real_close( handle );
}

/* WINHTTP_OPTION_URL in the form of the Wine 11 return_string_option. */
static BOOL return_url( const WCHAR *url, void *buffer, DWORD *buflen )
{
    DWORD len = (lstrlenW( url ) + 1) * sizeof(WCHAR);
    if (buffer && *buflen >= len)
    {
        memcpy( buffer, url, len );
        *buflen = len - sizeof(WCHAR);
        SetLastError( ERROR_SUCCESS );
        return TRUE;
    }
    *buflen = len;
    SetLastError( ERROR_INSUFFICIENT_BUFFER );
    return FALSE;
}

BOOL WINAPI WinHttpQueryOption( HINTERNET handle, DWORD option, void *buffer, DWORD *buflen )
{
    BOOL ret = real_query_option( handle, option, buffer, buflen );
    DWORD error = GetLastError();

    if (!ret && option == WINHTTP_OPTION_URL && buflen && error == ERROR_INVALID_PARAMETER)
    {
        struct entry *entry;
        WCHAR *url = NULL;

        AcquireSRWLockShared( &lock );
        if ((entry = find_entry( handle )) && entry->url) url = copy_string( entry->url );
        ReleaseSRWLockShared( &lock );
        if (url)
        {
            ret = return_url( url, buffer, buflen );
            HeapFree( GetProcessHeap(), 0, url );
            return ret;
        }
    }
    SetLastError( error );
    return ret;
}

BOOL WINAPI WinHttpSetOption( HINTERNET handle, DWORD option, void *buffer, DWORD buflen )
{
    BOOL ret = real_set_option( handle, option, buffer, buflen );
    DWORD error = GetLastError();

    /* Accept only what Windows accepts: a DWORD with known flags. */
    if (!ret && option == WINHTTP_OPTION_DECOMPRESSION && error == ERROR_WINHTTP_INVALID_OPTION
        && buffer && buflen == sizeof(DWORD) && !(*(DWORD *)buffer & ~WINHTTP_DECOMPRESSION_FLAG_ALL))
    {
        SetLastError( ERROR_SUCCESS );
        return TRUE;
    }
    SetLastError( error );
    return ret;
}

/* The real winhttp.dll: $IODUS_REAL_WINHTTP, or <WINEDLLDIR0>\x86_64-windows\winhttp.dll. */
static BOOL load_real( void )
{
    WCHAR path[MAX_PATH], dir[MAX_PATH];

    if (!GetEnvironmentVariableW( L"IODUS_REAL_WINHTTP", path, MAX_PATH ))
    {
        DWORD len = GetEnvironmentVariableW( L"WINEDLLDIR0", dir, MAX_PATH );
        const WCHAR *start = dir;
        if (!len || len >= MAX_PATH - 32) return FALSE;
        if (!wcsncmp( start, L"\\??\\", 4 )) start += 4;
        lstrcpyW( path, start );
        lstrcatW( path, L"\\x86_64-windows\\winhttp.dll" );
    }
    if (!(real = LoadLibraryW( path ))) return FALSE;

#define F(name) if (!(real_##name = (void *)GetProcAddress( real, #name ))) return FALSE;
    FORWARDS
#undef F
    real_connect = (void *)GetProcAddress( real, "WinHttpConnect" );
    real_open_request = (void *)GetProcAddress( real, "WinHttpOpenRequest" );
    real_close = (void *)GetProcAddress( real, "WinHttpCloseHandle" );
    real_query_option = (void *)GetProcAddress( real, "WinHttpQueryOption" );
    real_set_option = (void *)GetProcAddress( real, "WinHttpSetOption" );
    real_create_url = (void *)GetProcAddress( real, "WinHttpCreateUrl" );
    return real_connect && real_open_request && real_close && real_query_option && real_set_option && real_create_url;
}

/* WinHttpCreateUrl is a plain forward too, but make_url needs its pointer. */
BOOL WINAPI WinHttpCreateUrl( URL_COMPONENTS *uc, DWORD flags, WCHAR *url, DWORD *len )
{
    return real_create_url( uc, flags, url, len );
}

BOOL WINAPI DllMain( HINSTANCE instance, DWORD reason, void *reserved )
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls( instance );
        /* Without the real DLL, no call can work. Fail the load, so that the
         * error is clear ("winhttp.dll not found") and not a crash later. */
        if (!load_real()) return FALSE;
    }
    return TRUE;
}
