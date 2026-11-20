# Fidelis audio driver: an Audio Server plug-in adding the "Fidelis" output device.
# Adapted from the Sendspin for Mac driver (Apache-2.0, see LICENSE-sendspin), built on libASPL (MIT).
cmake_minimum_required(VERSION 3.20)

# Must precede project() to take effect.
set(CMAKE_OSX_DEPLOYMENT_TARGET 14.0 CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "")

project(FidelisDriver CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# "-" signs ad hoc (local use); pass a Developer ID for releases.
set(CODESIGN_ID "-" CACHE STRING "Codesign identity")

set(DRIVER_NAME "Fidelis")
set(DRIVER_VERSION "0.1.0")
set(DRIVER_IDENTIFIER "dev.fidelis.driver")
set(DRIVER_FACTORY_UUID "E7C3C4B1-D180-43C2-93C1-F1E75228AC22")
set(DRIVER_ENTRYPOINT "FidelisDriverEntryPoint")

# libASPL from the pinned submodule (third_party/libASPL, v3.1.2), as a static library.
include(ExternalProject)
set(LIBASPL_PREFIX ${CMAKE_CURRENT_BINARY_DIR}/libASPL-prefix)
ExternalProject_Add(libASPL
  SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../third_party/libASPL
  CMAKE_ARGS
    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET}
    -DBUILD_TESTING=OFF
  # Cache args keep the ;-separated architecture list intact.
  CMAKE_CACHE_ARGS
    -DCMAKE_OSX_ARCHITECTURES:STRING=${CMAKE_OSX_ARCHITECTURES}
  INSTALL_DIR ${LIBASPL_PREFIX}
  BUILD_BYPRODUCTS ${LIBASPL_PREFIX}/lib/libASPL.a
  LOG_CONFIGURE YES
  LOG_BUILD YES
  LOG_INSTALL YES
)

# A MODULE library is a Mach-O loadable bundle; CMake wraps it in Fidelis.driver/.
add_library(${DRIVER_NAME} MODULE
  src/ClientCheck.cpp
  src/Driver.cpp
  src/LoopbackHandler.cpp
  src/LoopbackStream.cpp
  src/FidelisDevice.cpp
)
add_dependencies(${DRIVER_NAME} libASPL)
target_include_directories(${DRIVER_NAME} SYSTEM PRIVATE ${LIBASPL_PREFIX}/include)
target_compile_options(${DRIVER_NAME} PRIVATE -Wall -Wextra -O2)
target_compile_definitions(${DRIVER_NAME} PRIVATE DRIVER_VERSION="${DRIVER_VERSION}")
find_library(CORE_FOUNDATION CoreFoundation REQUIRED)
find_library(CORE_AUDIO CoreAudio REQUIRED)
find_library(SECURITY Security REQUIRED)
target_link_libraries(${DRIVER_NAME} PRIVATE
  ${LIBASPL_PREFIX}/lib/libASPL.a ${CORE_FOUNDATION} ${CORE_AUDIO} ${SECURITY})

set_target_properties(${DRIVER_NAME} PROPERTIES
  OUTPUT_NAME "${DRIVER_NAME}"
  BUNDLE TRUE
  BUNDLE_EXTENSION "driver"
  PREFIX ""
  SUFFIX ""
  MACOSX_BUNDLE ON
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "${DRIVER_NAME}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${DRIVER_VERSION}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${DRIVER_VERSION}"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${DRIVER_IDENTIFIER}"
)

# Notarization requires a secure timestamp; ad-hoc signatures can't have one.
if(CODESIGN_ID STREQUAL "-")
  set(CODESIGN_TIMESTAMP --timestamp=none)
else()
  set(CODESIGN_TIMESTAMP --timestamp)
endif()

add_custom_target(${DRIVER_NAME}_codesign ALL
  COMMENT "Signing ${DRIVER_NAME}.driver (${CODESIGN_ID})"
  VERBATIM
  COMMAND codesign --force --options runtime ${CODESIGN_TIMESTAMP} -s "${CODESIGN_ID}"
    "$<TARGET_BUNDLE_DIR:${DRIVER_NAME}>"
  COMMAND codesign --verify --strict "$<TARGET_BUNDLE_DIR:${DRIVER_NAME}>"
)
add_dependencies(${DRIVER_NAME}_codesign ${DRIVER_NAME})
