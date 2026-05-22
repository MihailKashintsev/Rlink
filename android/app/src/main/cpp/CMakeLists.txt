cmake_minimum_required(VERSION 3.18.1)
project(whisper_bridge LANGUAGES C CXX)

set(WHISPER_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../native/whisper.cpp")

if(EXISTS "${WHISPER_CPP_DIR}/whisper.h")
    set(WHISPER_AVAILABLE TRUE)
else()
    set(WHISPER_AVAILABLE FALSE)
    message(WARNING "whisper.cpp not found at ${WHISPER_CPP_DIR}. "
        "Voice transcription will be disabled. "
        "To enable, clone whisper.cpp into native/whisper.cpp/")
endif()

if(WHISPER_AVAILABLE)
    set(WHISPER_SOURCES
        ${WHISPER_CPP_DIR}/whisper.cpp
        ${WHISPER_CPP_DIR}/ggml.c
        ${WHISPER_CPP_DIR}/ggml-alloc.c
        ${WHISPER_CPP_DIR}/ggml-backend.c
        ${WHISPER_CPP_DIR}/ggml-quants.c
    )
endif()

if(WHISPER_AVAILABLE)
    add_library(whisper_bridge SHARED
        ../../../../native/whisper_bridge.c
        ${WHISPER_SOURCES}
    )
else()
    add_library(whisper_bridge SHARED
        ../../../../native/whisper_bridge.c
    )
endif()

target_include_directories(whisper_bridge PRIVATE
    ../../../../native
)

if(WHISPER_AVAILABLE)
    target_include_directories(whisper_bridge PRIVATE
        ${WHISPER_CPP_DIR}
    )
    target_compile_definitions(whisper_bridge PRIVATE
        GGML_USE_CPU
    )
endif()

target_compile_features(whisper_bridge PRIVATE cxx_std_17)

find_library(log-lib log)
target_link_libraries(whisper_bridge ${log-lib})
