#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <sddl.h>

#include "flutter_window.h"
#include "utils.h"

namespace {
// One writer per Windows user, including separate logon sessions. Two wallet
// processes must never overwrite one another's encrypted wallet catalogue.
HANDLE SingleWalletInstance(bool& already_running) {
  HANDLE token=nullptr;
  if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))return nullptr;
  DWORD size=0;GetTokenInformation(token,TokenUser,nullptr,0,&size);
  std::vector<BYTE> data(size);
  if(!GetTokenInformation(token,TokenUser,data.data(),size,&size)){CloseHandle(token);return nullptr;}
  CloseHandle(token);LPWSTR sid=nullptr;
  if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid,&sid))return nullptr;
  std::wstring name=L"Global\\KaspireDesktop-";name+=sid;LocalFree(sid);
  HANDLE mutex=CreateMutexW(nullptr,TRUE,name.c_str());
  already_running=mutex&&GetLastError()==ERROR_ALREADY_EXISTS;
  return mutex;
}
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  bool already_running=false;
  HANDLE single_instance=SingleWalletInstance(already_running);
  if(!single_instance){MessageBoxW(nullptr,L"Could not establish an exclusive Windows wallet session. No wallet was opened.",L"Kaspire",MB_OK|MB_ICONERROR);return EXIT_FAILURE;}
  if(already_running){CloseHandle(single_instance);MessageBoxW(nullptr,L"Kaspire is already running for this Windows user. Use the existing window.",L"Kaspire",MB_OK);return EXIT_SUCCESS;}
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 860);
  if (!window.Create(L"Kaspire", origin, size)) {
    CloseHandle(single_instance);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
