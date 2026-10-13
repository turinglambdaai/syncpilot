cmake_minimum_required(VERSION 3.24)
project(syncpilot-linux-host LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Release artifacts must not embed developer-machine library search paths;
# every linked library (GTK4, GIO, libsecret, curses, LZ4, zlib) is a system
# dependency resolved by the normal loader search on the target machine.
set(CMAKE_SKIP_RPATH TRUE)

# RIVET_ROOT points at the installed Rivet package. `raco rivet build` sets
# it; manual builds may export it themselves.
if(NOT DEFINED ENV{RIVET_ROOT})
  message(FATAL_ERROR "RIVET_ROOT is not set. Export RIVET_ROOT to a Rivet checkout.")
endif()
set(RIVET_ROOT "$ENV{RIVET_ROOT}")

# RIVET_RACKET_LIBRARY is the exact embeddable Racket CS library. The lib-dir
# fallback supports installations that expose an unversioned linker name.
if(NOT DEFINED ENV{RIVET_RACKET_INCLUDE})
  message(FATAL_ERROR "RIVET_RACKET_INCLUDE is not set. Point it at the Racket include directory.")
endif()

find_package(PkgConfig REQUIRED)
find_package(Curses REQUIRED)
find_package(Threads REQUIRED)
find_package(ZLIB REQUIRED)
find_library(LZ4_LIBRARY NAMES lz4 REQUIRED)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4)
pkg_check_modules(GLIB REQUIRED IMPORTED_TARGET gio-2.0)
# The desktop JS bridge parses the calls the embedded official UI posts to
# the syncpilot-bridge:// scheme handler (see src/js_bridge.cpp).
pkg_check_modules(JSON_GLIB REQUIRED IMPORTED_TARGET json-glib-1.0)
# The Secret Service adapter is compiled whenever libsecret is present; the
# capability then reports itself at runtime based on service availability.
pkg_check_modules(LIBSECRET IMPORTED_TARGET libsecret-1)
# WebKitGTK 6.0 is the official-UI embed (WebKitWebView on GTK4). OPTIONAL:
# without it the host still builds and the boot page offers the daemon
# management window plus an "open the UI in a browser" fallback instead of
# the embedded web view.
pkg_check_modules(WEBKIT IMPORTED_TARGET webkitgtk-6.0)
if(DEFINED ENV{RIVET_RACKET_LIBRARY})
  set(RACKETCS_LIBRARY "$ENV{RIVET_RACKET_LIBRARY}")
elseif(DEFINED ENV{RIVET_RACKET_LIB_DIR})
  find_library(RACKETCS_LIBRARY
    NAMES racketcs
    PATHS "$ENV{RIVET_RACKET_LIB_DIR}"
    NO_DEFAULT_PATH
    REQUIRED
  )
else()
  message(FATAL_ERROR "Set RIVET_RACKET_LIBRARY to libracketcs, or RIVET_RACKET_LIB_DIR to its directory.")
endif()

add_executable(RivetHost
  src/main.cpp
  src/js_bridge.cpp
  src/settings_window.cpp
  src/toast.cpp
  src/update_flow.cpp
  "${RIVET_ROOT}/platform/linux/runtime/backend.cpp"
  "${RIVET_ROOT}/platform/linux/system/autostart.cpp"
  "${RIVET_ROOT}/platform/linux/system/clipboard.cpp"
  "${RIVET_ROOT}/platform/linux/system/crash_shutdown.cpp"
  "${RIVET_ROOT}/platform/linux/system/global_shortcuts.cpp"
  "${RIVET_ROOT}/platform/linux/system/notifications.cpp"
  "${RIVET_ROOT}/platform/linux/system/secure_storage.cpp"
  "${RIVET_ROOT}/platform/linux/system/single_instance.cpp"
  "${RIVET_ROOT}/platform/linux/system/system_services.cpp"
  "${RIVET_ROOT}/platform/linux/system/system_services_internal.cpp"
  "${RIVET_ROOT}/platform/linux/system/tray.cpp"
  "${RIVET_ROOT}/platform/linux/theme/theme.cpp"
  "${RIVET_ROOT}/runtime/src/protocol.cpp"
)

if(LIBSECRET_FOUND)
  target_compile_definitions(RivetHost PRIVATE RIVET_HAVE_LIBSECRET=1)
endif()
if(WEBKIT_FOUND)
  target_compile_definitions(RivetHost PRIVATE HAVE_WEBKIT=1)
  # The web-process extension injects the official-UI desktop bridge into
  # the page world (UserContentManager scripts miss the first document on
  # WebKitGTK 2.52). Staged into app/webext where the UI process looks for
  # it; the stage wipe happens before CMake runs, so this copy survives.
  add_library(SyncpilotWebExtension MODULE webext/syncpilot_extension.cpp)
  target_link_libraries(SyncpilotWebExtension PRIVATE PkgConfig::WEBKIT)
  add_custom_command(TARGET SyncpilotWebExtension POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "${CMAKE_SOURCE_DIR}/../.rivet/stage/app/webext"
    COMMAND ${CMAKE_COMMAND} -E copy
            "$<TARGET_FILE:SyncpilotWebExtension>"
            "${CMAKE_SOURCE_DIR}/../.rivet/stage/app/webext/")
endif()

target_include_directories(RivetHost PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${RIVET_ROOT}/platform/linux/runtime"
  "${RIVET_ROOT}/platform/linux/system"
  "${RIVET_ROOT}/platform/linux/theme"
  "${RIVET_ROOT}/runtime/include"
  "$ENV{RIVET_RACKET_INCLUDE}"
)

target_link_libraries(RivetHost PRIVATE
  PkgConfig::GTK4
  PkgConfig::GLIB
  PkgConfig::JSON_GLIB
  ${RACKETCS_LIBRARY}
  ZLIB::ZLIB
  ${LZ4_LIBRARY}
  ${CURSES_LIBRARIES}
  Threads::Threads
  ${CMAKE_DL_LIBS}
)

if(LIBSECRET_FOUND)
  target_link_libraries(RivetHost PRIVATE PkgConfig::LIBSECRET)
endif()
if(WEBKIT_FOUND)
  target_link_libraries(RivetHost PRIVATE PkgConfig::WEBKIT)
endif()

target_compile_options(RivetHost PRIVATE -Wall -Wextra -Wpedantic)
