cmake_minimum_required(VERSION 3.5)
project(moonlight_ohos C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(TP ${CMAKE_CURRENT_SOURCE_DIR}/third_party)
set(MC ${TP}/moonlight-common-c)

if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH arm64-v8a)
endif()

# ---------------------------------------------------------------------------
# mbedTLS (PSA crypto backend for moonlight-common-c)
# ---------------------------------------------------------------------------
set(ENABLE_TESTING OFF CACHE BOOL "" FORCE)
set(ENABLE_PROGRAMS OFF CACHE BOOL "" FORCE)
set(USE_SHARED_MBEDTLS_LIBRARY OFF CACHE BOOL "" FORCE)
set(USE_STATIC_MBEDTLS_LIBRARY ON CACHE BOOL "" FORCE)
set(MBEDTLS_FATAL_WARNINGS OFF CACHE BOOL "" FORCE)
set(MBEDTLS_AS_SUBPROJECT ON CACHE BOOL "" FORCE)
add_subdirectory(${TP}/mbedtls ${CMAKE_BINARY_DIR}/mbedtls EXCLUDE_FROM_ALL)

# ---------------------------------------------------------------------------
# enet (moonlight-common-c transport)
# ---------------------------------------------------------------------------
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
add_subdirectory(${TP}/enet ${CMAKE_BINARY_DIR}/enet EXCLUDE_FROM_ALL)

# ---------------------------------------------------------------------------
# opus (audio decode)
# ---------------------------------------------------------------------------
set(OPUS_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_PROGRAMS OFF CACHE BOOL "" FORCE)
set(OPUS_BUILD_SHARED_LIBRARY ON CACHE BOOL "" FORCE)
set(OPUS_BUILD_FRAMEWORK OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fPIC")
add_subdirectory(${TP}/opus ${CMAKE_BINARY_DIR}/opus EXCLUDE_FROM_ALL)
set_target_properties(opus PROPERTIES POSITION_INDEPENDENT_CODE ON)

# ---------------------------------------------------------------------------
# moonlight-common-c core (portable C, no Android dependencies)
# ---------------------------------------------------------------------------
file(GLOB MC_SOURCES CONFIGURE_DEPENDS ${MC}/src/*.c)
add_library(mooncore STATIC ${MC_SOURCES}
        ${TP}/nanors/rs.c
        ${TP}/nanors/deps/obl/oblas_common.c
        ${TP}/nanors/deps/obl/oblas_lite.c)

target_include_directories(mooncore PRIVATE
        ${MC}/src
        ${MC}/enet/include
        ${TP}/nanors
        ${TP}/nanors/deps/obl)

target_compile_definitions(mooncore PRIVATE
        USE_MBEDTLS
        HAS_SOCKLEN_T=1
        HAVE_CLOCK_GETTIME=1
        NDEBUG)

target_link_libraries(mooncore PUBLIC enet mbedcrypto)

# ---------------------------------------------------------------------------
# NAPI bridge (exports libmoonbridge.so to ArkTS)
# ---------------------------------------------------------------------------
add_library(moonbridge SHARED
        bridge/diag.cpp
        bridge/nvhttp.cpp
        bridge/videodec.cpp
        bridge/audiodec.cpp
        bridge/bridge_napi.cpp)

target_include_directories(moonbridge PRIVATE
        ${MC}/src
        bridge)

execute_process(COMMAND git -C ${MC} rev-parse --short HEAD
        OUTPUT_VARIABLE MC_COMMIT_SHORT
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET)
if(NOT MC_COMMIT_SHORT)
    set(MC_COMMIT_SHORT "unknown")
endif()

target_compile_definitions(moonbridge PRIVATE
        MC_COMMIT="${MC_COMMIT_SHORT}"
        OHOS_ARCH="${OHOS_ARCH}"
        MBEDTLS_ALLOW_PRIVATE_ACCESS)

target_link_libraries(moonbridge PRIVATE
        mooncore
        enet
        mbedcrypto
        mbedtls
        mbedx509
        libace_napi.z.so
        libhilog_ndk.z.so
        libnative_window.so
        libnative_media_codecbase.so
        libnative_media_core.so
        libnative_media_vdec.so
        libohaudio.so
        opus)

target_compile_options(mooncore PRIVATE -Wno-unused-parameter -Wno-sign-compare)
