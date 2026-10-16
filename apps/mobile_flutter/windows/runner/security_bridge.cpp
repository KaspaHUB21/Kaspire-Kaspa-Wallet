#include "security_bridge.h"
#include <flutter/standard_method_codec.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <filesystem>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

namespace {
constexpr UINT kPromptMessage = WM_APP + 81, kResultMessage = WM_APP + 82;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
std::wstring wide(const char* input) {
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input, -1, nullptr, 0);
  if (!count) throw std::runtime_error("Invalid UTF-8");
  std::wstring output(static_cast<size_t>(count), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input, -1, output.data(), count);
  output.pop_back(); return output;
}
std::string narrow(const std::wstring& input) {
  if (input.empty()) return {};
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), nullptr, 0, nullptr, nullptr);
  if (!count) throw std::runtime_error("Invalid Windows text");
  std::string output(static_cast<size_t>(count), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), output.data(), count, nullptr, nullptr); return output;
}
void wipe(std::wstring& value) {
  if (!value.empty()) SecureZeroMemory(value.data(), value.size() * sizeof(wchar_t));
  value.clear();
}
char* copy_answer(const std::wstring& value) {
  auto utf8 = narrow(value); auto output = static_cast<char*>(std::malloc(utf8.size() + 1));
  if (output) std::memcpy(output, utf8.c_str(), utf8.size() + 1);
  if (!utf8.empty()) SecureZeroMemory(utf8.data(), utf8.size());
  return output;
}
void __cdecl free_answer(char* value) { if (value) { SecureZeroMemory(value, std::strlen(value)); std::free(value); } }
char* __cdecl prompt(unsigned mode, const char* title, const char* content);
using CoreCall = char* (__cdecl*)(const char*, size_t, const char*, decltype(&prompt), decltype(&free_answer));
using CoreFree = void (__cdecl*)(char*);
using CoreCancel = void (__cdecl*)();
template<typename Function> Function exported(HMODULE module, const char* name) {
  Function function = nullptr;
  if (module) { auto address = GetProcAddress(module, name); static_assert(sizeof(function) == sizeof(address)); std::memcpy(&function, &address, sizeof(function)); }
  return function;
}
const Value* field(const Map& map, const char* key) { auto found = map.find(Value(key)); return found == map.end() ? nullptr : &found->second; }
int64_t integer(const Map& map, const char* key, int64_t fallback = 0) {
  const auto value = field(map, key);
  if (value) { if (auto v = std::get_if<int64_t>(value)) return *v; if (auto v = std::get_if<int32_t>(value)) return *v; }
  return fallback;
}
double number(const Map& map, const char* key) { const auto value = field(map, key); return value && std::get_if<double>(value) ? std::get<double>(*value) : static_cast<double>(integer(map, key)); }
bool bool_field(const Map& map, const char* key) { const auto value = field(map, key); return value && std::get_if<bool>(value) && std::get<bool>(*value); }
COLORREF color(const Map& map, const char* key) { const auto argb = static_cast<uint32_t>(integer(map, key)); return RGB((argb >> 16) & 255, (argb >> 8) & 255, argb & 255); }
std::wstring file_dialog(HWND owner, bool save, const std::wstring& filename) {
  IFileDialog* dialog = nullptr;
  HRESULT hr = save ? CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)) : CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr)) return {};
  const COMDLG_FILTERSPEC filters[] = {{L"Kaspire backup / recovery (*.json)", L"*.json"}};
  dialog->SetFileTypes(1, filters); dialog->SetDefaultExtension(L"json");
  DWORD options = 0; dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR | (save ? FOS_OVERWRITEPROMPT : FOS_FILEMUSTEXIST));
  if (save) dialog->SetFileName(filename.c_str());
  hr = dialog->Show(owner);
  std::wstring path;
  if (SUCCEEDED(hr)) { IShellItem* item = nullptr; if (SUCCEEDED(dialog->GetResult(&item))) { PWSTR text = nullptr; if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &text))) { path = text; CoTaskMemFree(text); } item->Release(); } }
  dialog->Release(); return path;
}
struct Prompt {
  int64_t id = 0; unsigned mode = 0;
  std::wstring title, text, answer;
  bool done = false, accepted = false;
  HWND container = nullptr, edit = nullptr;
  HFONT font = nullptr; HBRUSH brush = nullptr;
  COLORREF background = 0, foreground = 0;
  int font_height = 0;
  RECT bounds{};
  ULONGLONG last_activity = 0;
  ~Prompt() { wipe(text); wipe(answer); }
};
struct Work { std::string payload, response; uint64_t generation = 0; std::unique_ptr<Result> result; };
SecurityBridge::State* broker = nullptr;
LRESULT CALLBACK InputContainer(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto input = reinterpret_cast<Prompt*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) { input = static_cast<Prompt*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams); SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(input)); }
  if (input && (message == WM_CTLCOLOREDIT || message == WM_CTLCOLORSTATIC)) { const auto dc = reinterpret_cast<HDC>(wparam); SetTextColor(dc, input->foreground); SetBkColor(dc, input->background); return reinterpret_cast<LRESULT>(input->brush); }
  if (input && message == WM_ERASEBKGND) { RECT rect{}; GetClientRect(window, &rect); FillRect(reinterpret_cast<HDC>(wparam), &rect, input->brush); return 1; }
  return DefWindowProcW(window, message, wparam, lparam);
}
LRESULT CALLBACK InputKeys(HWND window, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR data);
}

struct SecurityBridge::State {
  HWND owner; HMODULE core = nullptr;
  CoreCall call = nullptr; CoreFree release = nullptr; CoreCancel cancel = nullptr, lock_session = nullptr;
  std::string directory;
  std::unique_ptr<flutter::MethodChannel<Value>> channel;
  std::mutex mutex; std::condition_variable wake;
  std::deque<std::unique_ptr<Work>> queued, completed;
  std::shared_ptr<Prompt> pending;
  std::thread worker; bool stopping = false; int64_t sequence = 0;
  std::atomic<uint64_t> generation{0};
  explicit State(HWND window) : owner(window) {}
  std::shared_ptr<Prompt> Current(int64_t id = 0) { std::lock_guard<std::mutex> guard(mutex); return pending && (!id || pending->id == id) && !pending->done ? pending : nullptr; }
  void RemoveInput(const std::shared_ptr<Prompt>& input) {
    if (input->edit) SetWindowTextW(input->edit, L"");
    if (input->container) DestroyWindow(input->container);
    input->container = input->edit = nullptr;
    if (input->font) DeleteObject(input->font);
    if (input->brush) DeleteObject(input->brush);
    input->font = nullptr; input->brush = nullptr; SetWindowDisplayAffinity(owner, WDA_NONE);
  }
  void Finish(const std::shared_ptr<Prompt>& input, bool accepted, std::wstring* answer = nullptr) {
    { std::lock_guard<std::mutex> guard(mutex); if (input->done) { if (answer) wipe(*answer); return; } }
    RemoveInput(input);
    channel->InvokeMethod("closePrompt", std::make_unique<Value>(Map{{Value("id"), Value(input->id)}}));
    { std::lock_guard<std::mutex> guard(mutex); input->accepted = accepted; if (answer) { input->answer.assign(*answer); wipe(*answer); } input->done = true; }
    SetFocus(GetWindow(owner, GW_CHILD)); wake.notify_all();
  }
  std::string Complete(int64_t id, bool accepted) {
    if (id <= 0) return "Invalid approval identifier.";
    auto input = Current(id); if (!input) return {};
    std::wstring answer;
    if (accepted && (input->mode == 1 || input->mode == 2)) {
      if (!input->edit) return "The secure input is not ready yet. Please try again.";
      const int count = GetWindowTextLengthW(input->edit); answer.resize(static_cast<size_t>(count) + 1);
      GetWindowTextW(input->edit, answer.data(), count + 1); answer.resize(static_cast<size_t>(count));
      if (answer.empty() && input->title != L"BIP39 passphrase (optional)") return "Please complete the field before continuing.";
    } else if (accepted) { answer = L"1"; }
    Finish(input, accepted, &answer); return {};
  }
  void Cancel() {
    auto input = Current(); if (input) Finish(input, false);
    std::deque<std::unique_ptr<Work>> abandoned; { std::lock_guard<std::mutex> guard(mutex); abandoned.swap(queued); }
    for (auto& task : abandoned) task->result->Error("SECURITY_ERROR", "Wallet locked. Review the operation again.");
  }
  bool SetPasswordVisibility(int64_t id, bool visible) {
    if (id <= 0) return false;
    auto input = Current(id);
    if (!input || input->done || input->mode != 1 || !input->edit) return false;
    // Only the mask changes. No text or keystroke crosses the Flutter channel.
    SendMessageW(input->edit, EM_SETPASSWORDCHAR, visible ? 0 : 0x2022, 0);
    RedrawWindow(input->edit, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW);
    SetFocus(input->edit);
    return true;
  }
  void Show(int64_t id) {
    auto input = Current(id); if (!input) return;
    if (input->mode == 4 || input->mode == 5) { auto answer = file_dialog(owner, input->mode == 5, input->text); const bool accepted = !answer.empty(); Finish(input, accepted, &answer); return; }
    // Only generic instructions, NEVER the displayed recovery phrase or key.
    const auto body = input->mode == 6 ? std::string("Keep this information private. Write it down and store it safely.") : narrow(input->text);
    channel->InvokeMethod("showPrompt", std::make_unique<Value>(Map{{Value("id"), Value(input->id)}, {Value("mode"), Value(static_cast<int32_t>(input->mode))}, {Value("title"), Value(narrow(input->title))}, {Value("body"), Value(body)}}));
  }
  void Position(const Map& frame) {
    if (integer(frame, "id") <= 0) return;
    auto input = Current(integer(frame, "id")); if (!input || input->mode == 3) return;
    const double scale = number(frame, "scale"), x = number(frame, "x"), y = number(frame, "y"), width = number(frame, "width"), height = number(frame, "height");
    if (!std::isfinite(scale) || scale < .5 || scale > 8 || !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) || width < 1 || height < 1 || width > 5000 || height > 5000 || std::abs(x) > 5000 || std::abs(y) > 5000) return;
    const auto background = color(frame, "background"), foreground = color(frame, "foreground");
    const bool colors_changed = !input->brush || background != input->background || foreground != input->foreground;
    if (colors_changed) {
      input->background = background; input->foreground = foreground;
      if (input->brush) DeleteObject(input->brush);
      input->brush = CreateSolidBrush(input->background);
    }
    if (!input->container) {
      WNDCLASSW wc{}; wc.lpfnWndProc = InputContainer; wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"KaspireEmbeddedSecureInput"; RegisterClassW(&wc);
      const auto view = GetWindow(owner, GW_CHILD);
      // Flutter must not erase/paint over the secure child input while drawing
      // focus/caret/animation frames. The text stays entirely in the native EDIT.
      SetWindowLongPtrW(view, GWL_STYLE, GetWindowLongPtrW(view, GWL_STYLE) | WS_CLIPCHILDREN);
      input->container = CreateWindowExW(0, wc.lpszClassName, input->title.c_str(), WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS, 0, 0, 1, 1, view, nullptr, wc.hInstance, input.get());
      const bool read_only = input->mode == 6;
      const DWORD style = WS_CHILD | WS_VISIBLE | WS_TABSTOP | (input->mode == 1 ? ES_PASSWORD | ES_AUTOHSCROLL : ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL) | (read_only ? ES_READONLY : 0);
      // Win32 EDIT renders multiline text only with CRLF line endings.
      std::wstring display;
      if (read_only) for (size_t i = 0; i < input->text.size(); ++i) {
        if (input->text[i] == L'\n' && (i == 0 || input->text[i - 1] != L'\r')) display += L'\r';
        display += input->text[i];
      }
      input->edit = CreateWindowExW(0, L"EDIT", read_only ? display.c_str() : L"", style, 0, 0, 1, 1, input->container, nullptr, wc.hInstance, nullptr);
      wipe(display);
      if (!input->container || !input->edit) { Finish(input, false); return; }
      SendMessageW(input->edit, EM_SETLIMITTEXT, 16384, 0); SetWindowSubclass(input->edit, InputKeys, 1, static_cast<DWORD_PTR>(input->id));
      SendMessageW(input->edit, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, MAKELPARAM(4, 4));
      SetWindowDisplayAffinity(owner, 0x11);
    }
    const int font_height = -static_cast<int>(std::lround(16 * scale));
    const bool font_changed = !input->font || font_height != input->font_height;
    if (font_changed) {
      auto font = CreateFontW(font_height, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
      SendMessageW(input->edit, WM_SETFONT, reinterpret_cast<WPARAM>(font), FALSE);
      if (input->font) DeleteObject(input->font);
      input->font = font; input->font_height = font_height;
    }
    const int w = static_cast<int>(std::lround(width * scale)), h = static_cast<int>(std::lround(height * scale));
    const RECT bounds{static_cast<LONG>(std::lround(x * scale)), static_cast<LONG>(std::lround(y * scale)), w, h};
    const bool bounds_changed = !EqualRect(&input->bounds, &bounds);
    if (bounds_changed || !IsWindowVisible(input->container)) {
      SetWindowPos(input->container, HWND_TOP, bounds.left, bounds.top, w, h, SWP_SHOWWINDOW | SWP_NOACTIVATE);
      if (bounds_changed) SetWindowPos(input->edit, nullptr, 0, 0, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
      input->bounds = bounds;
    }
    if (colors_changed || font_changed) RedrawWindow(input->container, nullptr, nullptr, RDW_INVALIDATE | RDW_ALLCHILDREN);
    if (bool_field(frame, "focus")) SetFocus(input->edit);
  }
  void Run() {
    while (true) {
      std::unique_ptr<Work> task;
      { std::unique_lock<std::mutex> guard(mutex); wake.wait(guard, [&] { return stopping || !queued.empty(); }); if (stopping) return; task = std::move(queued.front()); queued.pop_front(); }
      char* response = call(task->payload.data(), task->payload.size(), directory.c_str(), prompt, free_answer);
      if (response) { task->response = response; release(response); }
      { std::lock_guard<std::mutex> guard(mutex); completed.push_back(std::move(task)); if (!stopping) PostMessageW(owner, kResultMessage, 0, 0); }
    }
  }
};

namespace {
char* __cdecl prompt(unsigned mode, const char* title, const char* content) {
  try {
    auto state = broker; if (!state) return nullptr;
    auto input = std::make_shared<Prompt>(); input->mode = mode; input->title = wide(title); input->text = wide(content);
    std::unique_lock<std::mutex> guard(state->mutex); if (state->stopping) return nullptr;
    input->id = ++state->sequence; state->pending = input;
    if (!PostMessageW(state->owner, kPromptMessage, static_cast<WPARAM>(input->id), 0)) return nullptr;
    state->wake.wait(guard, [&] { return state->stopping || input->done; }); const bool accepted = !state->stopping && input->accepted;
    if (state->pending == input) state->pending.reset();
    guard.unlock(); return accepted ? copy_answer(input->answer) : nullptr;
  } catch (...) { return nullptr; }
}
LRESULT CALLBACK InputKeys(HWND window, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR data) {
  if (message == WM_KEYDOWN && broker) {
    auto input = broker->Current(static_cast<int64_t>(data));
    if (input && GetTickCount64() - input->last_activity >= 1000) {
      input->last_activity = GetTickCount64();
      broker->channel->InvokeMethod("promptActivity", std::make_unique<Value>(Map{{Value("id"), Value(input->id)}}));
    }
    if (input && wparam == VK_ESCAPE) { broker->Complete(input->id, false); return 0; }
    if (input && wparam == VK_RETURN && (input->mode == 1 || GetKeyState(VK_CONTROL) < 0)) {
      const auto error = broker->Complete(input->id, true);
      if (!error.empty()) broker->channel->InvokeMethod("promptError", std::make_unique<Value>(Map{{Value("id"), Value(input->id)}, {Value("message"), Value(error)}})); return 0;
    }
    if (input && wparam == VK_TAB) {
      SetFocus(GetWindow(broker->owner, GW_CHILD)); broker->channel->InvokeMethod("focusActions", std::make_unique<Value>(Map{{Value("id"), Value(input->id)}, {Value("backwards"), Value(GetKeyState(VK_SHIFT) < 0)}})); return 0;
    }
  }
  if (message == WM_NCDESTROY) RemoveWindowSubclass(window, InputKeys, id);
  return DefSubclassProc(window, message, wparam, lparam);
}
}

SecurityBridge::SecurityBridge(flutter::BinaryMessenger* messenger, HWND owner) : state_(std::make_unique<State>(owner)) {
  auto& s = *state_; wchar_t executable[32768]; DWORD count = GetModuleFileNameW(nullptr, executable, 32768);
  if (!count || count == 32768) throw std::runtime_error("Cannot locate Kaspire executable");
  auto dll = std::filesystem::path(executable).parent_path() / L"kaspa_secure_core.dll";
  s.core = LoadLibraryExW(dll.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
  s.call = exported<CoreCall>(s.core, "kaspire_desktop_call"); s.release = exported<CoreFree>(s.core, "kaspire_desktop_free"); s.cancel = exported<CoreCancel>(s.core, "kaspire_desktop_cancel"); s.lock_session = exported<CoreCancel>(s.core, "kaspire_desktop_lock");
  PWSTR appdata = nullptr; if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &appdata))) throw std::runtime_error("Cannot locate Windows user data");
  s.directory = narrow(std::filesystem::path(appdata).append(L"Kaspire").wstring()); CoTaskMemFree(appdata);
  s.channel = std::make_unique<flutter::MethodChannel<Value>>(messenger, "space.kaspire/security-windows", &flutter::StandardMethodCodec::GetInstance()); broker = &s;
  s.channel->SetMethodCallHandler([this](const auto& method, std::unique_ptr<Result> result) {
    auto& state = *state_; const auto frame = method.arguments() ? std::get_if<Map>(method.arguments()) : nullptr;
    if (!frame) { result->Error("SECURITY_ERROR", "Invalid native frame."); return; }
    if (method.method_name() == "layoutPrompt") { state.Position(*frame); result->Success(); return; }
    if (method.method_name() == "finishPrompt") { auto error = state.Complete(integer(*frame, "id"), bool_field(*frame, "accepted")); if (error.empty()) result->Success(); else result->Error("INPUT_REQUIRED", error); return; }
    if (method.method_name() == "setPromptVisibility") {
      const auto visible = field(*frame, "visible");
      if (!visible || !std::get_if<bool>(visible) || !state.SetPasswordVisibility(integer(*frame, "id"), std::get<bool>(*visible))) {
        result->Error("INPUT_UNAVAILABLE", "The password field is not available.");
      } else result->Success();
      return;
    }
    if (method.method_name() != "call") { result->NotImplemented(); return; }
    if (!state.call || !state.release || !state.cancel || !state.lock_session) { result->Error("SECURITY_ERROR", "The native Rust signing core could not be loaded."); return; }
    if (bool_field(*frame, "lock")) { state.generation.fetch_add(1); if (bool_field(*frame, "forgetPin")) state.lock_session(); else state.cancel(); state.Cancel(); result->Success(Value("{\"result\":null}")); return; }
    const auto payload = field(*frame, "payload"); const auto text = payload ? std::get_if<std::string>(payload) : nullptr;
    if (!text || text->size() > 4 * 1024 * 1024) { result->Error("SECURITY_ERROR", "Invalid native request."); return; }
    auto task = std::make_unique<Work>(); task->payload = *text; task->generation = state.generation.load(); task->result = std::move(result);
    { std::lock_guard<std::mutex> guard(state.mutex); if (state.queued.size() >= 64) { task->result->Error("SECURITY_BUSY", "Complete the current wallet operation first."); return; } state.queued.push_back(std::move(task)); }
    state.wake.notify_all();
  });
  s.worker = std::thread([state = state_.get()] { state->Run(); });
}
bool SecurityBridge::HandleWindowMessage(UINT message, WPARAM wparam, LPARAM, LRESULT* result) {
  auto& s = *state_;
  if (message == kPromptMessage) { s.Show(static_cast<int64_t>(wparam)); *result = 0; return true; }
  if (message == kResultMessage) {
    std::deque<std::unique_ptr<Work>> done; { std::lock_guard<std::mutex> guard(s.mutex); done.swap(s.completed); }
    for (auto& task : done) {
      if (task->generation != s.generation.load()) task->result->Error("SECURITY_ERROR", "Wallet locked during the operation. No signed transaction was released.");
      else if (task->response.empty()) task->result->Error("SECURITY_ERROR", "The native Rust signing core did not respond.");
      else task->result->Success(Value(task->response));
    }
    *result = 0; return true;
  }
  if (message == WM_SIZE && wparam == SIZE_MINIMIZED) { auto input = s.Current(); if (input && input->container) ShowWindow(input->container, SW_HIDE); }
  return false;
}
SecurityBridge::~SecurityBridge() {
  auto& s = *state_; if (s.lock_session) s.lock_session(); s.Cancel();
  { std::lock_guard<std::mutex> guard(s.mutex); s.stopping = true; }
  s.wake.notify_all(); if (s.worker.joinable()) s.worker.join(); broker = nullptr; s.channel.reset(); if (s.core) FreeLibrary(s.core);
}
