#include "ui_dispatcher.h"

#include <utility>

// The module this code lives in (the plugin DLL).
extern "C" IMAGE_DOS_HEADER __ImageBase;

namespace open_blue_plus {

namespace {

constexpr wchar_t kWindowClass[] = L"OpenBluePlusDispatcher";
constexpr UINT kRunTasks = WM_APP + 0x42;

HINSTANCE ModuleInstance() {
  return reinterpret_cast<HINSTANCE>(&__ImageBase);
}

}  // namespace

std::shared_ptr<UiDispatcher> UiDispatcher::Create() {
  return std::shared_ptr<UiDispatcher>(new UiDispatcher());
}

UiDispatcher::UiDispatcher() : thread_id_(GetCurrentThreadId()) {
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = &UiDispatcher::WindowProc;
  window_class.hInstance = ModuleInstance();
  window_class.lpszClassName = kWindowClass;
  // Fails harmlessly with ERROR_CLASS_ALREADY_EXISTS for a second engine.
  RegisterClassExW(&window_class);

  window_ = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                            nullptr, ModuleInstance(), nullptr);
  if (window_ != nullptr) {
    SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  }
}

UiDispatcher::~UiDispatcher() {
  // Normally already destroyed by Close(); windows can only be destroyed by
  // their own thread.
  if (window_ != nullptr && IsUiThread()) {
    DestroyWindow(window_);
  }
}

bool UiDispatcher::Post(std::function<void()> task) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (closed_ || window_ == nullptr) {
    return false;
  }
  tasks_.push_back(std::move(task));
  // One wake-up message per batch keeps the thread's message queue (limited
  // to 10000 posted messages) small during busy scans.
  if (!signaled_) {
    signaled_ = PostMessageW(window_, kRunTasks, 0, 0) != FALSE;
  }
  return true;
}

void UiDispatcher::Close() {
  std::deque<std::function<void()>> dropped;
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
    dropped.swap(tasks_);
    window = window_;
    window_ = nullptr;
  }
  if (window != nullptr) {
    SetWindowLongPtrW(window, GWLP_USERDATA, 0);
    DestroyWindow(window);
  }
  // `dropped` is destroyed here, outside the lock.
}

bool UiDispatcher::IsClosed() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return closed_;
}

void UiDispatcher::Drain() {
  std::deque<std::function<void()>> batch;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    signaled_ = false;
    batch.swap(tasks_);
  }
  for (auto& task : batch) {
    if (IsClosed()) {
      return;
    }
    try {
      task();
    } catch (...) {
      // Tasks handle their own errors; never let one unwind into the
      // message loop.
    }
  }
}

// static
LRESULT CALLBACK UiDispatcher::WindowProc(HWND window, UINT message,
                                          WPARAM wparam, LPARAM lparam) {
  if (message == kRunTasks) {
    auto* self =
        reinterpret_cast<UiDispatcher*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self != nullptr) {
      self->Drain();
    }
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace open_blue_plus
