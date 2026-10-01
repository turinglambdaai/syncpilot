// Bridge between backend threads and the GTK main loop. RPC completions and
// event notifications arrive on RVT1 reader threads, so every UI update is
// packaged by value and run through g_idle_add (the scaffold's pattern,
// shared by every window in the host).
#pragma once

#include <glib.h>

#include <exception>
#include <functional>
#include <memory>
#include <string>
#include <utility>

#include "GeneratedBackend.hpp"

namespace sp {

namespace detail {

template <typename T>
int run_on_main(gpointer data) {
  std::unique_ptr<std::pair<std::function<void(T&)>, T>> task(
      static_cast<std::pair<std::function<void(T&)>, T>*>(data));
  task->first(task->second);
  return G_SOURCE_REMOVE;
}

}  // namespace detail

// Run `run(payload)` on the GTK main loop.
template <typename T>
void post_to_main(std::function<void(T&)> run, T payload) {
  auto* task = new std::pair<std::function<void(T&)>, T>(std::move(run),
                                                         std::move(payload));
  g_idle_add(detail::run_on_main<T>, task);
}

// A backend result flattened for the UI thread: no exception_ptr, no
// optional indirection — just ok/value/error.
template <typename T>
struct Unpacked {
  bool ok{false};
  T value{};
  std::string error;
};

template <>
struct Unpacked<void> {
  bool ok{false};
  std::string error;
};

template <typename T>
Unpacked<T> unpack(rivet_app::Result<T> result) {
  Unpacked<T> out;
  try {
    out.value = result.get();
    out.ok = true;
  } catch (std::exception const& e) {
    out.error = e.what();
  } catch (...) {
    out.error = "unknown backend failure";
  }
  return out;
}

inline Unpacked<void> unpack(rivet_app::Result<void> result) {
  Unpacked<void> out;
  try {
    result.get();
    out.ok = true;
  } catch (std::exception const& e) {
    out.error = e.what();
  } catch (...) {
    out.error = "unknown backend failure";
  }
  return out;
}

}  // namespace sp
