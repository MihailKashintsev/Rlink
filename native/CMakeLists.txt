cmake_minimum_required(VERSION 3.14)
project(whisper_bridge LANGUAGES C CXX)

# whisper.cpp sources — expects whisper.cpp repo at native/whisper.cpp/
set(WHISPER_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/whisper.cpp")

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
        whisper_bridge.c
        ${WHISPER_SOURCES}
    )
else()
    add_library(whisper_bridge SHARED
        whisper_bridge.c
    )
endif()

target_include_directories(whisper_bridge PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

if(WHISPER_AVAILABLE)
    target_include_directories(whisper_bridge PRIVATE
        ${WHISPER_CPP_DIR}
    )
    target_compile_definitions(whisper_bridge PRIVATE
        GGML_USE_CPU
    )
else()
    target_compile_definitions(whisper_bridge PRIVATE RLINK_NO_WHISPER)
endif()

if(WIN32)
    # whisper.cpp + ggml are compiled straight INTO whisper_bridge.dll, so their
    # API macros must be dllEXPORT while building. Defining only *_SHARED makes
    # GGML_API/WHISPER_API dllimport, and "defining a dllimport function" is a
    # hard error (C2491) in ggml.c. Add *_BUILD so they resolve to dllexport.
    target_compile_definitions(whisper_bridge PRIVATE
        WHISPER_SHARED
        GGML_SHARED
        WHISPER_BUILD
        GGML_BUILD
    )
endif()

target_compile_features(whisper_bridge PRIVATE cxx_std_17)

# Install to build output
install(TARGETS whisper_bridge
    RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
    LIBRARY DESTINATION "${CMAKE_INSTALL_PREFIX}"
)
