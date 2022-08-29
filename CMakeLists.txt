# Minimum version of CMake that has all features required for this specific file.
cmake_minimum_required(VERSION 3.21)

project(CMakeRC VERSION 2.0.1)

# Insert CMakeRC into the CMake module path before all other modules.
list(INSERT CMAKE_MODULE_PATH 0 "${PROJECT_SOURCE_DIR}/cmake")

# Include the main module
include(CMakeRC.cmake)

# Don't build tests by default if the project is being included in another.
option(CMakeRC_BUILD_TESTS "Build tests" ${PROJECT_IS_TOP_LEVEL})

if (CMakeRC_BUILD_TESTS AND (PROJECT_SOURCE_DIR STREQUAL CMAKE_SOURCE_DIR))
  enable_testing()

  if (NOT MSVC)
    add_compile_options(-Wall -Wextra)
  endif ()

  add_subdirectory(tests)
endif ()
