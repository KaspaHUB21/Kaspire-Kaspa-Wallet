#pragma once
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>

class SecurityBridge {
 public:
  SecurityBridge(flutter::BinaryMessenger* messenger, HWND owner);
  ~SecurityBridge();
  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam,
                           LRESULT* result);
  struct State;
 private:
  std::unique_ptr<State> state_;
};
