//
// JK_Botti - be more human!
//
// h_export.cpp
//

#include <string.h>

#include <extdll.h>
#include <dllapi.h>
#include <h_export.h>
#include <meta_api.h>

#include "bot.h"
#include "bootstrap_log.h"
#include "safe_snprintf.h"

static void BootstrapResolveLogPath(void *module_handle);

#ifdef _WIN32
static char g_bootstrap_log_path[512];
static char g_bootstrap_module_path[512];
#endif


enginefuncs_t g_engfuncs;
globalvars_t  *gpGlobals;


void BootstrapLogStage(const char *stage, const char *detail)
{
#ifdef _WIN32
   HANDLE file;
   SYSTEMTIME now;
   DWORD written;
   DWORD size_low;
   char line[1024];

   if (stage == NULL)
      return;

   if (g_bootstrap_log_path[0] == 0)
      BootstrapResolveLogPath(NULL);

   if (g_bootstrap_log_path[0] == 0)
      return;

   file = CreateFileA(g_bootstrap_log_path, GENERIC_WRITE, FILE_SHARE_READ,
      NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
   if (file == INVALID_HANDLE_VALUE)
      return;

   size_low = GetFileSize(file, NULL);
   if (size_low != INVALID_FILE_SIZE && size_low > 262144)
   {
      CloseHandle(file);
      file = CreateFileA(g_bootstrap_log_path, GENERIC_WRITE, FILE_SHARE_READ,
         NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
      if (file == INVALID_HANDLE_VALUE)
         return;
   }
   else
      SetFilePointer(file, 0, NULL, FILE_END);

   GetLocalTime(&now);
   safevoid_snprintf(line, sizeof(line),
      "%04d-%02d-%02d %02d:%02d:%02d.%03d [%lu] %s%s%s\r\n",
      now.wYear,
      now.wMonth,
      now.wDay,
      now.wHour,
      now.wMinute,
      now.wSecond,
      now.wMilliseconds,
      (unsigned long)GetCurrentProcessId(),
      stage,
      (detail && detail[0]) ? " " : "",
      (detail && detail[0]) ? detail : "");

   WriteFile(file, line, (DWORD)strlen(line), &written, NULL);
   CloseHandle(file);
#else
   (void)stage;
   (void)detail;
#endif
}

static void BootstrapResolveLogPath(void *module_handle)
{
#ifdef _WIN32
   HMODULE module = (HMODULE)module_handle;
   DWORD path_length;
   char module_dir[512];
   char addon_dir[512];
   char runtime_dir[512];
   char *last_sep;

   if (g_bootstrap_log_path[0] != 0)
      return;

   if (module == NULL)
      module = GetModuleHandleA("jk_botti_mm.dll");

   if (module == NULL)
      return;

   path_length = GetModuleFileNameA(module, g_bootstrap_module_path,
      sizeof(g_bootstrap_module_path));
   if (path_length == 0 || path_length >= sizeof(g_bootstrap_module_path))
   {
      g_bootstrap_module_path[0] = 0;
      return;
   }

   safe_strcopy(module_dir, sizeof(module_dir), g_bootstrap_module_path);
   last_sep = strrchr(module_dir, '\\');
   if (last_sep == NULL)
      last_sep = strrchr(module_dir, '/');
   if (last_sep != NULL)
      *last_sep = 0;

   safe_strcopy(addon_dir, sizeof(addon_dir), module_dir);
   last_sep = strrchr(addon_dir, '\\');
   if (last_sep == NULL)
      last_sep = strrchr(addon_dir, '/');
   if (last_sep != NULL)
      *last_sep = 0;

   safevoid_snprintf(runtime_dir, sizeof(runtime_dir), "%s\\runtime", addon_dir);
   CreateDirectoryA(runtime_dir, NULL);
   safevoid_snprintf(g_bootstrap_log_path, sizeof(g_bootstrap_log_path),
      "%s\\bootstrap.log", runtime_dir);
#else
   (void)module_handle;
#endif
}


#ifndef __linux__

// Required DLL entry point
extern "C" BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved)
{
   char detail[768];

   (void)lpvReserved;

   if (fdwReason == DLL_PROCESS_ATTACH)
   {
      BootstrapResolveLogPath(hinstDLL);
      safevoid_snprintf(detail, sizeof(detail), "result=process_attach module=%s",
         g_bootstrap_module_path[0] ? g_bootstrap_module_path : "unknown");
      BootstrapLogStage("DllMain", detail);
   }
   else if (fdwReason == DLL_PROCESS_DETACH)
      BootstrapLogStage("DllMain", "result=process_detach");

   return TRUE;
}

#endif

void WINAPI GiveFnptrsToDll( enginefuncs_t* pengfuncsFromEngine, globalvars_t *pGlobals )
{
   BootstrapLogStage("GiveFnptrsToDll", "result=entered");

   // get the engine functions from the engine...
   memcpy(&g_engfuncs, pengfuncsFromEngine, sizeof(enginefuncs_t));
   gpGlobals = pGlobals;

   BootstrapLogStage("GiveFnptrsToDll", "result=success");
}

#ifdef __GNUC__
/* workaround gcc4.x 'local static variable' guarding (hlds is single thread so this is ok) */
namespace __cxxabiv1
{
   /* guard variables */

   /* The ABI requires a 64-bit type.  */
   __extension__ typedef int __guard __attribute__((mode (__DI__)));

   extern "C" int __cxa_guard_acquire (__guard *);
   extern "C" void __cxa_guard_release (__guard *);
   extern "C" void __cxa_guard_abort (__guard *);

   extern "C" int __cxa_guard_acquire (__guard *g)
   {
      return !*(char *)(g);
   }

   extern "C" void __cxa_guard_release (__guard *g)
   {
      *(char *)g = 1;
   }

   extern "C" void __cxa_guard_abort (__guard *)
   {
   }
}
#endif
