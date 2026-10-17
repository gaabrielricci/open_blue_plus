#ifndef FLUTTER_PLUGIN_OPEN_BLUE_PLUS_UI_DISPATCHER_H_
#define FLUTTER_PLUGIN_OPEN_BLUE_PLUS_UI_DISPATCHER_H_

#include <windows.h>

#include <coroutine>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>

namespace open_blue_plus {

// Runs tasks on the thread that created it (the Flutter platform thread)
// through a message-only window. Post() may be called from any thread.
//
// WinRT callbacks arrive on thread-pool threads, while channels and plugin
// state may only be touched on the platform thread.
class UiDispatcher {
 public:
  // Must be called on the platform thread.
  static std::shared_ptr<UiDispatcher> Create();
  ~UiDispatcher();

  UiDispatcher(const UiDispatcher&) = delete;
  UiDispatcher& operator=(const UiDispatcher&) = delete;

  // Queues [task]. Returns false (and drops it) once closed.
  bool Post(std::function<void()> task);

  // Drops pending tasks and stops accepting new ones. Platform thread only.
  void Close();

  bool IsClosed() const;
  bool IsUiThread() const { return GetCurrentThreadId() == thread_id_; }

 private:
  UiDispatcher();
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  void Drain();

  HWND window_ = nullptr;
  const DWORD thread_id_;
  mutable std::mutex mutex_;
  std::deque<std::function<void()>> tasks_;
  bool signaled_ = false;  // a wake-up message is already in the queue
  bool closed_ = false;
};

// `if (!co_await ResumeOnUi{dispatcher}) co_return;`
// Continues the coroutine on the platform thread. Yields false when the
// dispatcher is closed (plugin destroyed): the coroutine must then return
// without touching plugin state. If the dispatcher closes while the
// continuation is queued, the coroutine is never resumed (only at shutdown).
struct ResumeOnUi {
  std::shared_ptr<UiDispatcher> dispatcher;

  bool await_ready() const noexcept { return dispatcher->IsUiThread(); }
  bool await_suspend(std::coroutine_handle<> handle) const {
    return dispatcher->Post([handle]() { handle.resume(); });
  }
  bool await_resume() const noexcept { return !dispatcher->IsClosed(); }
};

}  // namespace open_blue_plus

#endif  // FLUTTER_PLUGIN_OPEN_BLUE_PLUS_UI_DISPATCHER_H_
