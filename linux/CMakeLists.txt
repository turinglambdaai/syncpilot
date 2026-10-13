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

# The Rivet platform is consumed as a package library target (project
# constraint, rivet#238): hosts never compile Rivet sources into their own
# executable lists — rivet adding a translation unit needs no downstream
# change. The platform target carries the Racket include/link closure
# (RIVET_RACKET_INCLUDE / RIVET_RACKET_LIBRARY environment) publicly.
add_subdirectory("${RIVET_ROOT}/platform/linux"
                 "${CMAKE_BINARY_DIR}/rivet-platform-build")

# The desktop JS bridge parses the calls the embedded official UI posts to
# the syncpilot-bridge:// scheme handler (see src/js_bridge.cpp).
find_package(PkgConfig REQUIRED)
pkg_check_modules(JSON_GLIB REQUIRED IMPORTED_TARGET json-glib-1.0)
# WebKitGTK 6.0 is the official-UI embed (WebKitWebView on GTK4). OPTIONAL:
# without it the host still builds and the boot page offers the daemon
# management window plus an "open the UI in a browser" fallback instead of
# the embedded web view.
pkg_check_modules(WEBKIT IMPORTED_TARGET webkitgtk-6.0)

add_executable(RivetHost
  src/main.cpp
  src/js_bridge.cpp
  src/settings_window.cpp
  src/toast.cpp
  src/update_flow.cpp
)

if(WEBKIT_FOUND)
  target_compile_definitions(RivetHost PRIVATE HAVE_WEBKIT=1)
  target_link_libraries(RivetHost PRIVATE PkgConfig::WEBKIT)
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
)

target_link_libraries(RivetHost PRIVATE
  rivet::platform
  PkgConfig::JSON_GLIB
)

target_compile_options(RivetHost PRIVATE -Wall -Wextra -Wpedantic)
